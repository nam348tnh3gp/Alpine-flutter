import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tar/tar.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart' show XZDecoder;
import 'package:path/path.dart' as p;
import 'native_bridge.dart';
import '../proot_jni.dart';
import '../models/distro.dart';

class FakeProcess implements Process {
  final int _pid;
  int _exitCode;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController = StreamController.broadcast();
  final StreamController<List<int>> _stderrController = StreamController.broadcast();
  final void Function()? onKill;

  FakeProcess(this._pid, this._exitCode, {this.onKill});

  @override
  int get pid => _pid;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => IOSink(StreamController<List<int>>().sink);

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  void setExitCode(int code) {
    _exitCode = code;
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    onKill?.call();
    return true;
  }

  void addStdout(List<int> data) => _stdoutController.add(data);
  void addStderr(List<int> data) => _stderrController.add(data);
  void closeStdout() => _stdoutController.close();
  void closeStderr() => _stderrController.close();
}

class PRootService {
  final Distro distro;
  final void Function(String line) onLog;
  final void Function()? onProcessExited;
  Process? _currentProcess;
  final StringBuffer _logBuffer = StringBuffer();
  StreamSubscription<String>? _logSub;
  bool _running = false;
  String _sessionId = '';

  PRootService({required this.distro, required this.onLog, this.onProcessExited});

  String getLogs() => _logBuffer.toString();
  void clearLogs() => _logBuffer.clear();

  void _log(String message) {
    _logBuffer.writeln(message);
    onLog(message);
  }

  Future<String> _rootfsDir() async {
    final filesDir = await NativeBridge.getFilesDir();
    return '$filesDir/rootfs-${distro.id}';
  }

  Future<bool> isInstalled() async {
    final rootfs = await _rootfsDir();
    final markerOk = File('$rootfs/${distro.markerFile}').existsSync();
    final shOk = File('$rootfs/bin/sh').existsSync() ||
        File('$rootfs/usr/bin/sh').existsSync();
    if (markerOk && !shOk) {
      _log('⚠️ Phát hiện rootfs ${distro.displayName} cài dở (thiếu /bin/sh) - sẽ cài lại.');
    }
    return markerOk && shOk;
  }

  /// Chuẩn bị `xz` binary + `liblzma.so` để stream-giải-nén .tar.xz.
  ///
  /// QUAN TRỌNG: RPATH của libxz.so là `$ORIGIN` (= thư mục chứa binary).
  /// Vì jniLibs có thể noexec, ta copy CẢ HAI file ra filesDir (exec được):
  ///   <libDir>/libxz.so   -> <filesDir>/xz-bin
  ///   <libDir>/liblzma.so -> <filesDir>/liblzma.so
  /// Khi exec <filesDir>/xz-bin, linker resolve `liblzma.so` cạnh nó.
  ///
  /// Trả null nếu APK không nhúng binary → bootstrap fallback về XZDecoder
  /// thuần Dart (tốn RAM, có thể OOM với Gentoo).
  Future<String?> _ensureXzBinary(String libDir, String filesDir) async {
    final cachedXz = '$filesDir/xz-bin';
    final cachedLzma = '$filesDir/liblzma.so';

    // Cache hit: đã có cả 2 file → chmod lại (idempotent) và trả luôn.
    if (File(cachedXz).existsSync() && File(cachedLzma).existsSync()) {
      final r = await Process.run('chmod', ['+x', cachedXz]);
      if (r.exitCode == 0) return cachedXz;
    }

    for (final name in ['libxz.so', 'xz']) {
      final src = '$libDir/$name';
      if (!File(src).existsSync()) continue;
      try {
        await File(src).copy(cachedXz);
        final r = await Process.run('chmod', ['+x', cachedXz]);
        if (r.exitCode != 0) {
          _log('⚠️ chmod +x $cachedXz thất bại: ${r.stderr}');
          continue;
        }

        // Copy liblzma cạnh xz-bin để RPATH `$ORIGIN` tìm được.
        final lzmaSrc = '$libDir/liblzma.so';
        if (File(lzmaSrc).existsSync()) {
          await File(lzmaSrc).copy(cachedLzma);
          await Process.run('chmod', ['+x', cachedLzma]);
        } else {
          _log('⚠️ Không thấy liblzma.so trong $libDir — xz binary có thể không chạy được.');
        }

        _log('✅ Đã chuẩn bị xz binary từ $name');
        return cachedXz;
      } catch (e) {
        _log('⚠️ Không dùng được $src: $e');
      }
    }
    return null;
  }

