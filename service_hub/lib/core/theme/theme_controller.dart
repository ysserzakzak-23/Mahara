import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeController {
  ThemeController._();

  static const _key = 'theme_mode';

  static final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.light);

  static bool get isDark => mode.value == ThemeMode.dark;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      mode.value =
          prefs.getString(_key) == 'dark' ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {}
  }

  static Future<void> setDark(bool dark) async {
    mode.value = dark ? ThemeMode.dark : ThemeMode.light;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, dark ? 'dark' : 'light');
    } catch (_) {}
  }

  static Future<void> toggle() => setDark(!isDark);
}