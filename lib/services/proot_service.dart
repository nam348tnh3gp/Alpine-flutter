import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tar/tar.dart';
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

    // package:tar KHÔNG giữ execute bit — tất cả file được tạo với 0644.
    // Kernel vẫn kiểm tra permission bit (độc lập với SELinux), nên dù
    // targetSdk=28 mở W^X thì busybox/apk/... vẫn bị "Permission denied"
    // nếu thiếu bước này.
    _log('🔧 Cấp quyền execute cho binary trong rootfs...');
    for (final binDir in ['bin', 'sbin', 'usr/bin', 'usr/sbin', 'usr/lib/apk']) {
      final dir = Directory('$rootfs/$binDir');
      if (!dir.existsSync()) continue;
      await Process.run('chmod', ['-R', 'a+x', dir.path]);
    }

    // Đảm bảo /bin/sh symlink tồn tại
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

    // Loader nằm trong nativeLibraryDir — luôn exec-able trên mọi Android/API.
    // Cần cho 2 lý do độc lập:
    //   1) SELinux W^X (targetSdk>=29 chặn execve từ /data/...)
    //      → targetSdk=28 giải quyết lý do này, nhưng loader vẫn cần cho #2.
    //   2) ELF interpreter: Alpine dùng musl, binary của nó khai ELF interpreter
    //      là /lib/ld-musl-aarch64.so.1. File này không tồn tại trên Android.
    //      Kernel không thể exec binary musl dù SELinux cho phép — nó tìm
    //      interpreter theo đường dẫn thật, không qua proot remapping.
    //      Loader giải quyết bằng cách tự đọc/map ELF vào memory, không nhờ
    //      kernel exec interpreter → cần loader trên MỌI targetSdk.
    // Không cần copy loader ra filesDir: nativeLibraryDir luôn exec-able.
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

    final env = <String, String>{
      'PROOT_TMP_DIR': tmpDir,
      'PROOT_LOADER': loaderPath,
      'LD_LIBRARY_PATH': libDir,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'TERM': 'xterm-256color',
      'COLUMNS': '80',
      'LINES': '24',
    };

    final loader32 = '$libDir/libproot-loader32.so';
    if (File(loader32).existsSync()) {
      env['PROOT_LOADER_32'] = loader32;
    }

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');
    _log('   PROOT_LOADER=$loaderPath');

    final process = await Process.start(
      prootBin,
      args,
      environment: env,
      runInShell: false,
    );

    process.stderr.transform(utf8.decoder).listen((s) {
      _log('[proot] $s');
      onStderr?.call(s);
    });
    process.stdout.transform(utf8.decoder).listen((s) => onStdout?.call(s));
    process.exitCode.then((code) => _log('Process exited with code $code'));

    _currentProcess = process;
    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}