  // ─────────────────────────────────────────────────────────────────────
  // Download: retry + mirror fallback
  // ─────────────────────────────────────────────────────────────────────

  Future<bool> _downloadWithFallback({
    required List<String> urls,
    required File dest,
    required void Function(double) onProgress,
  }) async {
    final client = http.Client();
    try {
      for (var i = 0; i < urls.length; i++) {
        final url = urls[i];
        for (var attempt = 0; attempt < 2; attempt++) {
          if (i > 0 || attempt > 0) {
            _log('🔁 Thử lại ($url) — lần ${attempt + 1}');
          }
          if (attempt > 0) {
            await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
          }
          final ok = await _downloadOnce(client, url, dest, onProgress);
          if (ok) return true;
        }
      }
      return false;
    } finally {
      client.close();
    }
  }

  Future<bool> _downloadOnce(
    http.Client client,
    String url,
    File dest,
    void Function(double) onProgress,
  ) async {
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        _log('❌ HTTP ${response.statusCode} từ $url');
        return false;
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      sink = dest.openWrite();

      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress(received / total * 0.7);
        } else {
          onProgress(0.10 + ((received ~/ (1024 * 1024)) % 40) / 40 * 0.59);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0) {
        _log('❌ Tải thất bại: file rỗng ($url)');
        return false;
      }
      if (total > 0 && received < total) {
        _log('⚠️ Tải không đầy đủ: $received/$total bytes ($url)');
        return false;
      }
      return true;
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      try { if (dest.existsSync()) dest.deleteSync(); } catch (_) {}
      _log('❌ Tải lỗi ($url): $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────────────
  // URL resolution (Alpine / Gentoo resolve động)
  // ─────────────────────────────────────────────────────────────────────

  Future<List<String>> _resolveUrls(String abi) async {
    // Static URLs (có thể nhiều mirror)
    if (distro.archUrls.containsKey(abi)) {
      return List<String>.from(distro.archUrls[abi]!);
    }

    // Gentoo: đọc latest-stage3-*.txt
    if (distro.gentooAutobuilds?.containsKey(abi) ?? false) {
      final cfg = distro.gentooAutobuilds![abi]!;
      _log('🔎 Đang dò bản Gentoo mới nhất ($abi)...\n${cfg.latestUrl}');
      final resp = await http.get(Uri.parse(cfg.latestUrl));
      if (resp.statusCode != 200) {
        throw Exception(
            'Không đọc được ${cfg.latestFile}: HTTP ${resp.statusCode}');
      }
      final m = RegExp(r'(\S+\.tar\.xz)').firstMatch(resp.body);
      if (m == null) {
        throw Exception(
            'Không tìm thấy tarball .tar.xz trong ${cfg.latestFile}');
      }
      final tarballPath = m.group(1)!;
      final tarballName = tarballPath.contains('/')
          ? tarballPath.split('/').last
          : tarballPath;
      final url = '${cfg.tarballBaseUrl}$tarballName';
      _log('   -> tarball: $tarballName');
      return [url];
    }

    // Alpine: đọc latest-releases.yaml
    if (distro.alpineLatest?.containsKey(abi) ?? false) {
      final cfg = distro.alpineLatest![abi]!;
      _log('🔎 Đang dò bản Alpine mới nhất ($abi)...\n${cfg.yamlUrl}');
      final resp = await http.get(Uri.parse(cfg.yamlUrl));
      if (resp.statusCode != 200) {
        throw Exception(
            'Không đọc được latest-releases.yaml: HTTP ${resp.statusCode}');
      }
      final pattern = RegExp(
          'alpine-${RegExp.escape(cfg.variant)}-[^\\s"\']+\\.tar\\.gz');
      final m = pattern.firstMatch(resp.body);
      if (m == null) {
        throw Exception(
            'Không tìm thấy ${cfg.variant} trong latest-releases.yaml');
      }
      final tarballName = m.group(0)!;
      final url = '${cfg.baseUrl}$tarballName';
      _log('   -> tarball: $tarballName');
      return [url];
    }

    throw Exception(
        'Không xác định được URL tải cho ${distro.displayName} ($abi).');
  }

  // ─────────────────────────────────────────────────────────────────────
  // Bootstrap
  // ─────────────────────────────────────────────────────────────────────

  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    if (!distro.supportsAbi(abi)) {
      throw Exception(
          '${distro.displayName} không hỗ trợ ABI thiết bị này ($abi).');
    }
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();
    final libDir = await NativeBridge.getNativeLibraryDir();

    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    // ── Xác định URL(s) ──
    final urls = await _resolveUrls(abi);

    final ext = distro.isXz ? 'tar.xz' : 'tar.gz';
    _log('📥 Đang tải ${distro.displayName} rootfs ($abi)...\n${urls.first}');

    final archiveFile = File('$filesDir/${distro.id}-rootfs.$ext');
    if (archiveFile.existsSync()) {
      try { archiveFile.deleteSync(); } catch (_) {}
    }

    // ── Tải (retry + mirror fallback) ──
    final downloaded = await _downloadWithFallback(
      urls: urls,
      dest: archiveFile,
      onProgress: onProgress,
    );
    if (!downloaded) {
      try { if (archiveFile.existsSync()) archiveFile.deleteSync(); } catch (_) {}
      throw Exception('Tất cả mirror đều thất bại cho ${distro.displayName}.');
    }

    onProgress(0.72);
    var fileCount = 0, dirCount = 0, linkCount = 0;

    if (distro.isXz) {
      // ── FIX OOM 72% ──
      // Trước đây: readAsBytes() + XZDecoder().decodeBytes() → peak RAM
      // ~1.3GB với Gentoo stage3 → Android OOM-kill → app "reload" ở 72%.
      // Giờ: ưu tiên xz binary native (stream stdout → TarReader, peak vài
      // MB), chỉ fallback về XZDecoder thuần Dart khi APK chưa nhúng binary.
      _log('📦 Giải nén .tar.xz (${distro.displayName})...');

      final xzBin = await _ensureXzBinary(libDir, filesDir);
      if (xzBin != null) {
        _log('   -> dùng native xz (stream, RAM thấp)');
        final proc = await Process.start(xzBin, ['-d', '-c', archiveFile.path]);

        // Drain stderr để pipe không bị đầy (xz in warning ra stderr).
        final stderrBuf = StringBuffer();
        final stderrSub = proc.stderr
            .transform(utf8.decoder)
            .listen(stderrBuf.write);

        try {
          final counts = await _extractTarStream(
            proc.stdout,
            rootfs,
            onProgress: (n) {
              // Scale progress từ 0.72 → 0.87 trong lúc extract.
              onProgress((0.72 + 0.15 * ((n % 200) / 200)).clamp(0.72, 0.87));
            },
          );
          final exitCode = await proc.exitCode;
          if (exitCode != 0) {
            throw Exception(
                'xz thoát với code $exitCode: ${stderrBuf.toString().trim()}');
          }
          fileCount = counts.$1;
          dirCount = counts.$2;
          linkCount = counts.$3;
        } catch (e) {
          proc.kill(ProcessSignal.sigkill);
          rethrow;
        } finally {
          await stderrSub.cancel();
        }
      } else {
        _log('   ⚠️ Không tìm thấy xz binary trong APK — dùng XZDecoder '
            'thuần Dart. Với Gentoo stage3 (~300MB nén → ~1GB tar) có thể '
            'OOM. Nhúng `libxz.so` + `liblzma.so` vào jniLibs để fix triệt để.');
        final xzBytes = await archiveFile.readAsBytes();
        final tarBytes = XZDecoder().decodeBytes(xzBytes);
        onProgress(0.8);
        final counts = await _extractTarStream(Stream.value(tarBytes), rootfs);
        fileCount = counts.$1;
        dirCount = counts.$2;
        linkCount = counts.$3;
      }
    } else {
      _log('📦 Giải nén rootfs bằng package:tar (hỗ trợ symlink đầy đủ)...');
      final tarStream = archiveFile.openRead().transform(gzip.decoder);
      final counts = await _extractTarStream(
        tarStream,
        rootfs,
        onProgress: (n) {
          onProgress((0.72 + 0.15 * ((n % 200) / 200)).clamp(0.72, 0.87));
        },
      );
      fileCount = counts.$1;
      dirCount = counts.$2;
      linkCount = counts.$3;
    }
    _log('   -> $fileCount file, $dirCount thư mục, $linkCount symlink');
    onProgress(0.88);

    try {
      await archiveFile.delete();
    } catch (_) {}

    // ── Quyền execute (tối ưu: chỉ chmod thư mục + bin/sbin) ──
    // `chmod -R a+rx` trên Arch/Gentoo (800MB+) cực chậm và không cần thiết:
    //   • Permission của file đã được tar giữ nguyên từ tarball.
    //   • Chỉ cần đảm bảo MỌI THƯ MỤC có +x (traversal) và các binary
    //     cốt lõi trong bin/sbin có +x (Android có thể strip khi extract
    //     tarball nếu là root, nhưng ở đây ta extract bằng chính app nên
    //     bit đã được giữ; bước này là phòng hờ).
    _log('🔧 Đảm bảo quyền execute (dirs + bin/sbin)...');
    try {
      await Process.run(
        'find', [rootfs, '-type', 'd', '-exec', 'chmod', 'a+rx', '{}', '+'],
      );
      for (final d in [
        'bin', 'sbin', 'usr/bin', 'usr/sbin',
        'usr/local/bin', 'usr/local/sbin',
      ]) {
        final p = '$rootfs/$d';
        if (Directory(p).existsSync()) {
          await Process.run(
            'find', [p, '-type', 'f', '-exec', 'chmod', 'a+x', '{}', '+'],
          );
        }
      }
    } catch (e) {
      _log('⚠️ chmod thất bại: $e');
    }

    if (distro.id == 'alpine') {
      final shLink = Link('$rootfs/bin/sh');
      if (!shLink.existsSync()) {
        try {
          if (File('$rootfs/bin/sh').existsSync()) File('$rootfs/bin/sh').deleteSync();
          await shLink.create('busybox', recursive: true);
          _log('✅ Đã tạo /bin/sh -> busybox.');
        } catch (e) {
          _log('ℹ️ /bin/sh đã tồn tại từ tarball (bình thường).');
        }
      }
    }

    // Tạo sẵn thư mục chuẩn + resolv.conf (bao gồm etc/ — trước đây thiếu
    // nếu tarball không có etc/ do layout khác).
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root', 'etc']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    onProgress(1.0);
    _log('✅ Hoàn tất cài đặt ${distro.displayName} rootfs tại: $rootfs');
    if (distro.postInstallNote != null) {
      _log(distro.postInstallNote!);
    }
  }

