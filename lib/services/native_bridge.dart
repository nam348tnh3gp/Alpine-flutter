import 'package:flutter/services.dart';

/// Cầu nối sang Kotlin để lấy `applicationInfo.nativeLibraryDir`.
/// Đây là thư mục DUY NHẤT trên Android 10+ mà app được phép exec file
/// trực tiếp (W^X exemption), vì hệ thống tự cấp quyền +x khi extract
/// các file `lib*.so` từ APK vào đây lúc cài đặt.
class NativeBridge {
  static const _channel = MethodChannel('alpine_runner/native');

  /// Trả về đường dẫn kiểu: /data/app/~~xxxx/com.example.alpinerunner-yyyy/lib/arm64
  static Future<String> getNativeLibraryDir() async {
    final dir = await _channel.invokeMethod<String>('getNativeLibraryDir');
    if (dir == null) {
      throw StateError('Không lấy được nativeLibraryDir');
    }
    return dir;
  }

  static Future<String> getFilesDir() async {
    final dir = await _channel.invokeMethod<String>('getFilesDir');
    if (dir == null) {
      throw StateError('Không lấy được filesDir');
    }
    return dir;
  }

  static Future<String> getAbi() async {
    final abi = await _channel.invokeMethod<String>('getAbi');
    return abi ?? 'arm64-v8a';
  }
}
