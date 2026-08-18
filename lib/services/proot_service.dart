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
    onProgress(0.92);

    await File(tarGzPath).delete().catchError((_) => File(tarGzPath));

    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }
    File('$rootfs/etc/resolv.conf')
        .writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    final busyboxReal = '$rootfs/bin/busybox';
    if (File(busyboxReal).existsSync()) {
      await Process.run('chmod', ['755', busyboxReal]);
    } else {
      throw Exception('/bin/busybox không tồn tại sau khi giải nén.');
    }

    try {
      final shLink = Link('$rootfs/bin/sh');
      if (shLink.existsSync()) await shLink.delete();
      if (File('$rootfs/bin/sh').existsSync()) File('$rootfs/bin/sh').deleteSync();
      shLink.createSync('busybox');
      _log('✅ Đã tạo /bin/sh -> busybox.');
    } catch (e) {
      _log('ℹ️ Không tạo được symlink /bin/sh ($e) - không sao.');
    }

    onProgress(1.0);
    _log('✅ Hoàn tất cài đặt Alpine rootfs tại: $rootfs');
  }

  // === START (phiên bản tối giản, không loader, không bind mount) ===
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

    if (command.isEmpty) command = ['/bin/sh', '-l'];
    final effectiveCommand = List<String>.from(command);
    // Không cần đổi /bin/sh -> busybox vì rootfs đã có symlink
    // Nhưng nếu muốn an toàn, vẫn giữ
    if (effectiveCommand.isNotEmpty && effectiveCommand.first == '/bin/sh') {
      effectiveCommand.removeAt(0);
      effectiveCommand.insertAll(0, ['/bin/busybox', 'sh']);
      _log('ℹ️ Dùng busybox trong rootfs: /bin/busybox sh');
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
      ...effectiveCommand,
    ];

    final env = <String, String>{
      'PROOT_TMP_DIR': tmpDir,
      'LD_LIBRARY_PATH': libDir,
      'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'HOME': '/root',
      'TERM': 'xterm-256color',
      'COLUMNS': '80',
      'LINES': '24',
    };

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: env,
      runInShell: false,
    );

    process.stdout.transform(utf8.decoder).listen((s) => onStdout?.call(s));
    process.stderr.transform(utf8.decoder).listen((s) => onStderr?.call(s));
    process.exitCode.then((code) => _log('Process exited with code $code'));

    _currentProcess = process;
    return process;
  }

  void stop() {
    _currentProcess?.kill(ProcessSignal.sigterm);
    _currentProcess = null;
  }
}