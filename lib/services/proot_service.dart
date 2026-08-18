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
    // Không còn kiểm tra /bin/sh: chuyển sang gọi trực tiếp "busybox sh"
    // (multi-call binary, không cần symlink riêng - xem hàm start()).
    // Chỉ cần chắc chắn /bin/busybox (file thật, không phải symlink) tồn
    // tại và có quyền exec là đủ để chạy được.
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

    // QUAN TRỌNG: phải xử lý riêng symlink. Alpine minirootfs có hàng chục
    // symlink (mọi applet busybox: /bin/sh, /bin/ls, /bin/cat... đều trỏ
    // tới /bin/busybox). package:tar cho biết chính xác entry nào là
    // TypeFlag.symlink kèm linkName - khác với package:archive từng bị
    // nhầm các symlink này thành thư mục rỗng.
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
          // Regular file (và các type ít gặp khác coi như file thường)
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

    // Cấp lại quyền thực thi cho /bin/busybox - đây là file THẬT (không phải
    // symlink), nên không có lý do gì nó thiếu ở bước này trừ khi tar.gz
    // tải về bị hỏng/thiếu.
    final busyboxReal = '$rootfs/bin/busybox';
    if (File(busyboxReal).existsSync()) {
      await _chmodExecutable(busyboxReal);
    } else {
      throw Exception('/bin/busybox không tồn tại sau khi giải nén - '
          'tar.gz tải về có thể bị hỏng/thiếu. Thử tải lại.');
    }

    // Cố gắng tạo /bin/sh -> busybox cho TIỆN (một số script bên trong rootfs
    // có shebang "#!/bin/sh"), nhưng KHÔNG bắt buộc: dù package:tar giờ đã
    // tạo symlink đúng ngay từ bước giải nén ở trên, vẫn giữ bước dự phòng
    // này; nếu vì lý do gì đó vẫn thất bại, start() bên dưới không phụ
    // thuộc vào symlink này mà gọi thẳng "busybox sh".
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

    final tmpDir = '$filesDir/proot-tmp';
    if (await Directory(tmpDir).exists()) {
      await Directory(tmpDir).delete(recursive: true);
    }
    Directory(tmpDir).createSync(recursive: true);

    if (command.isEmpty) {
      command = ['/bin/sh', '-l'];
    }

    // Không phụ thuộc symlink /bin/sh - dù package:tar giờ tạo symlink đúng,
    // vẫn giữ đường an toàn này: gọi busybox multi-call binary trực tiếp
    // ("busybox sh ...") hoạt động y hệt "sh ..." mà không cần symlink nào.
    final effectiveCommand = List<String>.from(command);
    if (effectiveCommand.isNotEmpty && effectiveCommand.first == '/bin/sh') {
      effectiveCommand
        ..removeAt(0)
        ..insertAll(0, ['/bin/busybox', 'sh']);
      _log('ℹ️ Đổi lệnh khởi chạy: /bin/sh -> /bin/busybox sh (không cần symlink)');
    }

    // Không còn cần bind /host-libs hay đường dẫn host nào vào argv: mọi
    // path trong `command` đều là guest path (bên trong -r rootfs), proot
    // tự dịch. libtalloc.so/libandroid-shmem.so được tìm qua rpath $ORIGIN
    // (đã patch lúc build) + LD_LIBRARY_PATH trỏ thẳng nativeLibraryDir.
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

    // QUAN TRONG (fix W^X "execve(...): Permission denied"): ban proot cua
    // Termux cho Android khong execve() thang file trong rootfs. No dung
    // mot "loader" rieng (nam trong nativeLibraryDir - noi DUY NHAT duoc
    // Android cho phep exec bat chap SELinux W^X) de tu doc/anh xa ELF vao
    // bo nho roi nhay vao entry point, thay vi goi execve() that su tren
    // file nam trong /data/user/0/.../alpine-rootfs (bi chan). Neu khong
    // khai bao PROOT_LOADER, proot roi ve execve() thang -> loi da gap.
    final loaderPath = '$libDir/libproot-loader.so';
    final loader32Path = '$libDir/libproot-loader32.so';
    if (!File(loaderPath).existsSync()) {
      throw Exception(
        'Không tìm thấy $loaderPath. Cần build lại APK với '
        'scripts/fetch_native_binaries.sh bản mới (đã bổ sung tải '
        'libexec/proot/loader từ gói .deb của Termux).',
      );
    }

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
    if (File(loader32Path).existsSync()) {
      env['PROOT_LOADER_32'] = loader32Path;
    }

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');
    _log('   PROOT_LOADER=$loaderPath');

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