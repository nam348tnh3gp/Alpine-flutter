import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

class PRootService {
  static const _alpineVersion = '3.19.9';

  static const _alpineArchMap = {
    'arm64-v8a': 'aarch64',
    'armeabi-v7a': 'armv7',
  };

  final void Function(String line) onLog;
  Process? _currentProcess;

  PRootService({required this.onLog});

  Future<String> _rootfsDir() async {
    final filesDir = await NativeBridge.getFilesDir();
    return '$filesDir/alpine-rootfs';
  }

  Future<bool> isInstalled() async {
    final rootfs = await _rootfsDir();
    return File('$rootfs/etc/alpine-release').existsSync();
  }

  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    final alpineArch = _alpineArchMap[abi] ?? 'aarch64';
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();
    final libDir = await NativeBridge.getNativeLibraryDir();

    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    final url = 'https://dl-cdn.alpinelinux.org/alpine/v${_alpineVersion.substring(0, 4)}/'
        'releases/$alpineArch/alpine-minirootfs-$_alpineVersion-$alpineArch.tar.gz';

    onLog('Đang tải Alpine minirootfs ($alpineArch)...\n$url');

    final tarGzPath = '$filesDir/alpine-rootfs.tar.gz';
    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception('Tải rootfs thất bại: HTTP ${response.statusCode}. '
          'Kiểm tra lại URL/version Alpine trong proot_service.dart');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = File(tarGzPath).openWrite();
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) onProgress(received / total * 0.85);
    }
    await sink.close();

    // 🔥 GIẢI NÉN BẰNG HOST TAR (Android có sẵn)
    onLog('Giải nén bằng host tar...');
    onProgress(0.87);

    // Tìm đường dẫn tar trên Android
    String? tarPath;
    for (var p in ['/system/bin/tar', '/bin/tar', '/system/xbin/tar']) {
      if (File(p).existsSync()) {
        tarPath = p;
        break;
      }
    }
    if (tarPath == null) {
      throw Exception('Không tìm thấy tar trên hệ thống.');
    }

    final result = await Process.run(
      tarPath,
      ['-xzf', tarGzPath, '-C', rootfs],
    );

    if (result.exitCode != 0) {
      throw Exception(
        'Giải nén rootfs thất bại: ${result.stderr}',
      );
    }

    onProgress(0.95);
    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    // Tạo thư mục runtime
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // DNS
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 🔥 TẠO /bin/sh BẰNG CÁCH COPY BUSYBOX (KHÔNG DÙNG SYMLINK)
    final busyboxSrc = '$libDir/libbusybox.so';
    if (!File(busyboxSrc).existsSync()) {
      throw Exception('Không tìm thấy libbusybox.so tại $busyboxSrc');
    }

    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      onLog('📦 Copy libbusybox.so thành /bin/sh...');
      await File(busyboxSrc).copy(shPath);
      await _chmodX(shPath);
    } else {
      // Kiểm tra xem file có thực sự là executable không
      try {
        final test = await Process.run(shPath, ['--version']);
        if (test.exitCode != 0) {
          onLog('⚠️ /bin/sh hiện có không chạy được, ghi đè bằng busybox...');
          await File(busyboxSrc).copy(shPath);
          await _chmodX(shPath);
        }
      } catch (_) {
        await File(busyboxSrc).copy(shPath);
        await _chmodX(shPath);
      }
    }

    // Đảm bảo busybox cũng có trong /bin (phòng khi cần)
    final busyboxDst = '$rootfs/bin/busybox';
    if (!File(busyboxDst).existsSync()) {
      await File(busyboxSrc).copy(busyboxDst);
      await _chmodX(busyboxDst);
    }

    onProgress(1.0);
    onLog('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  Future<void> _chmodX(String path) async {
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {
      // fallback: dùng chmod shell
      await Process.run('/system/bin/chmod', ['+x', path]);
    }
  }

  Future<Process> start({
    required List<String> command,
    void Function(String)? onStdout,
    void Function(String)? onStderr,
  }) async {
    final libDir = await NativeBridge.getNativeLibraryDir();
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    final prootBin = '$libDir/libproot.so';
    final tmpDir = '$filesDir/proot-tmp';
    Directory(tmpDir).createSync(recursive: true);

    if (command.isEmpty) {
      command = ['/bin/sh', '-l'];
    }

    final args = <String>[
      '-0',
      '--link2symlink',
      '--kill-on-exit',
      '-r', rootfs,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '$tmpDir:/tmp',
      '-b', '$libDir:/host-libs',
      '-w', '/root',
      ...command,
    ];

    onLog('🚀 Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: {
        'PROOT_TMP_DIR': tmpDir,
        'LD_LIBRARY_PATH': '/host-libs',
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/host-libs',
        'HOME': '/root',
        'TERM': 'xterm-256color',
      },
      runInShell: false,
    );

    _currentProcess = process;
    process.stdout.transform(utf8.decoder).listen((s) {
      onStdout?.call(s);
      print('STDOUT: $s');
    });
    process.stderr.transform(utf8.decoder).listen((s) {
      onStderr?.call(s);
      print('STDERR: $s');
    });

    process.exitCode.then((code) {
      onLog('Process exited with code $code');
    });

    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}