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

    // 🔥 CÁCH 2: Tạo symlink để gọi busybox đúng cách
    // Tạo thư mục tạm để chứa các symlink
    final tempBinDir = Directory('$filesDir/busybox-bin');
    if (await tempBinDir.exists()) {
      await tempBinDir.delete(recursive: true);
    }
    await tempBinDir.create(recursive: true);

    // Tạo symlink 'tar' trỏ đến libbusybox.so
    final tarLink = File('${tempBinDir.path}/tar');
    await Process.run('ln', ['-sf', busyboxSrc, tarLink.path]);

    onLog('✅ Đã tạo symlink tar -> busybox');

    // 🔥 GIẢI NÉN BẰNG BUSYBOX QUA SYMLINK
    onLog('Giải nén rootfs bằng busybox tar (qua symlink)...');
    onProgress(0.87);

    final result = await Process.run(
      tarLink.path,
      ['xzf', tarGzPath, '-C', rootfs],
      environment: {
        'LD_LIBRARY_PATH': libDir,
        'PATH': '/bin:/system/bin:/system/xbin',
      },
    );

    if (result.exitCode != 0) {
      onLog('❌ Lỗi giải nén: exitCode=${result.exitCode}');
      onLog('stderr: ${result.stderr}');
      onLog('stdout: ${result.stdout}');

      // Thử với host tar nếu busybox thất bại
      final hostTar = '/system/bin/tar';
      if (File(hostTar).existsSync()) {
        onLog('🔄 Thử giải nén bằng host tar...');
        final result2 = await Process.run(
          hostTar,
          ['-xzf', tarGzPath, '-C', rootfs],
        );
        if (result2.exitCode != 0) {
          throw Exception(
            'Giải nén rootfs thất bại cả 2 cách: '
            'busybox: ${result.stderr}, host tar: ${result2.stderr}',
          );
        }
        // Nếu host tar thành công, xóa file rỗng từ busybox
        await File('$rootfs/usr').delete(recursive: true).catchError((_) {});
      } else {
        throw Exception(
          'Giải nén rootfs thất bại (busybox tar exit=${result.exitCode}): '
          '${result.stderr}',
        );
      }
    }

    // Xóa thư mục tạm busybox-bin
    await tempBinDir.delete(recursive: true).catchError((_) {});

    onProgress(0.95);
    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    // Tạo thư mục runtime cho proot
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // DNS
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 🔥 KIỂM TRA VÀ TẠO /bin/sh
    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      onLog('⚠️ /bin/sh không tồn tại! Tạo từ busybox...');
      await File(busyboxSrc).copy('$rootfs/bin/busybox');
      await _chmodX('$rootfs/bin/busybox');
      
      // Tạo symlink /bin/sh -> busybox
      try {
        await Process.run('ln', ['-sf', '/bin/busybox', shPath]);
        onLog('✅ Đã tạo symlink /bin/sh -> busybox');
      } catch (e) {
        // Fallback: copy busybox thành sh
        onLog('⚠️ Không tạo được symlink, copy busybox thành sh');
        await File(busyboxSrc).copy(shPath);
        await _chmodX(shPath);
      }
    } else {
      onLog('✅ /bin/sh đã tồn tại');
    }

    // 🔥 KIỂM TRA THÊM
    if (File('$rootfs/bin/sh').existsSync()) {
      onLog('✅ Shell đã sẵn sàng!');
    } else {
      onLog('❌ VẪN CHƯA CÓ /bin/sh! Kiểm tra lại.');
      // Liệt kê nội dung /bin để debug
      try {
        final lsResult = await Process.run('ls', ['-la', '$rootfs/bin']);
        onLog('Nội dung /bin:\n${lsResult.stdout}');
      } catch (_) {}
    }

    onProgress(1.0);
    onLog('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  Future<void> _chmodX(String path) async {
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {
      // Fallback: dùng chmod 755
      await Process.run('chmod', ['755', path]);
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

    // Kiểm tra proot tồn tại
    if (!File(prootBin).existsSync()) {
      throw Exception('Không tìm thấy libproot.so tại: $prootBin');
    }

    final tmpDir = '$filesDir/proot-tmp';
    if (await Directory(tmpDir).exists()) {
      await Directory(tmpDir).delete(recursive: true);
    }
    Directory(tmpDir).createSync(recursive: true);

    if (command.isEmpty) {
      command = ['/bin/sh', '-l'];
    }

    // Kiểm tra shell
    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      onLog('⚠️ /bin/sh không tồn tại! Thử dùng busybox...');
      // Thử dùng busybox trực tiếp
      final busyboxHost = '$libDir/libbusybox.so';
      if (File(busyboxHost).existsSync()) {
        command = ['/host-libs/libbusybox.so', 'sh', '-l'];
        onLog('🔄 Chuyển sang dùng busybox từ host');
      } else {
        throw Exception(
          'Không tìm thấy shell: $shPath. '
          'Kiểm tra quá trình cài đặt rootfs.'
        );
      }
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