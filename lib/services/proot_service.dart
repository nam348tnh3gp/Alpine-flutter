import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:tar/tar.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

/// Quản lý bootstrap Alpine rootfs + chạy proot. KHÔNG exec bất kỳ native
/// binary nào (tar/busybox...) trực tiếp trên host để giải nén - Android áp
/// seccomp-bpf cho tiến trình app, nhiều syscall mà tar/musl dùng bị chặn,
/// gây crash SIGSYS (exitCode âm, vd -31) ngay cả khi binary hợp lệ và có
/// quyền exec. Giải nén bằng package:tar thuần Dart (không qua syscall lạ
/// nào ngoài file I/O thông thường), có hỗ trợ symlink đầy đủ và đáng tin
/// cậy hơn package:archive (từng thiếu xử lý symlink cho định dạng TAR).
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

  Future<void> _chmodExecutable(String path) async {
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw Exception('chmod thất bại cho $path: ${result.stderr}');
    }
  }

  Future<bool> isInstalled() async {
    final rootfs = await _rootfsDir();
    final releaseOk = File('$rootfs/etc/alpine-release').existsSync();
    final busyboxOk = File('$rootfs/bin/busybox').existsSync();
    if (releaseOk && !busyboxOk) {
      _log('⚠️ Phát hiện rootfs cài dở từ lần trước (thiếu /bin/busybox) - sẽ cài lại.');
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
      if (total > 0) onProgress(received / total * 0.7);
    }
    await sink.close();

    _log('📦 Giải nén rootfs bằng package:tar (hỗ trợ symlink đầy đủ, không '
        'phụ thuộc archive package - biết có bug thiếu symlink cho định dạng '
        'TAR)...');
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
          if (linkFile.existsSync()) {
            await linkFile.delete();
          } else if (File(outPath).existsSync()) {
            File(outPath).deleteSync();
          }
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
    onProgress(0.92);

    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    final busyboxReal = '$rootfs/bin/busybox';
    if (File(busyboxReal).existsSync()) {
      await _chmodExecutable(busyboxReal);
    } else {
      throw Exception('/bin/busybox không tồn tại sau khi giải nén - '
          'tar.gz tải về có thể bị hỏng/thiếu. Thử tải lại.');
    }

    try {
      final shLink = Link('$rootfs/bin/sh');
      if (shLink.existsSync()) await shLink.delete();
      if (File('$rootfs/bin/sh').existsSync()) {
        File('$rootfs/bin/sh').deleteSync();
      }
      shLink.createSync('busybox');
      _log('✅ Đã tạo (best-effort) /bin/sh -> busybox.');
    } catch (e) {
      _log('ℹ️ Không tạo được symlink /bin/sh ($e) - không sao, sẽ dùng '
          '"busybox sh" trực tiếp khi chạy.');
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

    // ---- Tạo symlink sạch cho loader trong filesDir (cách 2) ----
    final loaderPath = '$libDir/libproot-loader.so';
    final loader32Path = '$libDir/libproot-loader32.so';
    if (!File(loaderPath).existsSync()) {
      throw Exception(
        'Không tìm thấy $loaderPath. Cần build lại APK với '
        'scripts/fetch_native_binaries.sh bản mới (đã bổ sung tải '
        'libexec/proot/loader từ gói .deb của Termux).',
      );
    }

    // Cấp quyền thực thi cho loader (dù đã có nhưng đảm bảo)
    await _chmodExecutable(loaderPath);
    if (File(loader32Path).existsSync()) {
      await _chmodExecutable(loader32Path);
    }

    final loaderSymlink = '$filesDir/loader';
    if (await File(loaderSymlink).exists()) {
      await File(loaderSymlink).delete();
    }
    await Process.run('ln', ['-sf', loaderPath, loaderSymlink]);
    _log('ℹ️ Tạo symlink loader: $loaderSymlink -> $loaderPath');

    String? loader32Symlink;
    if (File(loader32Path).existsSync()) {
      loader32Symlink = '$filesDir/loader32';
      if (await File(loader32Symlink).exists()) {
        await File(loader32Symlink).delete();
      }
      await Process.run('ln', ['-sf', loader32Path, loader32Symlink]);
      _log('ℹ️ Tạo symlink loader32: $loader32Symlink -> $loader32Path');
    }

    // ---- Xử lý tmpDir ----
    final tmpDir = '$filesDir/proot-tmp';
    if (await Directory(tmpDir).exists()) {
      await Directory(tmpDir).delete(recursive: true);
    }
    Directory(tmpDir).createSync(recursive: true);

    // ---- Xử lý command ----
    if (command.isEmpty) {
      command = ['/bin/sh', '-l'];
    }
    final effectiveCommand = List<String>.from(command);
    if (effectiveCommand.isNotEmpty && effectiveCommand.first == '/bin/sh') {
      effectiveCommand
        ..removeAt(0)
        ..insertAll(0, ['/bin/busybox', 'sh']);
      _log('ℹ️ Đổi lệnh khởi chạy: /bin/sh -> /bin/busybox sh (không cần symlink)');
    }

    // ---- Xây dựng args (cách 1: thêm --loader) ----
    final args = <String>[
      '-0',
      '--link2symlink',
      '--kill-on-exit',
      '--loader', loaderSymlink,          // <-- Thêm flag loader (cách 1)
      if (loader32Symlink != null) ...['--loader32', loader32Symlink],
      '-r', rootfs,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '$tmpDir:/tmp',
      '-w', '/root',
      ...effectiveCommand,
    ];

    // ---- Môi trường ----
    final env = <String, String>{
      'PROOT_TMP_DIR': tmpDir,
      'PROOT_LOADER': loaderSymlink,      // Vẫn giữ để an toàn
      if (loader32Symlink != null) 'PROOT_LOADER_32': loader32Symlink,
      'LD_LIBRARY_PATH': libDir,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'TERM': 'xterm-256color',
      'COLUMNS': '80',
      'LINES': '24',
    };

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');
    _log('   Loader: $loaderSymlink');

    final process = await Process.start(
      prootBin,
      args,
      environment: env,
      runInShell: false,
    );

    _currentProcess = process;
    process.stdout.transform(utf8.decoder).listen((s) => onStdout?.call(s));
    process.stderr.transform(utf8.decoder).listen((s) => onStderr?.call(s));
    process.exitCode.then((code) => _log('Process exited with code $code'));

    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}