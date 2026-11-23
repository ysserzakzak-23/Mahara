import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/config/api_config.dart';

void main() {
  test('apiPrefix matches the FastAPI routers', () {
    expect(ApiConfig.apiPrefix, '/api/v1');
  });

  test('Android emulator reaches the host through 10.0.2.2', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(ApiConfig.baseUrl, 'http://10.0.2.2:8000');
    expect(ApiConfig.apiBaseUrl, 'http://10.0.2.2:8000/api/v1');
  });

  test('other platforms use localhost', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(ApiConfig.baseUrl, 'http://localhost:8000');
    expect(ApiConfig.apiBaseUrl, 'http://localhost:8000/api/v1');
  });

  group('resolveUrl', () {
    test('keeps absolute URLs unchanged', () {
      expect(ApiConfig.resolveUrl('http://x.com/a.png'), 'http://x.com/a.png');
      expect(ApiConfig.resolveUrl('https://x.com/a.png'), 'https://x.com/a.png');
    });

    test('prefixes relative upload paths with the base URL', () {
      expect(
        ApiConfig.resolveUrl('/uploads/abc.jpg'),
        '${ApiConfig.baseUrl}/uploads/abc.jpg',
      );
    });
  });
}