  /// Giải nén 1 tar stream (đã giải nén sẵn khỏi gzip/xz) ra [rootfs].
  ///
  /// Có 2 lớp bảo vệ **path traversal**:
  ///  1. Entry name không được resolve ra ngoài rootfs (chặn `../../etc`).
  ///  2. Symlink target (nếu là relative) không được trỏ ra ngoài rootfs.
  ///     Symlink tuyệt đối (`/usr/bin/foo`) được giữ nguyên — sẽ resolve
  ///     bên trong proot rootfs lúc runtime.
  Future<(int, int, int)> _extractTarStream(
    Stream<List<int>> tarStream,
    String rootfs, {
    void Function(int extractedCount)? onProgress,
  }) async {
    var fileCount = 0, dirCount = 0, linkCount = 0;
    final reader = TarReader(tarStream);
    final rootfsAbs = p.canonicalize(rootfs);

    bool isEntrySafe(String name) {
      final clean = name.replaceFirst(RegExp(r'^(\./)+'), '');
      if (clean.isEmpty) return false;
      final joined = p.canonicalize(p.join(rootfs, clean));
      if (!p.isWithin(rootfsAbs, joined) && joined != rootfsAbs) {
        _log('🚫 Bỏ qua entry có path không an toàn: $name');
        return false;
      }
      return true;
    }

    bool isSymlinkTargetSafe(String linkPath, String target) {
      if (target.isEmpty) return false;
      if (target.startsWith('/')) return true; // absolute: OK trong proot
      final linkDir = p.dirname(p.join(rootfs, linkPath));
      final resolved = p.canonicalize(p.join(linkDir, target));
      if (!p.isWithin(rootfsAbs, resolved)) {
        _log('🚫 Bỏ qua symlink không an toàn: $linkPath -> $target');
        return false;
      }
      return true;
    }

    while (await reader.moveNext()) {
      final entry = reader.current;
      final header = entry.header;
      if (!isEntrySafe(entry.name)) continue;
      final outPath = '$rootfs/${entry.name}';

      switch (header.typeFlag) {
        case TypeFlag.symlink:
          final target = header.linkName;
          if (target == null) break;
          if (!isSymlinkTargetSafe(entry.name, target)) break;
          Directory(outPath).parent.createSync(recursive: true);
          if (Link(outPath).existsSync() || File(outPath).existsSync()) {
            try {
              File(outPath).deleteSync();
            } catch (_) {
              Link(outPath).deleteSync();
            }
          }
          try {
            await Link(outPath).create(target, recursive: true);
          } catch (e) {
            _log('⚠️ Không tạo được symlink $outPath -> $target: $e');
          }
          linkCount++;
          break;
        case TypeFlag.dir:
          Directory(outPath).createSync(recursive: true);
          dirCount++;
          break;
        default:
          final outFile = File(outPath);
          outFile.parent.createSync(recursive: true);
          await entry.contents.pipe(outFile.openWrite());
          fileCount++;
          break;
      }

      if (onProgress != null &&
          (fileCount + dirCount + linkCount) % 200 == 0) {
        onProgress(fileCount + dirCount + linkCount);
      }
    }
    return (fileCount, dirCount, linkCount);
  }

