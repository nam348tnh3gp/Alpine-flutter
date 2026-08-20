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
    Map<String, String> env,
  ) async {
    final result = await _channel.invokeMethod('runProot', {
      'prootPath': prootPath,
      'args': args,
      'env': env,
    });
    return result as int;
  }

  static Future<int> writeToPty(List<int> data) async {
    final result = await _channel.invokeMethod('writeToPty', {
      'data': Uint8List.fromList(data),
    });
    return result as int;
  }
}