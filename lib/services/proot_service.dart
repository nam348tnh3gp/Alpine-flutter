import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

/// Quản lý toàn bộ vòng đời: tải rootfs Alpine (lần đầu mở app),
/// giải nén, và chạy proot KHÔNG chroot, KHÔNG cần root, dùng file
/// thực thi lấy từ nativeLibraryDir (libproot.so, libtalloc.so, libbusybox.so...).
///
/// LƯU Ý: các URL download bên dưới là VÍ DỤ và PHẢI được bạn xác minh còn
/// hoạt động (Alpine đổi version thường xuyên). Xem README.md mục
/// "Cập nhật nguồn tải rootfs".
class PRootService {
  static const _alpineVersion = '3.20.3';

  /// Map arch Android -> tên arch Alpine dùng trong URL minirootfs.
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

  /// Tải + giải nén Alpine minirootfs lần đầu chạy app.
  /// Chạy song song stream log ra UI qua [onLog].
  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    final alpineArch = _alpineArchMap[abi] ?? 'aarch64';
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    Directory(rootfs).createSync(recursive: true);

    final url = 'https://dl-cdn.alpinelinux.org/alpine/v${_alpineVersion.substring(0, 4)}/'
        'releases/$alpineArch/alpine-minirootfs-$_alpineVersion-$alpineArch.tar.gz';

    onLog('Đang tải Alpine minirootfs ($alpineArch)...\n$url');

    final tarGzPath = '$filesDir/alpine-minirootfs.tar.gz';
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

    // Thư mục runtime bắt buộc cho proot bind-mount
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // DNS cơ bản trong rootfs
    File('$rootfs/etc/resolv.conf').writeAsStringSync('nameserver 8.8.8.8\n');

    onLog('Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  /// Chạy shell (CLI) hoặc script khởi động X server + VNC (GUI) bên trong proot.
  /// [extraArgs] ví dụ: ['/bin/sh', '-l'] cho CLI, hoặc
  /// ['/usr/local/bin/start-gui.sh'] cho GUI.
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

    final args = <String>[
      '-0', // fake root bên trong (không cần root máy thật)
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
    process.stdout.transform(utf8.decoder).listen((s) => onStdout?.call(s));
    process.stderr.transform(utf8.decoder).listen((s) => onStderr?.call(s));
    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}
