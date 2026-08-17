import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

class PRootService {
  static const _alpineVersion = '3.19.9'; // Phiên bản mới nhất có netboot

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

    // Xóa rootfs cũ nếu có
    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    // 🔥 DÙNG NETBOOT (chứa full rootfs + kernel/initramfs)
    final url = 'https://dl-cdn.alpinelinux.org/alpine/v${_alpineVersion.substring(0, 4)}/'
        'releases/$alpineArch/alpine-netboot-$_alpineVersion-$alpineArch.tar.gz';

    onLog('Đang tải Alpine netboot rootfs ($alpineArch)...\n$url');

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
      if (total > 0) onProgress(received / total);
    }
    await sink.close();

    onLog('Giải nén rootfs...');
    final bytes = File(tarGzPath).readAsBytesSync();
    final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    
    // Giải nén tất cả file vào rootfs
    for (final file in archive) {
      final outPath = '$rootfs/${file.name}';
      if (file.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(file.content as List<int>);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
    File(tarGzPath).deleteSync();

    // 🔥 XỬ LÝ CẤU TRÚC NETBOOT
    // Netboot có cấu trúc: /boot (chứa kernel/initramfs) + / (rootfs)
    // Cần đảm bảo /bin/sh tồn tại
    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      onLog('Netboot có cấu trúc đặc biệt, đang tạo symlink...');
      
      // Kiểm tra xem busybox có trong /bin không
      final busyboxPath = '$rootfs/bin/busybox';
      if (File(busyboxPath).existsSync()) {
        // Tạo symlink /bin/sh -> busybox
        onLog('Tạo symlink /bin/sh -> busybox');
        try {
          await Process.run('ln', ['-sf', '/bin/busybox', shPath]);
        } catch (e) {
          // Nếu không thể tạo symlink, copy busybox thành sh
          onLog('Không thể tạo symlink, copy busybox thành sh');
          final shFile = File(shPath);
          await shFile.writeAsBytes(File(busyboxPath).readAsBytesSync());
          await shFile.setMode(FileMode.ownerExecute);
        }
      } else {
        // Kiểm tra xem có thư mục con chứa rootfs không
        onLog('Kiểm tra cấu trúc thư mục netboot...');
        final subDirs = Directory(rootfs).listSync().whereType<Directory>().toList();
        
        for (final subDir in subDirs) {
          final subBinPath = '${subDir.path}/bin/sh';
          if (File(subBinPath).existsSync()) {
            onLog('Tìm thấy shell trong ${subDir.path}, di chuyển lên root...');
            // Di chuyển toàn bộ nội dung lên rootfs
            await _moveDirectoryContent(subDir.path, rootfs);
            break;
          }
        }
      }
    }

    // Tạo thư mục runtime cho proot
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // DNS
    File('$rootfs/etc/resolv.conf').writeAsStringSync('nameserver 8.8.8.8\n');

    onLog('Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  // Helper: di chuyển nội dung từ source sang dest
  Future<void> _moveDirectoryContent(String source, String dest) async {
    final sourceDir = Directory(source);
    if (!await sourceDir.exists()) return;

    await for (final entity in sourceDir.list()) {
      final targetPath = '$dest/${entity.path.split('/').last}';
      if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        await _moveDirectoryContent(entity.path, targetPath);
      }
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

    // Kiểm tra xem /bin/sh có tồn tại không
    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      onLog('⚠️ CẢNH BÁO: /bin/sh không tồn tại!');
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
      '-w', '/root',
      ...command,
    ];

    onLog('Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: {
        'PROOT_TMP_DIR': tmpDir,
        'PROOT_LOADER': '$libDir/libprootloader.so',
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
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