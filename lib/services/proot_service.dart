import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

class PRootService {
  static const _alpineVersion = '3.20.3';

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

    // 🔥 THAY ĐỔI: Dùng alpine-standard thay vì minirootfs
    final url = 'https://dl-cdn.alpinelinux.org/alpine/v${_alpineVersion.substring(0, 4)}/'
        'releases/$alpineArch/alpine-standard-$_alpineVersion-$alpineArch.tar.gz';

    onLog('Đang tải Alpine standard rootfs ($alpineArch)...\n$url');

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

    // Tạo thư mục runtime cho proot
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // DNS
    File('$rootfs/etc/resolv.conf').writeAsStringSync('nameserver 8.8.8.8\n');

    onLog('Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
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

    // 🔥 KHÔNG CẦN chuyển đổi command nữa, rootfs đã có /bin/sh
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
        // 🔥 KHÔNG CẦN LD_LIBRARY_PATH vì rootfs có thư viện riêng
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