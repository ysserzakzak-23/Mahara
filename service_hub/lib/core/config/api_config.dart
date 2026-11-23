import 'package:flutter/foundation.dart';

/// Central place for the backend connection settings.
///
/// The base URL can be overridden at build/run time without touching code:
///   flutter run --dart-define=API_BASE_URL=http://192.168.1.10:8000
///
/// When no override is given we pick a sensible default per platform:
///   - Android emulator reaches the host machine via the special 10.0.2.2 IP.
///   - Everything else (iOS sim, desktop, web) can use localhost.
class ApiConfig {
  ApiConfig._();

  /// API version prefix shared by every backend route (see FastAPI routers).
  static const String apiPrefix = '/api/v1';

  static const String _override = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );

  /// Root server URL, e.g. http://localhost:8000 (no trailing slash, no prefix).
  static String get baseUrl {
    if (_override.isNotEmpty) return _override;

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://localhost:8000';
  }

  /// Full API base, e.g. http://localhost:8000/api/v1
  static String get apiBaseUrl => '$baseUrl$apiPrefix';

  /// Turns a relative path returned by the backend (e.g. an uploaded
  /// image's "/uploads/xyz.jpg") into a fully-qualified URL the Flutter
  /// app can pass straight to `Image.network`. Already-absolute URLs
  /// (http/https) are returned unchanged.
  static String resolveUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    return '$baseUrl$path';
  }
}
