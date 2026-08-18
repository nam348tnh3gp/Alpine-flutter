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
      if (total > 0) onProgress(received / total * 0.80);
    }
    await sink.close();

    final busyboxSrc = '$libDir/libbusybox.so';
    onLog('📦 Kiểm tra libbusybox.so tại: $busyboxSrc');

    if (!File(busyboxSrc).existsSync()) {
      final altPaths = [
        '$libDir/../libbusybox.so',
        '/system/lib/libbusybox.so',
        '/data/local/tmp/libbusybox.so',
      ];
      String? foundPath;
      for (var p in altPaths) {
        if (File(p).existsSync()) {
          foundPath = p;
          break;
        }
      }

      if (foundPath != null) {
        onLog('✅ Tìm thấy libbusybox.so tại: $foundPath');
        await File(foundPath).copy(busyboxSrc);
        await _chmodX(busyboxSrc);
      } else {
        throw Exception(
          'Không tìm thấy libbusybox.so trong native libs ($busyboxSrc). '
          'Kiểm tra bước "Tải native binaries" trong .github/workflows/build.yml '
          'đã tải busybox-static thành công chưa.',
        );
      }
    }

    // 🔥 Tạo symlink busybox để gọi applet
    final busyboxBinDir = '$filesDir/busybox-bin';
    await Directory(busyboxBinDir).create(recursive: true);
    final busyboxLink = '$busyboxBinDir/busybox';
    await Process.run('ln', ['-sf', busyboxSrc, busyboxLink]);

    // 🔥 Hàm giải nén và kiểm tra
    Future<bool> _extractWithTar(String tarCmd) async {
      final result = await Process.run(
        tarCmd,
        ['-xzf', tarGzPath, '-C', rootfs],
        environment: {
          if (tarCmd == busyboxLink) 'LD_LIBRARY_PATH': libDir,
          'PATH': '/bin:/system/bin:/system/xbin',
        },
      );
      if (result.exitCode != 0) {
        onLog('❌ Lỗi giải nén với $tarCmd: exitCode=${result.exitCode}');
        onLog('stderr: ${result.stderr}');
        onLog('stdout: ${result.stdout}');
        return false;
      }
      // Kiểm tra file quan trọng
      if (!File('$rootfs/etc/alpine-release').existsSync()) {
        onLog('⚠️ Giải nén thành công nhưng không thấy /etc/alpine-release');
        return false;
      }
      return true;
    }

    onLog('Giải nén rootfs...');
    onProgress(0.85);

    // 1️⃣ Ưu tiên host tar
    final hostTar = '/system/bin/tar';
    bool extracted = false;
    if (File(hostTar).existsSync()) {
      onLog('Thử host tar: $hostTar');
      extracted = await _extractWithTar(hostTar);
    }

    // 2️⃣ Nếu host tar thất bại, dùng busybox tar
    if (!extracted) {
      onLog('🔄 Thử lại với busybox tar...');
      extracted = await _extractWithTar(busyboxLink);
    }

    if (!extracted) {
      throw Exception(
        'Giải nén rootfs thất bại cả 2 cách. Kiểm tra file tarball: $tarGzPath',
      );
    }

    onProgress(0.95);
    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 🔥 Kiểm tra và tạo /bin/sh nếu chưa có
    final shPath = '$rootfs/bin/sh';
    final busyboxDst = '$rootfs/bin/busybox';

    if (!File(shPath).existsSync()) {
      onLog('⚠️ /bin/sh không tồn tại! Tạo từ busybox...');
      // Copy busybox từ host vào rootfs/bin/
      await File(busyboxSrc).copy(busyboxDst);
      await _chmodX(busyboxDst);

      // Thử tạo symlink
      try {
        await Process.run('ln', ['-sf', '/bin/busybox', shPath]);
      } catch (e) {
        // Nếu không symlink được, copy busybox thành sh
        await File(busyboxSrc).copy(shPath);
        await _chmodX(shPath);
      }
    }

    // 🔥 Xác minh shell hoạt động
    onLog('🔍 Kiểm tra shell...');
    final testResult = await Process.run(
      shPath,
      ['-c', 'echo test'],
      workingDirectory: rootfs,
    );
    if (testResult.exitCode != 0 || testResult.stdout.trim() != 'test') {
      onLog('❌ Shell không hoạt động: ${testResult.stderr}');
      throw Exception('Shell không khả dụng. Kiểm tra busybox trong rootfs.');
    } else {
      onLog('✅ Shell hoạt động tốt');
    }

    onProgress(1.0);
    onLog('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  Future<void> _chmodX(String path) async {
    try {
      final result = await Process.run('chmod', ['+x', path]);
      if (result.exitCode != 0) {
        throw Exception('chmod +x $path thất bại: ${result.stderr}');
      }
    } catch (e) {
      onLog('⚠️ Không thể chmod $path: $e');
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