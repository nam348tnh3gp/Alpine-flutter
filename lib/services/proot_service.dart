import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'native_bridge.dart';

/// Client tương tác với Docker Registry OCI (giống proot-distro)
class DockerRegistryClient {
  static const String registry = 'registry-1.docker.io';
  static const String authService = 'registry.docker.io';

  final String image; // 'library/alpine'

  DockerRegistryClient(this.image);

  /// Lấy token xác thực (anonymous)
  Future<String> _getToken(String scope) async {
    final url = Uri.parse(
        'https://auth.docker.io/token?service=$authService&scope=repository:$image:pull');
    final response = await http.get(url);
    if (response.statusCode != 200) {
      throw Exception('Không lấy được token: ${response.body}');
    }
    final json = jsonDecode(response.body);
    return json['token'];
  }

  /// Lấy manifest cho tag, tự động chọn đúng kiến trúc
  Future<Map<String, dynamic>> getManifest(String tag, String arch) async {
    final token = await _getToken('repository:$image:pull');

    // Lấy manifest list (multi-arch)
    final listUrl = Uri.parse('https://$registry/v2/$image/manifests/$tag');
    final listResp = await http.get(listUrl, headers: {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.docker.distribution.manifest.list.v2+json',
    });
    if (listResp.statusCode != 200) {
      // Nếu không có manifest list, thử lấy manifest thường
      return _fetchManifest(token, tag);
    }

    final listJson = jsonDecode(listResp.body);
    final manifests = listJson['manifests'] as List;
    // Tìm manifest phù hợp với kiến trúc
    Map<String, dynamic>? selected;
    for (var m in manifests) {
      final platform = m['platform'] as Map<String, dynamic>;
      if (platform['architecture'] == arch) {
        selected = m;
        break;
      }
    }
    if (selected == null) {
      throw Exception('Không tìm thấy manifest cho kiến trúc $arch');
    }

    final digest = selected['digest'];
    // Tải manifest cụ thể
    return _fetchManifest(token, digest);
  }

  Future<Map<String, dynamic>> _fetchManifest(String token, String ref) async {
    final url = Uri.parse('https://$registry/v2/$image/manifests/$ref');
    final response = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
      'Accept': 'application/vnd.docker.distribution.manifest.v2+json',
    });
    if (response.statusCode != 200) {
      throw Exception('Lỗi tải manifest: ${response.body}');
    }
    return jsonDecode(response.body);
  }

  /// Tải blob (layer) dưới dạng bytes
  Future<List<int>> downloadBlob(String digest) async {
    final token = await _getToken('repository:$image:pull');
    final url = Uri.parse('https://$registry/v2/$image/blobs/$digest');
    final response = await http.get(url, headers: {
      'Authorization': 'Bearer $token',
    });
    if (response.statusCode != 200) {
      throw Exception('Lỗi tải blob: ${response.body}');
    }
    return response.bodyBytes;
  }
}

/// Hàm tiện ích giải nén tar.gz hoặc tar
void extractTarGz(List<int> bytes, String targetDir) {
  // Kiểm tra nếu là gzip (magic bytes 1F 8B)
  bool isGzip = bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;
  List<int> data = bytes;
  if (isGzip) {
    data = GZipDecoder().decodeBytes(bytes);
  }
  final archive = TarDecoder().decodeBytes(data);
  for (final file in archive) {
    final outPath = '$targetDir/${file.name}';
    if (file.isFile) {
      final outFile = File(outPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(file.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

class PRootService {
  static const _alpineImage = 'library/alpine';
  static const _alpineTag = '3.19'; // có thể thay đổi

  static const _archMap = {
    'arm64-v8a': 'aarch64',
    'armeabi-v7a': 'arm',
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
    // Kiểm tra file đặc trưng của Alpine
    return File('$rootfs/etc/alpine-release').existsSync();
  }

  Future<void> bootstrap({required void Function(double) onProgress}) async {
    final abi = await NativeBridge.getAbi();
    final dockerArch = _archMap[abi] ?? 'aarch64';
    final rootfs = await _rootfsDir();
    final filesDir = await NativeBridge.getFilesDir();

    // Xóa rootfs cũ nếu có
    if (await Directory(rootfs).exists()) {
      await Directory(rootfs).delete(recursive: true);
    }
    Directory(rootfs).createSync(recursive: true);

    onLog('🔄 Tải Alpine $dockerArch từ Docker registry...');

    final client = DockerRegistryClient(_alpineImage);
    final manifest = await client.getManifest(_alpineTag, dockerArch);
    final layers = manifest['layers'] as List;

    int total = layers.length;
    int current = 0;

    for (var layer in layers) {
      final digest = layer['digest'];
      onLog('📥 Tải layer ${++current}/$total: $digest');
      final blobBytes = await client.downloadBlob(digest);
      onLog('📦 Giải nén layer...');
      extractTarGz(blobBytes, rootfs);
      onProgress(current / total);
    }

    // Tạo các thư mục runtime cần thiết
    for (final d in ['proc', 'sys', 'dev', 'tmp', 'root']) {
      Directory('$rootfs/$d').createSync(recursive: true);
    }

    // Cấu hình DNS (giống proot-distro)
    final resolvConf = File('$rootfs/etc/resolv.conf');
    resolvConf.writeAsStringSync('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

    // Cấu hình hosts
    final hosts = File('$rootfs/etc/hosts');
    hosts.writeAsStringSync('127.0.0.1 localhost\n::1 localhost ip6-localhost\n');

    // Đánh dấu đã cài
    File('$rootfs/.installed').createSync();

    onLog('✅ Cài đặt Alpine hoàn tất tại $rootfs');
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

    // Mặc định shell nếu không có command
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

    onLog('🚀 Khởi chạy: $prootBin ${args.join(' ')}');

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