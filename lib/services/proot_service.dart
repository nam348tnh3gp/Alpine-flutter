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

    // FIX: KHÔNG dùng parser tar thuần Dart (package:archive) nữa - nó
    // không xử lý symlink (biến mọi symlink, kể cả /bin/sh -> busybox,
    // thành thư mục rỗng), gây lỗi "execve(/bin/sh): No such file or
    // directory" khi proot chạy. Dùng busybox thật (đã có sẵn trong
    // jniLibs, tải bởi scripts/fetch_native_binaries.sh) để giải nén,
    // giữ đúng symlink/permission như tar thật.
    final busyboxSrc = '$libDir/libbusybox.so';
    if (!File(busyboxSrc).existsSync()) {
      throw Exception(
        'Không tìm thấy libbusybox.so trong native libs ($busyboxSrc). '
        'Kiểm tra bước "Tải native binaries" trong .github/workflows/build.yml '
        'đã tải busybox-static thành công chưa.',
      );
    }

    onLog('Giải nén rootfs bằng busybox tar (giữ đúng symlink)...');
    onProgress(0.87);
    final result = await Process.run(busyboxSrc, [
      'tar',
      'xzf',
      tarGzPath,
      '-C',
      rootfs,
    ]);
    if (result.exitCode != 0) {
      throw Exception(
        'Giải nén rootfs thất bại (busybox tar exit=${result.exitCode}): '
        '${result.stderr}',
      );
    }
    onProgress(0.95);

    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    // Không cần tự copy busybox / tự tạo symlink /bin/sh nữa: tarball gốc
    // của Alpine đã có sẵn /bin/sh -> busybox đúng nghĩa, giờ được giải
    // nén thật sự bằng busybox tar ở trên.

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    onProgress(1.0);
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
      '-w', '/root',
      ...command,
    ];

    onLog('Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: {
        'PROOT_TMP_DIR': tmpDir,
        'LD_LIBRARY_PATH': libDir,
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': '/root',
        'TERM': 'xterm-256color',
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
      onLog('Process exited with code $code');
    });

    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}
