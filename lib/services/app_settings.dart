import 'dart:convert';
import 'dart:io';
import 'native_bridge.dart';

/// Lưu trữ setting nhỏ (hiện tại: cỡ chữ terminal) vào
/// `<filesDir>/settings.json`. Không dùng SharedPreferences để tránh
/// thêm dependency — file JSON đủ cho nhu cầu hiện tại và dễ debug
/// (có thể `cat` từ adb shell).
class AppSettings {
  static const _kFontSize = 'fontSize';

  static Future<File> _file() async {
    final dir = await NativeBridge.getFilesDir();
    return File('$dir/settings.json');
  }

  static Future<Map<String, dynamic>> _load() async {
    try {
      final f = await _file();
      if (!f.existsSync()) return {};
      final raw = f.readAsStringSync();
      if (raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  static Future<double> getFontSize() async {
    final v = (await _load())[_kFontSize];
    if (v is num) return v.toDouble();
    return 14.0;
  }

  static Future<void> setFontSize(double v) async {
    try {
      final data = await _load();
      data[_kFontSize] = v;
      final f = await _file();
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(data));
    } catch (_) {
      // Bỏ qua lỗi ghi file — không ảnh hưởng hoạt động chính.
    }
  }
}