  Future<Process> start({
    required List<String> command,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
    int rows = 24,
    int cols = 80,
  }) async {
    if (_running) {
      throw Exception('PRootService đang chạy.');
    }
    _running = true;
    _sessionId = DateTime.now().microsecondsSinceEpoch.toString();

    final libDir = await NativeBridge.getNativeLibraryDir();
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    final prootBin = '$libDir/libproot.so';
    if (!File(prootBin).existsSync()) {
      _running = false;
      throw Exception('Không tìm thấy libproot.so tại: $prootBin');
    }

    final loaderPath = '$libDir/libproot-loader.so';
    if (!File(loaderPath).existsSync()) {
      _running = false;
      throw Exception(
        'Không tìm thấy $loaderPath.\n'
        'Build lại APK — fetch_native_binaries.sh cần tải loader từ gói '
        'proot của Termux (libexec/proot/loader).',
      );
    }

    final tmpDir = '$filesDir/proot-tmp';
    Directory(tmpDir).createSync(recursive: true);

    if (command.isEmpty) command = ['/bin/sh', '-l'];

    final args = <String>[
      '-0',
      '--link2symlink',
      '--kill-on-exit',
      '-r', rootfs,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '$tmpDir:/tmp',
      '-w', '/root',
      ...command,
    ];

    final env = <String, String>{
      'PROOT_TMP_DIR': tmpDir,
      'PROOT_LOADER': loaderPath,
      'LD_LIBRARY_PATH': libDir,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'TERM': 'xterm-256color',
      'COLUMNS': cols.toString(),
      'LINES': rows.toString(),
      'PROOT_NO_SECCOMP': '1',
    };

    final loader32 = '$libDir/libproot-loader32.so';
    if (File(loader32).existsSync()) {
      env['PROOT_LOADER_32'] = loader32;
    }

    _log('🚀 Khởi chạy JNI: $prootBin ${args.join(' ')}');
    _log('   PROOT_LOADER=$loaderPath');

    final fake = FakeProcess(0, -1, onKill: () {
      ProotJNI.killProot(sessionId: _sessionId);
    });
    _currentProcess = fake;

    _logSub = ProotJNI.onLog.listen((line) {
      if (line.startsWith('[$_sessionId][pty]')) {
        String content = line.substring('[$_sessionId][pty]'.length);
        if (content.isNotEmpty) {
          final data = utf8.encode(content);
          fake.addStdout(data);
          onStdout?.call(content);
        }
      } else {
        if (line.startsWith('[$_sessionId]')) {
          _logBuffer.writeln(line.substring('[$_sessionId]'.length));
          final bytes = utf8.encode('$line\n');
          fake.addStderr(bytes);
        }
      }
    });

    // ── FIX: đảm bảo Completer exitCode luôn được complete dù JNI throw ──
    int exitCode = -1;
    try {
      exitCode = await ProotJNI.runProot(
        prootBin,
        args,
        env,
        rows: rows,
        cols: cols,
        sessionId: _sessionId,
      );
    } catch (e) {
      exitCode = -2;
      _log('💥 JNI error: $e');
      rethrow;
    } finally {
      await _logSub?.cancel();
      _logSub = null;
      fake.closeStdout();
      fake.closeStderr();
      fake.setExitCode(exitCode); // LUÔN complete completer
      _running = false;
      onProcessExited?.call();
    }

    _log('Process exited with code $exitCode');
    return fake;
  }

  Future<void> sendInput(String data) async {
    if (!_running) return;
    final bytes = utf8.encode(data);
    await ProotJNI.writeToPty(bytes, sessionId: _sessionId);
  }

  Future<void> resizeTerminal(int width, int height) async {
    if (!_running) return;
    await ProotJNI.resizePty(width, height, sessionId: _sessionId);
  }

  void stop() {
    if (_currentProcess != null) {
      _currentProcess?.kill();
      _currentProcess = null;
    }
    _running = false;
    _logSub?.cancel();
    _logSub = null;
  }
}