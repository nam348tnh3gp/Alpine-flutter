import 'package:flutter/services.dart';

class ProotJNI {
  static const MethodChannel _channel = MethodChannel('alpine_runner/proot');

  // Trước đây log native (stdout/stderr của proot, lỗi execve/fork chi
  // tiết) không có đường nào về Dart -> chỉ nhận được exit code khi
  // runProot() trả về. EventChannel này nhận từng dòng log NGAY khi
  // native emit ra, độc lập với Future runProot() bên dưới.
  static const EventChannel _logChannel =
      EventChannel('alpine_runner/proot_logs');

  static Stream<String>? _logStream;

  /// Stream log chi tiết theo thời gian thực từ proot + launcher native.
  /// Phải subscribe TRƯỚC (hoặc gần như đồng thời với) khi gọi [runProot]
  /// để không bỏ lỡ các dòng log đầu tiên.
  static Stream<String> get onLog {
    _logStream ??= _logChannel
        .receiveBroadcastStream()
        .map((event) => event.toString());
    return _logStream!;
  }

  /// Gọi native fork+exec qua JNI, trả về exit code.
  /// Log chi tiết trong lúc chạy nằm ở [onLog], không nằm trong kết quả này.
  static Future<int> runProot(
    String prootPath,
    List<String> args,
    Map<String, String> env,
  ) async {
    final result = await _channel.invokeMethod('runProot', {
      'prootPath': prootPath,
      'args': args,
      'env': env,
    });
    return result as int;
  }
}