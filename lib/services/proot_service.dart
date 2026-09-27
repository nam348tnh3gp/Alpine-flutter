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
  final void Function()? onKill; // Callback để kill đúng session

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
    // /bin/sh gần như luôn có trên mọi distro Linux - dùng làm kiểm tra
    // "rootfs còn nguyên vẹn" chung cho tất cả, thay vì chỉ check busybox
    // (chỉ Alpine mới có busybox, các distro khác dùng coreutils/dash/bash).
    final shOk = File('$rootfs/bin/sh').existsSync() ||
        File('$rootfs/usr/bin/sh').existsSync();
    if (markerOk && !shOk) {
      _log('⚠️ Phát hiện rootfs ${distro.displayName} cài dở (thiếu /bin/sh) - sẽ cài lại.');
    }
    return markerOk && shOk;
  }

  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    if (!distro.supportsAbi(abi)) {
      throw Exception(
          '${distro.displayName} không hỗ trợ ABI thiết bị này ($abi).');
    }
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    // ── Xác định URL tải tarball ──
    // Đa số distro có URL cố định (archUrls). Riêng Gentoo xoá các bản cũ
    // theo thời gian, và cả symlink "current-stage3-*" (cách cũ) đôi khi
    // 404 tuỳ mirror/route - nên thay vào đó TỰ QUÉT thư mục autobuilds/
    // (endpoint ổn định, không phải symlink) để tìm thư mục ngày-giờ mới
    // nhất, rồi tự suy ra tên file - giống hệt cách làm thủ công.
    String url;
    if (distro.archUrls.containsKey(abi)) {
      url = distro.archUrls[abi]!;
    } else {
      final cfg = distro.gentooAutobuilds![abi]!;
      final listUrl = 'https://distfiles.gentoo.org/releases/${cfg.archPath}/autobuilds/';
      _log('🔎 Đang dò bản Gentoo mới nhất ($abi)...\n$listUrl');

      final listResp = await http.get(Uri.parse(listUrl));
      if (listResp.statusCode != 200) {
        throw Exception('Không đọc được danh sách bản build: HTTP ${listResp.statusCode}');
      }
      // Thư mục con dạng "20260830T234553Z/" - tên có thể sort được trực
      // tiếp dạng chuỗi vì đúng định dạng ISO8601 rút gọn (chuỗi lớn hơn
      // = ngày sau hơn), không cần parse ra DateTime.
      final timestamps = RegExp(r'href="(\d{8}T\d{6}Z)/"')
          .allMatches(listResp.body)
          .map((m) => m.group(1)!)
          .toSet()
          .toList()
        ..sort();
      if (timestamps.isEmpty) {
        throw Exception('Không tìm thấy bản build nào tại $listUrl (Gentoo đổi cấu trúc thư mục?)');
      }
      final latest = timestamps.last;
      url = 'https://distfiles.gentoo.org/releases/${cfg.archPath}/autobuilds/$latest/'
          'stage3-${cfg.profile}-$latest.tar.xz';
      _log('   -> bản mới nhất: $latest');
    }

    final ext = distro.isXz ? 'tar.xz' : 'tar.gz';
    _log('📥 Đang tải ${distro.displayName} rootfs ($abi)...\n$url');

    final archivePath = '$filesDir/${distro.id}-rootfs.$ext';
    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception('Tải rootfs thất bại: HTTP ${response.statusCode}.');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = File(archivePath).openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total * 0.7);
    }
    await sink.close();

    onProgress(0.72);
    var fileCount = 0, dirCount = 0, linkCount = 0;

    if (distro.isXz) {
      // Không có API giải nén .tar.xz dạng stream ổn định trong Dart, nên
      // phải đọc + giải nén toàn bộ vào RAM trước (LƯU Ý: tốn nhiều bộ nhớ
      // hơn nhánh .tar.gz bên dưới - stage3 Gentoo giải nén ra có thể tới
      // hàng trăm MB - 1GB+, máy ít RAM có thể lỗi ở bước này).
      _log('📦 Giải nén .tar.xz (${distro.displayName}) - có thể mất một lúc và tốn RAM...');
      final xzBytes = await File(archivePath).readAsBytes();
      final tarBytes = XZDecoder().decodeBytes(xzBytes);
      onProgress(0.8);
      final counts = await _extractTarStream(Stream.value(tarBytes), rootfs);
      fileCount = counts.$1;
      dirCount = counts.$2;
      linkCount = counts.$3;
    } else {
      _log('📦 Giải nén rootfs bằng package:tar (hỗ trợ symlink đầy đủ)...');
      final tarStream = File(archivePath).openRead().transform(gzip.decoder);
      final counts = await _extractTarStream(tarStream, rootfs);
      fileCount = counts.$1;
      dirCount = counts.$2;
      linkCount = counts.$3;
    }
    _log('   -> $fileCount file, $dirCount thư mục, $linkCount symlink');
    onProgress(0.88);

    await File(archivePath).delete().catchError((_) => File(archivePath));

    _log('🔧 Cấp quyền execute cho toàn bộ rootfs...');
    final chmodResult = await Process.run('chmod', ['-R', 'a+rx', rootfs]);
    if (chmodResult.exitCode != 0) {
      _log('⚠️ chmod -R a+rX $rootfs thất bại (exit ${chmodResult.exitCode}): '
          '${chmodResult.stderr}');
    }

    // Chỉ Alpine dùng busybox - các distro khác (Ubuntu/Arch/Gentoo) đã có
    // sẵn /bin/sh thật (dash/bash) từ trong tarball, KHÔNG được đè lên.
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
  /// Dùng chung cho cả nhánh .tar.gz và .tar.xz để không lặp code xử lý
  /// symlink/thư mục/file.
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
        // Bỏ prefix và truyền nguyên vẹn (không trim, không thêm \n)
        String content = line.substring('[$_sessionId][pty]'.length);
        if (content.isNotEmpty) {
          final data = utf8.encode(content); // raw bytes
          fake.addStdout(data);
          onStdout?.call(content); // truyền raw string
        }
      } else {
        // Log thường từ launcher: chỉ lưu vào buffer để dùng cho nút "Copy log",
        // không in ra terminal để tránh nhiễu.
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
      _currentProcess?.kill(); // Gọi callback kill session
      _currentProcess = null;
    }
    _running = false;
    _logSub?.cancel();
    _logSub = null;
  }
}