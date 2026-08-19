import 'package:flutter/services.dart';

class ProotJNI {
  static const MethodChannel _channel = MethodChannel('alpine_runner/proot');

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