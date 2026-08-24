import 'package:flutter/services.dart';

class ProotJNI {
  static const MethodChannel _channel = MethodChannel('alpine_runner/proot');
  static const EventChannel _logChannel = EventChannel('alpine_runner/proot_logs');

  static Stream<String>? _logStream;

  static Stream<String> get onLog {
    _logStream ??= _logChannel
        .receiveBroadcastStream()
        .map((event) => event.toString());
    return _logStream!;
  }

  static Future<int> runProot(
    String prootPath,
    List<String> args,
    Map<String, String> env, {
    int rows = 24,
    int cols = 80,
    String sessionId = 'default',
  }) async {
    final result = await _channel.invokeMethod('runProot', {
      'prootPath': prootPath,
      'args': args,
      'env': env,
      'rows': rows,
      'cols': cols,
      'sessionId': sessionId,
    });
    return result as int;
  }

  static Future<int> writeToPty(List<int> data, {String sessionId = 'default'}) async {
    final result = await _channel.invokeMethod('writeToPty', {
      'data': Uint8List.fromList(data),
      'sessionId': sessionId,
    });
    return result as int;
  }

  static Future<void> killProot({String sessionId = 'default'}) async {
    await _channel.invokeMethod('killProot', {
      'sessionId': sessionId,
    });
  }

  static Future<void> resizePty(int width, int height, {String sessionId = 'default'}) async {
    await _channel.invokeMethod('resizePty', {
      'width': width,
      'height': height,
      'sessionId': sessionId,
    });
  }
}
