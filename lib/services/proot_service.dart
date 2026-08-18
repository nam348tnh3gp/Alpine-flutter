import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

/// Quản lý bootstrap Alpine rootfs + chạy proot. KHÔNG exec bất kỳ native
/// binary nào (tar/busybox...) trực tiếp trên host để giải nén - Android áp
/// seccomp-bpf cho tiến trình app, nhiều syscall mà tar/musl dùng bị chặn,
/// gây crash SIGSYS (exitCode âm, vd -31) ngay cả khi binary hợp lệ và có
/// quyền exec. Giải nén bằng package:archive thuần Dart (không qua syscall
/// lạ nào ngoài file I/O thông thường mà Flutter vẫn dùng hằng ngày).
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
    // Kiểm tra CẢ HAI: alpine-release (rootfs đã giải nén) VÀ /bin/sh thực
    // sự resolve được (không phải symlink gãy). Nếu lần trước bootstrap bị
    // crash giữa chừng, alpine-release có thể đã tồn tại nhưng /bin/sh thì
    // chưa -> phải coi là CHƯA cài để tự động cài lại từ đầu.
    final releaseOk = File('$rootfs/etc/alpine-release').existsSync();
    final shOk = File('$rootfs/bin/sh').existsSync(); // existsSync() trên
    // File sẽ follow symlink và trả về false nếu target không tồn tại/gãy.
    if (releaseOk && !shOk) {
      _log('⚠️ Phát hiện rootfs cài dở từ lần trước (thiếu /bin/sh khả dụng) - sẽ cài lại.');
    }
    return releaseOk && shOk;
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

    _log('📦 Giải nén rootfs (Dart thuần, không exec native binary)...');
    onProgress(0.72);

    final bytes = File(tarGzPath).readAsBytesSync();
    final archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));

    // QUAN TRỌNG: phải xử lý riêng symlink. Alpine minirootfs có hàng chục
    // symlink (mọi applet busybox: /bin/sh, /bin/ls, /bin/cat... đều trỏ
    // tới /bin/busybox). Nếu coi mọi entry không phải file là "thư mục",
    // toàn bộ các symlink này biến thành thư mục rỗng sai, /bin/sh sẽ
    // KHÔNG tồn tại dù rootfs "giải nén thành công".
    var fileCount = 0, dirCount = 0, linkCount = 0;
    for (final entry in archive) {
      final outPath = '$rootfs/${entry.name}';

      if (entry.isSymbolicLink) {
        final target = entry.nameOfLinkedFile;
        final linkFile = Link(outPath);
        Directory(linkFile.path).parent.createSync(recursive: true);
        if (linkFile.existsSync()) {
          linkFile.deleteSync();
        } else if (File(outPath).existsSync()) {
          File(outPath).deleteSync();
        }
        linkFile.createSync(target, recursive: true);
        linkCount++;
      } else if (entry.isFile) {
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entry.content as List<int>);
        fileCount++;
      } else {
        Directory(outPath).createSync(recursive: true);
        dirCount++;
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

    // Cấp lại quyền thực thi cho các binary quan trọng - archive package giữ
    // nguyên file mode từ tar header trong đa số trường hợp, nhưng chmod lại
    // /bin/busybox cho chắc chắn (phòng khi mode bị mất khi ghi qua Dart IO).
    final busyboxReal = '$rootfs/bin/busybox';
    if (File(busyboxReal).existsSync()) {
      await _chmodExecutable(busyboxReal);
    }

    final shOk = File('$rootfs/bin/sh').existsSync();
    if (shOk) {
      _log('✅ Shell /bin/sh đã sẵn sàng (symlink -> busybox).');
    } else {
      _log('❌ VẪN CHƯA CÓ /bin/sh sau khi giải nén đúng cách - kiểm tra lại '
          'file tar.gz tải về có bị hỏng/thiếu không.');
      throw Exception('/bin/sh không tồn tại sau khi bootstrap.');
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
      ...command,
    ];

    _log('🚀 Khởi chạy: $prootBin ${args.join(' ')}');

    final process = await Process.start(
      prootBin,
      args,
      environment: {
        'PROOT_TMP_DIR': tmpDir,
        'LD_LIBRARY_PATH': libDir,
        'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        'HOME': '/root',
        'TERM': 'xterm-256color',
        'COLUMNS': '80',
        'LINES': '24',
      },
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