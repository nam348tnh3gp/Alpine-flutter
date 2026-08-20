import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tar/tar.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';
import '../proot_jni.dart';

// ===== FAKE PROCESS =====
// Giả lập Process object vì JNI không trả về Process
class FakeProcess implements Process {
  final int _pid;
  int _exitCode;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutController = StreamController.broadcast();
  final StreamController<List<int>> _stderrController = StreamController.broadcast();

  FakeProcess(this._pid, this._exitCode);

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

  // Trước đây exit code được truyền cứng vào constructor lúc proot ĐÃ
  // xong, nên FakeProcess không thể được trả về sớm để UI theo dõi log
  // trong lúc chạy. Giờ tạo FakeProcess trước, set exit code sau khi
  // proot thực sự thoát.
  void setExitCode(int code) {
    _exitCode = code;
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  // Hỗ trợ ghi output từ JNI nếu có callback
  void addStdout(List<int> data) => _stdoutController.add(data);
  void addStderr(List<int> data) => _stderrController.add(data);
  void closeStdout() => _stdoutController.close();
  void closeStderr() => _stderrController.close();
}

// ===== PRootService =====
class PRootService {
  static const _alpineVersion = '3.19.9';
  static const _alpineArchMap = {
    'arm64-v8a': 'aarch64',
    'armeabi-v7a': 'armv7',
  };

  final void Function(String line) onLog;
  Process? _currentProcess;
  final StringBuffer _logBuffer = StringBuffer();

  PRootService({required this.onLog});

  String getLogs() => _logBuffer.toString();
  void clearLogs() => _logBuffer.clear();

  void _log(String message) {
    _logBuffer.writeln(message);
    onLog(message);
  }

  Future<String> _rootfsDir() async {
    final filesDir = await NativeBridge.getFilesDir();
    return '$filesDir/alpine-rootfs';
  }

  Future<bool> isInstalled() async {
    final rootfs = await _rootfsDir();
    final releaseOk = File('$rootfs/etc/alpine-release').existsSync();
    final busyboxOk = File('$rootfs/bin/busybox').existsSync();
    if (releaseOk && !busyboxOk) {
      _log('⚠️ Phát hiện rootfs cài dở (thiếu /bin/busybox) - sẽ cài lại.');
    }
    return releaseOk && busyboxOk;
  }

  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    final alpineArch = _alpineArchMap[abi] ?? 'aarch64';
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    final url =
        'https://dl-cdn.alpinelinux.org/alpine/v${_alpineVersion.substring(0, 4)}/'
        'releases/$alpineArch/alpine-minirootfs-$_alpineVersion-$alpineArch.tar.gz';

    _log('📥 Đang tải Alpine minirootfs ($alpineArch)...\n$url');

