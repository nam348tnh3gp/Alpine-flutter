import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tar/tar.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart' show XZDecoder;
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

    // ── Xác định URL tải tarball ──
    final String url;
    if (distro.archUrls.containsKey(abi)) {
      url = distro.archUrls[abi]!;
    } else if (distro.gentooAutobuilds?.containsKey(abi) ?? false) {
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
      url = '${cfg.tarballBaseUrl}$tarballName';
      _log('   -> tarball: $tarballName');
    } else if (distro.alpineLatest?.containsKey(abi) ?? false) {
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
      url = '${cfg.baseUrl}$tarballName';
      _log('   -> tarball: $tarballName');
    } else {
      throw Exception(
          'Không xác định được URL tải cho ${distro.displayName} ($abi).');
    }

    final ext = distro.isXz ? 'tar.xz' : 'tar.gz';
    _log('📥 Đang tải ${distro.displayName} rootfs ($abi)...\n$url');

    // ── Tải file nén ──
    final archivePath = '$filesDir/${distro.id}-rootfs.$ext';
    final archiveFile = File(archivePath);

    if (archiveFile.existsSync()) {
      try { archiveFile.deleteSync(); } catch (_) {}
    }

    final client = http.Client();
    IOSink? sink;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('Tải rootfs thất bại: HTTP ${response.statusCode}.');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      sink = archiveFile.openWrite();

      await for (final chunk in response.stream) {
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

      if (total > 0 && received < total) {
        throw Exception(
            'Tải rootfs không đầy đủ: $received/$total bytes.');
      }
      if (received == 0) {
        throw Exception('Tải rootfs thất bại: file rỗng.');
      }
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      try { if (archiveFile.existsSync()) archiveFile.deleteSync(); } catch (_) {}
      _log('❌ Tải rootfs thất bại: $e');
      rethrow;
    } finally {
      client.close();
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
        final proc = await Process.start(xzBin, ['-d', '-c', archivePath]);

        // Drain stderr để pipe không bị đầy (xz in warning ra stderr).
        final stderrBuf = StringBuffer();
        final stderrSub = proc.stderr
            .transform(utf8.decoder)
            .listen(stderrBuf.write);

        try {
          // TarReader consume trực tiếp stdout của xz → không cần buffer
          // toàn bộ tar vào RAM.
          final counts = await _extractTarStream(proc.stdout, rootfs);
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
      final counts = await _extractTarStream(tarStream, rootfs);
      fileCount = counts.$1;
      dirCount = counts.$2;
      linkCount = counts.$3;
    }
    _log('   -> $fileCount file, $dirCount thư mục, $linkCount symlink');
    onProgress(0.88);

    try {
      await archiveFile.delete();
    } catch (_) {}

    _log('🔧 Cấp quyền execute cho toàn bộ rootfs...');
    final chmodResult = await Process.run('chmod', ['-R', 'a+rx', rootfs]);
    if (chmodResult.exitCode != 0) {
      _log('⚠️ chmod -R a+rX $rootfs thất bại (exit ${chmodResult.exitCode}): '
          '${chmodResult.stderr}');
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

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
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
  Future<(int, int, int)> _extractTarStream(
      Stream<List<int>> tarStream, String rootfs) async {
    var fileCount = 0, dirCount = 0, linkCount = 0;
    final reader = TarReader(tarStream);

    while (await reader.moveNext()) {
      final entry = reader.current;
      final header = entry.header;
      final outPath = '$rootfs/${entry.name}';

      switch (header.typeFlag) {
        case TypeFlag.symlink:
          final target = header.linkName;
          if (target == null) break;
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
      throw Exception('Không tìm thấy libproot.so tại: $prootBin');
    }

    final loaderPath = '$libDir/libproot-loader.so';
    if (!File(loaderPath).existsSync()) {
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
    } finally {
      await _logSub?.cancel();
      _logSub = null;
      fake.closeStdout();
      fake.closeStderr();
      _running = false;
      onProcessExited?.call();
    }

    _log('Process exited with code $exitCode');
    fake.setExitCode(exitCode);

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