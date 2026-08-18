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
    return File('$rootfs/etc/alpine-release').existsSync();
  }

  // 🔥 Tạo symlink cho busybox applet
  Future<String> _createBusyboxSymlink(String applet, String libDir) async {
    final filesDir = await NativeBridge.getFilesDir();
    final symlinkDir = '$filesDir/busybox-links';
    await Directory(symlinkDir).create(recursive: true);
    final linkPath = '$symlinkDir/$applet';
    
    final busyboxPath = '$libDir/libbusybox.so';
    if (!File(linkPath).existsSync()) {
      await Process.run('ln', ['-sf', busyboxPath, linkPath]);
      _log('✅ Đã tạo symlink: $applet -> libbusybox.so');
    }
    return linkPath;
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
      if (total > 0) onProgress(received / total * 0.85);
    }
    await sink.close();

    // 🔥 Tạo symlink tar -> libbusybox.so
    final tarLink = await _createBusyboxSymlink('tar', libDir);
    _log('📦 Giải nén rootfs bằng busybox tar...');
    onProgress(0.87);

    final result = await Process.run(
      tarLink,
      ['xzf', tarGzPath, '-C', rootfs],
      environment: {
        'PATH': '/bin:/system/bin:/system/xbin',
      },
    );

    if (result.exitCode != 0) {
      _log('❌ Lỗi giải nén: exitCode=${result.exitCode}');
      _log('stderr: ${result.stderr}');

      final hostTar = '/system/bin/tar';
      if (File(hostTar).existsSync()) {
        _log('🔄 Thử giải nén bằng host tar...');
        final result2 = await Process.run(
          hostTar,
          ['-xzf', tarGzPath, '-C', rootfs],
        );
        if (result2.exitCode != 0) {
          throw Exception('Giải nén thất bại: ${result2.stderr}');
        }
      } else {
        throw Exception('Giải nén rootfs thất bại: ${result.stderr}');
      }
    }

    onProgress(0.95);
    await File(tarGzPath).delete().catchError((_) {});

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // 🔥 Tạo /bin/sh nếu chưa có
    final shPath = '$rootfs/bin/sh';
    if (!File(shPath).existsSync()) {
      _log('⚠️ /bin/sh không tồn tại! Tạo từ busybox...');
      final busyboxPath = '$libDir/libbusybox.so';
      await File(busyboxPath).copy('$rootfs/bin/busybox');
      await Process.run('chmod', ['+x', '$rootfs/bin/busybox']);
      
      try {
        await Process.run('ln', ['-sf', '/bin/busybox', shPath]);
        _log('✅ Đã tạo symlink /bin/sh -> busybox');
      } catch (e) {
        _log('⚠️ Copy busybox thành sh');
        await File(busyboxPath).copy(shPath);
        await Process.run('chmod', ['+x', shPath]);
      }
    }

    if (File(shPath).existsSync()) {
      _log('✅ Shell đã sẵn sàng!');
    } else {
      _log('❌ VẪN CHƯA CÓ /bin/sh!');
    }

    onProgress(1.0);
    _log('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
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

    if (!File(prootBin).existsSync()) {
      throw Exception('Không tìm thấy libproot.so tại: $prootBin');
    }

    final tmpDir = '$filesDir/proot-tmp';
    if (await Directory(tmpDir).exists()) {
      await Directory(tmpDir).delete(recursive: true);
    }
    Directory(tmpDir).createSync(recursive: true);

    // 🔥 Tạo symlink sh -> libbusybox.so nếu cần
    final shLink = await _createBusyboxSymlink('sh', libDir);

    // Nếu command là /bin/sh và không tồn tại, dùng symlink
    if (command.isEmpty || command[0] == '/bin/sh') {
      final shPath = '$rootfs/bin/sh';
      if (!File(shPath).existsSync()) {
        _log('⚠️ /bin/sh không tồn tại! Dùng busybox symlink');
        command = [shLink, '-l'];
      } else {
        command = ['/bin/sh', '-l'];
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

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: {
        'PROOT_TMP_DIR': tmpDir,
        'LD_LIBRARY_PATH': '/host-libs',
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/host-libs',
        'HOME': '/root',
        'TERM': 'xterm-256color',
        'COLUMNS': '80',
        'LINES': '24',
      },
      runInShell: false,
    );

    _currentProcess = process;
    process.stdout.transform(utf8.decoder).listen((s) {
      onStdout?.call(s);
    });
    process.stderr.transform(utf8.decoder).listen((s) {
      onStderr?.call(s);
    });

    process.exitCode.then((code) {
      _log('Process exited with code $code');
    });

    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}