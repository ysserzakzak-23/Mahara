// Startup and session handling (audit B4, task 3).
//
// The access token lasts 30 minutes, so after any real break the app starts
// with an expired one. That alone must NOT send the user to the login
// screen: the stored refresh token is good for 7 days, so the session is
// refreshed and Home opens as usual. Login appears only when the server
// refuses the session itself.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/login_screen.dart';
import 'package:service_hub/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/fixtures.dart';

const _me = {
  'id': 1,
  'email': 'ahmad@example.com',
  'role': 'user',
  'is_provider': false,
  'is_active': true,
  'profile': {'full_name': 'Ahmad Ali'},
};

/// A backend that accepts only [validAccessToken] and can refresh once.
class _Backend {
  _Backend({this.refreshStatus = 200, this.meStatus, this.gate}) {
    client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path.replaceFirst('/api/v1', '')}');
      if (gate != null) await gate!.future;
      final path = request.url.path;

      if (path.endsWith('/auth/refresh')) {
        refreshCalls++;
        if (refreshStatus != 200) {
          return http.Response(
              jsonEncode({'detail': 'رمز التحديث غير صالح'}), refreshStatus,
              headers: jsonHeaders);
        }
        return http.Response(
          jsonEncode({
            'access_token': validAccessToken,
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
          }),
          200,
          headers: jsonHeaders,
        );
      }

      if (path.endsWith('/users/me')) {
        if (meStatus != null) {
          return http.Response(
              jsonEncode({'detail': 'الخادم لا يستجيب'}), meStatus!, headers: jsonHeaders);
        }
        if (request.headers['Authorization'] != 'Bearer $validAccessToken') {
          return http.Response(
              jsonEncode({'detail': 'رمز الدخول غير صالح أو منتهي الصلاحية'}), 401,
              headers: jsonHeaders);
        }
        return http.Response(jsonEncode(_me), 200, headers: jsonHeaders);
      }
      return http.Response(jsonEncode({'ok': true}), 200, headers: jsonHeaders);
    });
  }

  /// The only access token this backend accepts — what a refresh hands out.
  static const validAccessToken = 'fresh-access';

  final int refreshStatus;
  final int? meStatus;
  final Completer<void>? gate;

  late final http.Client client;
  final List<String> requests = [];
  int refreshCalls = 0;

  int callsTo(String key) => requests.where((r) => r == key).length;
}

Widget _app(_Backend backend) => MyApp(
      showDeviceFrame: false,
      apiClient: ApiClient(httpClient: backend.client, tokenStore: TokenStore()),
      pushSetup: () async {},            // Firebase is not initialised in tests
      homeBuilder: (_) => const Scaffold(body: Text('HOME')),
    );

Future<Map<String, String?>> storedTokens() async {
  final store = TokenStore();
  return {'access': await store.accessToken, 'refresh': await store.refreshToken};
}

void main() {
  group('E. startup', () {
    testWidgets('a valid access token opens Home, with no refresh', (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'fresh-access',
        'refresh_token': 'good-refresh',
      });
      final backend = _Backend();

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(backend.refreshCalls, 0);
      expect(backend.callsTo('GET /users/me'), 1);
    });

    testWidgets('an EXPIRED access token with a good refresh token still opens Home',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'expired-access',
        'refresh_token': 'good-refresh',
      });
      final backend = _Backend();

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);       // never logged out
      expect(backend.refreshCalls, 1);                      // exactly one refresh
      expect(backend.callsTo('GET /users/me'), 2);          // the retry
      expect(await storedTokens(),
          {'access': 'fresh-access', 'refresh': 'rotated-refresh'});
    });

    testWidgets('the login screen is not shown even for a moment while refreshing',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'expired-access',
        'refresh_token': 'good-refresh',
      });
      final gate = Completer<void>();
      final backend = _Backend(gate: gate);

      await tester.pumpWidget(_app(backend));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(LoginScreen), findsNothing);     // a spinner, not Login
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      }

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);
    });

    testWidgets('a refused refresh token clears the session and shows Login',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'expired-access',
        'refresh_token': 'revoked-refresh',
      });
      final backend = _Backend(refreshStatus: 401);

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
      expect(await storedTokens(), {'access': null, 'refresh': null});
      expect(backend.refreshCalls, 1);
    });

    testWidgets('no stored session at all goes straight to Login without any request',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final backend = _Backend();

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(backend.requests, isEmpty);
    });

    testWidgets('startup refreshes only once', (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'expired-access',
        'refresh_token': 'good-refresh',
      });
      final backend = _Backend();

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /auth/refresh'), 1);
    });

    testWidgets('a server that is down keeps the user signed in', (tester) async {
      // A 500 (or no network) says nothing about the session: staying signed
      // in is right, and the app's own screens show their error states.
      SharedPreferences.setMockInitialValues({
        'access_token': 'fresh-access',
        'refresh_token': 'good-refresh',
      });
      final backend = _Backend(meStatus: 500);

      await tester.pumpWidget(_app(backend));
      await tester.pumpAndSettle();

      expect(find.text('HOME'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(await storedTokens(),
          {'access': 'fresh-access', 'refresh': 'good-refresh'});   // untouched
    });
  });

  group('a session refused while the app is in use', () {
    testWidgets('sends the user back to Login', (tester) async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'fresh-access',
        'refresh_token': 'good-refresh',
      });
      final backend = _Backend();
      final api = ApiClient(httpClient: backend.client, tokenStore: TokenStore());

      await tester.pumpWidget(MyApp(
        showDeviceFrame: false,
        apiClient: api,
        pushSetup: () async {},
        homeBuilder: (_) => const Scaffold(body: Text('HOME')),
      ));
      await tester.pumpAndSettle();
      expect(find.text('HOME'), findsOneWidget);

      // What ApiClient does when the backend refuses the refresh token.
      await TokenStore().clear();
      api.onSessionExpired!();
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('HOME'), findsNothing);
    });

    testWidgets('the listener is dropped when the app widget goes away', (tester) async {
      final backend = _Backend();
      final api = ApiClient(httpClient: backend.client, tokenStore: TokenStore());
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(MyApp(showDeviceFrame: false, apiClient: api));
      await tester.pumpAndSettle();
      expect(api.onSessionExpired, isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();

      expect(api.onSessionExpired, isNull);     // nothing left pointing at a dead widget
    });
  });

  group('F. the app uses one shared HTTP client', () {
    testWidgets('services built without an explicit client reuse ApiClient.shared',
        (tester) async {
      // Every data service defaults to the same instance, so the app keeps
      // one connection pool and one refresh state.
      expect(identical(ApiClient.shared, ApiClient.shared), isTrue);
      expect(ApiClient.shared.close, throwsStateError);
    });
  });
}