    final tarGzPath = '$filesDir/alpine-rootfs.tar.gz';
    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception('Tải rootfs thất bại: HTTP ${response.statusCode}.');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = File(tarGzPath).openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total * 0.7);
    }
    await sink.close();

    _log('📦 Giải nén rootfs bằng package:tar (hỗ trợ symlink đầy đủ)...');
    onProgress(0.72);

    var fileCount = 0, dirCount = 0, linkCount = 0;
    final tarStream = File(tarGzPath).openRead().transform(gzip.decoder);
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
          final linkFile = Link(outPath);
          if (linkFile.existsSync()) await linkFile.delete();
          else if (File(outPath).existsSync()) File(outPath).deleteSync();
          await linkFile.create(target, recursive: true);
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
    _log('   -> $fileCount file, $dirCount thư mục, $linkCount symlink');
    onProgress(0.88);

    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    _log('🔧 Cấp quyền execute cho toàn bộ rootfs...');
    // BUG CŨ: chỉ chmod +x cho 'bin','sbin','usr/bin','usr/sbin','usr/lib/apk'.
    // Vì package:tar giải nén qua File.openWrite() (KHÔNG giữ mode bit gốc
    // trong tarball), MỌI file trong rootfs đều thiếu +x trừ khi chmod thủ
    // công. Danh sách trên bỏ sót 'lib/' - nơi chứa ELF interpreter musl
    // (vd. /lib/ld-musl-aarch64.so.1). Khi exec một binary động, kernel
    // Linux còn kiểm tra quyền +x của chính file interpreter (PT_INTERP)
    // qua open_exec(), không chỉ của binary chính -> thiếu +x ở đây khiến
    // MỌI binary liên kết động trong rootfs (gồm cả busybox) không exec
    // được, dù đường dẫn được proot dịch (translate) hoàn toàn chính xác.
    // Chmod đệ quy toàn bộ rootfs một lần để không sót thư mục nào nữa.
    // Lưu ý: dùng 'x' thường (không phải 'X') — 'X' chỉ set +x cho file ĐÃ
    // có sẵn +x từ trước, mà file do Dart ghi ra (File.openWrite) không có
    // bit +x nào cả nên 'X' sẽ không set được gì. Set +x cho toàn bộ file
    // (kể cả file dữ liệu/config) là vô hại trên rootfs dùng riêng cho app.
    final chmodResult = await Process.run('chmod', ['-R', 'a+rx', rootfs]);
    if (chmodResult.exitCode != 0) {
      _log('⚠️ chmod -R a+rX $rootfs thất bại (exit ${chmodResult.exitCode}): '
          '${chmodResult.stderr}');
    }

    final shLink = Link('$rootfs/bin/sh');
    if (!shLink.existsSync()) {
      try {
        if (File('$rootfs/bin/sh').existsSync()) File('$rootfs/bin/sh').deleteSync();
        shLink.createSync('busybox');
        _log('✅ Đã tạo /bin/sh -> busybox.');
      } catch (e) {
        _log('ℹ️ /bin/sh đã tồn tại từ tarball (bình thường).');
      }
    }

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    onProgress(1.0);
    _log('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  // ---- Gọi JNI thay vì Process.start ----
  Future<Process> start({
    required List<String> command,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
  }) async {
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

    // 🔥 Thêm -v 5 để debug
    final args = <String>[
      '-v', '5',
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
      'COLUMNS': '80',
      'LINES': '24',
      'PROOT_NO_SECCOMP': '1',
    };

    final loader32 = '$libDir/libproot-loader32.so';
    if (File(loader32).existsSync()) {
      env['PROOT_LOADER_32'] = loader32;
    }

    _log('🚀 Khởi chạy JNI: $prootBin ${args.join(' ')}');
    _log('   PROOT_LOADER=$loaderPath');

    // Trả về FakeProcess NGAY để UI có thể lắng nghe stdout/stderr trong
    // lúc proot đang chạy, thay vì đợi tới khi có exitCode mới biết gì.
    final fake = FakeProcess(0, -1);
    _currentProcess = fake;

    // BUG CŨ: native đã có FakeProcess.addStdout()/addStderr() nhưng
    // không có gì gọi tới -> không bao giờ có log ngoài exit code.
    // Native giờ emit log real-time qua EventChannel 'alpine_runner/proot_logs';
    // subscribe TRƯỚC khi gọi runProot() để không bỏ lỡ log của những
    // dòng đầu (bootstrap/execve/loader).
    final logSub = ProotJNI.onLog.listen((line) {
      _log(line);
      final bytes = utf8.encode('$line\n');
      if (line.contains('[proot:stderr]') || line.contains('[launcher]')) {
        fake.addStderr(bytes);
        onStderr?.call(line);
      } else {
        fake.addStdout(bytes);
        onStdout?.call(line);
      }
    });

    late final int exitCode;
    try {
      exitCode = await ProotJNI.runProot(
        prootBin,
        args,
        env,
      );
    } finally {
      await logSub.cancel();
      fake.closeStdout();
      fake.closeStderr();
    }

    _log('Process exited with code $exitCode');
    fake.setExitCode(exitCode);

    return fake;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}