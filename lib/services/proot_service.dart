import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
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

  /// dart:io không có API chmod trực tiếp trên File (FileMode chỉ dùng cho
  /// chế độ MỞ file - read/write/append - không phải quyền Unix). Phải gọi
  /// binary `chmod` thật của hệ thống (Android có sẵn qua toybox).
  Future<void> _chmodExecutable(String path) async {
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw Exception('chmod thất bại cho $path: ${result.stderr}');
    }
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

    // Tạo /bin/sh từ libbusybox.so đã nhúng trong APK (jniLibs)
    final libDir = await NativeBridge.getNativeLibraryDir();
    final busyboxSrc = '$libDir/libbusybox.so';
    final busyboxDst = '$rootfs/bin/busybox';
    final shPath = '$rootfs/bin/sh';

    if (File(busyboxSrc).existsSync()) {
      onLog('Copy libbusybox.so vào rootfs...');
      await File(busyboxSrc).copy(busyboxDst);
      await _chmodExecutable(busyboxDst);

      onLog('Tạo symlink /bin/sh -> busybox');
      try {
        // Dùng API symlink của chính Dart thay vì gọi tiến trình `ln` ngoài -
        // không phụ thuộc PATH của hệ thống, chắc chắn tồn tại trên mọi máy.
        if (File(shPath).existsSync() || Link(shPath).existsSync()) {
          await File(shPath).delete();
        }
        await Link(shPath).create('/bin/busybox', recursive: true);
      } catch (e) {
        onLog('Không thể tạo symlink ($e), copy busybox thành sh');
        final shFile = File(shPath);
        await shFile.writeAsBytes(File(busyboxDst).readAsBytesSync());
        await _chmodExecutable(shPath);
      }
      onLog('Shell /bin/sh đã sẵn sàng.');
    } else {
      onLog('CẢNH BÁO: Không tìm thấy libbusybox.so trong native libs!');
    }

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    File('$rootfs/etc/resolv.conf').writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

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
        // libproot.so được patchelf --set-rpath '$ORIGIN' lúc build (xem
        // fetch_native_binaries.sh) nên tự tìm libtalloc.so cùng thư mục.
        // Vẫn set LD_LIBRARY_PATH trỏ đúng nativeLibraryDir làm phương án
        // dự phòng nếu rpath không áp dụng được trên máy nào đó.
        // KHÔNG set PROOT_LOADER: bản proot hiện đại tự giải nén loader nội
        // bộ vào PROOT_TMP_DIR, không cần file loader rời (trước đây script
        // tạo 'libprootloader.so' giả - không phải ELF - đã bị loại bỏ).
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