// Automatic access-token refresh (audit B4).
//
// The access token lasts 30 minutes and the refresh token 7 days, so a
// request made after a break is answered 401. The client then refreshes the
// pair through POST /auth/refresh and sends the request again — once — so
// the user is not signed out while their refresh token is still good.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

const _refreshPath = '/auth/refresh';

/// A backend that answers 401 until the token pair is refreshed.
///
/// Every request is recorded (method, path, Authorization, body), so a test
/// can see exactly what was retried and with which token.
class FakeAuthBackend {
  FakeAuthBackend({
    this.validAccessToken = 'new-access',
    this.refreshStatus = 200,
    this.refreshBody,
    this.onRefresh,
    this.replyTo,
  }) {
    client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path.replaceFirst('/api/v1', '');

      if (path == _refreshPath) {
        refreshCalls++;
        sentRefreshTokens.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['refresh_token'] as String?,
        );
        if (onRefresh != null) await onRefresh!();
        final body = refreshBody ??
            {
              'access_token': validAccessToken,
              'refresh_token': 'new-refresh',
              'token_type': 'bearer',
            };
        return http.Response(jsonEncode(body), refreshStatus, headers: jsonHeaders);
      }

      final custom = replyTo?.call(request);
      if (custom != null) return custom;

      final sent = request.headers['Authorization'];
      if (sent != 'Bearer $validAccessToken') {
        return http.Response(
          jsonEncode({'detail': 'رمز الدخول غير صالح أو منتهي الصلاحية'}),
          401,
          headers: jsonHeaders,
        );
      }
      return http.Response(jsonEncode({'ok': path}), 200, headers: jsonHeaders);
    });
  }

  /// The access token the backend accepts (what a refresh hands out).
  final String validAccessToken;
  final int refreshStatus;
  final Map<String, dynamic>? refreshBody;

  /// Runs inside the refresh handler: lets a test hold the refresh open.
  final Future<void> Function()? onRefresh;

  /// Answers a non-refresh request itself when it returns non-null.
  final http.Response? Function(http.Request request)? replyTo;

  late final http.Client client;
  final List<http.Request> requests = [];
  final List<String?> sentRefreshTokens = [];
  int refreshCalls = 0;

  Iterable<http.Request> to(String path) =>
      requests.where((r) => r.url.path.endsWith(path));
  List<String?> authHeadersFor(String path) =>
      [for (final r in to(path)) r.headers['Authorization']];
}

ApiClient clientFor(http.Client http_) =>
    ApiClient(httpClient: http_, tokenStore: TokenStore());

Future<Map<String, String?>> storedTokens() async {
  final store = TokenStore();
  return {
    'access': await store.accessToken,
    'refresh': await store.refreshToken,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({
        'access_token': 'expired-access',
        'refresh_token': 'good-refresh',
      }));

  group('A. a successful refresh keeps the session', () {
    test('401 -> refresh -> the request is retried and its real answer returned',
        () async {
      final backend = FakeAuthBackend();

      final result = await clientFor(backend.client).get('/users/me');

      expect(result, {'ok': '/users/me'});                 // the retry's answer
      expect(backend.refreshCalls, 1);
      expect(backend.sentRefreshTokens, ['good-refresh']); // the stored refresh token
      // The first attempt carried the expired token, the retry the new one.
      expect(backend.authHeadersFor('/users/me'),
          ['Bearer expired-access', 'Bearer new-access']);
    });

    test('the rotated pair is stored (the backend rotates both)', () async {
      await clientFor(FakeAuthBackend().client).get('/users/me');

      expect(await storedTokens(), {'access': 'new-access', 'refresh': 'new-refresh'});
    });

    test('the refresh call itself carries no Authorization header and is not refreshed',
        () async {
      final backend = FakeAuthBackend();

      await clientFor(backend.client).get('/users/me');

      final refresh = backend.to(_refreshPath).single;
      expect(refresh.headers.containsKey('Authorization'), isFalse);
      expect(refresh.headers['Content-Type'], contains('application/json'));
      expect(backend.refreshCalls, 1);
    });

    test('a request that needs no refresh sends none', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': 'new-access',          // already the valid one
        'refresh_token': 'good-refresh',
      });
      final backend = FakeAuthBackend();

      expect(await clientFor(backend.client).get('/users/me'), {'ok': '/users/me'});
      expect(backend.refreshCalls, 0);
    });

    test('an unauthenticated request (auth: false) is never refreshed', () async {
      final backend = FakeAuthBackend(
        replyTo: (r) => http.Response(
          jsonEncode({'detail': 'رمز الدخول مفقود'}), 401, headers: jsonHeaders),
      );

      await expectLater(
        clientFor(backend.client).post('/auth/login', auth: false, body: {'email': 'a'}),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
      expect(backend.refreshCalls, 0);
    });

    test('with no stored token at all there is nothing to refresh', () async {
      SharedPreferences.setMockInitialValues({});
      final backend = FakeAuthBackend(
        replyTo: (r) => http.Response(
          jsonEncode({'detail': 'رمز الدخول مفقود'}), 401, headers: jsonHeaders),
      );

      await expectLater(clientFor(backend.client).get('/users/me'), throwsA(isA<ApiException>()));
      expect(backend.refreshCalls, 0);
    });
  });

  group('B. a refused refresh ends the session', () {
    test('the stored tokens are cleared and the caller still gets the 401', () async {
      final backend = FakeAuthBackend(
        refreshStatus: 401,
        refreshBody: {'detail': 'رمز التحديث غير صالح أو منتهي الصلاحية'},
      );

      await expectLater(
        clientFor(backend.client).get('/users/me'),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
      expect(await storedTokens(), {'access': null, 'refresh': null});
      expect(backend.refreshCalls, 1);
      expect(backend.to('/users/me').length, 1);     // not retried
    });

    test('onSessionExpired fires exactly once', () async {
      final backend = FakeAuthBackend(refreshStatus: 401, refreshBody: {'detail': 'x'});
      var expired = 0;
      final api = clientFor(backend.client)..onSessionExpired = () => expired++;

      await expectLater(api.get('/users/me'), throwsA(isA<ApiException>()));

      expect(expired, 1);
    });

    test('a request is retried at most once: a second 401 is not refreshed again',
        () async {
      // The refresh "succeeds" but hands out a token the backend still refuses.
      final backend = FakeAuthBackend(validAccessToken: 'never-accepted', refreshBody: {
        'access_token': 'still-stale',
        'refresh_token': 'new-refresh',
        'token_type': 'bearer',
      });

      await expectLater(
        clientFor(backend.client).get('/users/me'),
        throwsA(isA<ApiException>().having((e) => e.isUnauthorized, 'isUnauthorized', isTrue)),
      );
      expect(backend.to('/users/me').length, 2);     // original + one retry, no more
      expect(backend.refreshCalls, 1);
    });

    test('no refresh token stored: no refresh, no session-expired callback', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'expired-access'});
      final backend = FakeAuthBackend();
      var expired = 0;
      final api = clientFor(backend.client)..onSessionExpired = () => expired++;

      await expectLater(api.get('/users/me'), throwsA(isA<ApiException>()));

      expect(backend.refreshCalls, 0);
      expect(expired, 0);
    });

    group('the session survives anything that is not a refusal', () {
      test('a 500 from the refresh endpoint keeps the tokens', () async {
        final backend = FakeAuthBackend(refreshStatus: 500, refreshBody: {'detail': 'boom'});
        var expired = 0;
        final api = clientFor(backend.client)..onSessionExpired = () => expired++;

        await expectLater(api.get('/users/me'), throwsA(isA<ApiException>()));

        expect(await storedTokens(),
            {'access': 'expired-access', 'refresh': 'good-refresh'});
        expect(expired, 0);
      });

      test('an unreachable server during refresh keeps the tokens', () async {
        var calls = 0;
        final client = MockClient((request) async {
          calls++;
          if (request.url.path.endsWith(_refreshPath)) {
            throw http.ClientException('connection failed');
          }
          return http.Response(jsonEncode({'detail': 'expired'}), 401, headers: jsonHeaders);
        });
        var expired = 0;
        final api = clientFor(client)..onSessionExpired = () => expired++;

        await expectLater(api.get('/users/me'), throwsA(isA<ApiException>()));

        expect(await storedTokens(),
            {'access': 'expired-access', 'refresh': 'good-refresh'});
        expect(expired, 0);
        expect(calls, greaterThan(1));
      });

      for (final broken in [
        {'access_token': '', 'refresh_token': 'r'},
        {'refresh_token': 'r'},
        {'access_token': 'a'},
        {'access_token': 'a', 'refresh_token': ''},
        {'access_token': 42, 'refresh_token': 'r'},
      ]) {
        test('a malformed refresh body ($broken) never overwrites the stored tokens',
            () async {
          final backend = FakeAuthBackend(refreshBody: broken);

          await expectLater(clientFor(backend.client).get('/users/me'),
              throwsA(isA<ApiException>()));

          expect(await storedTokens(),
              {'access': 'expired-access', 'refresh': 'good-refresh'});
        });
      }
    });

    test('no token value appears in the error shown to the user', () async {
      final backend = FakeAuthBackend(
        refreshStatus: 401,
        refreshBody: {'detail': 'رمز التحديث غير صالح أو منتهي الصلاحية'},
      );

      try {
        await clientFor(backend.client).get('/users/me');
        fail('expected an ApiException');
      } on ApiException catch (e) {
        expect(e.message, isNot(contains('expired-access')));
        expect(e.message, isNot(contains('good-refresh')));
        expect(e.toString(), isNot(contains('refresh')));
      }
    });
  });

  group('C. concurrent 401s share one refresh', () {
    test('six parallel requests cause one refresh; all are retried and succeed',
        () async {
      final gate = Completer<void>();
      final backend = FakeAuthBackend(onRefresh: () => gate.future);
      final api = clientFor(backend.client);

      final paths = ['/users/me', '/services', '/notifications', '/appointments/me',
        '/exchange-requests/me', '/categories'];
      final inFlight = [for (final p in paths) api.get(p)];
      await pumpEventQueue();
      gate.complete();
      final results = await Future.wait(inFlight);

      expect(backend.refreshCalls, 1);                       // single flight
      expect(results, [for (final p in paths) {'ok': p}]);
      for (final p in paths) {
        expect(backend.authHeadersFor(p), ['Bearer expired-access', 'Bearer new-access'],
            reason: p);
      }
    });

    test('a 401 arriving after the refresh finished retries without a second refresh',
        () async {
      final backend = FakeAuthBackend();
      final api = clientFor(backend.client);

      await api.get('/users/me');            // refreshes once
      expect(backend.refreshCalls, 1);

      // A request sent with the old token (e.g. in flight during the refresh)
      // is answered 401; the stored token is already new, so it just retries.
      final late401 = MockClient((request) async {
        backend.requests.add(request);
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return http.Response(jsonEncode({'ok': 'late'}), 200, headers: jsonHeaders);
        }
        return http.Response(jsonEncode({'detail': 'expired'}), 401, headers: jsonHeaders);
      });
      expect(await clientFor(late401).get('/services'), {'ok': 'late'});
      expect(backend.refreshCalls, 1);                       // still just the one
    });

    test('when the shared refresh is refused, every waiter fails and the session ends once',
        () async {
      final gate = Completer<void>();
      final backend = FakeAuthBackend(
        refreshStatus: 401,
        refreshBody: {'detail': 'رمز التحديث غير صالح'},
        onRefresh: () => gate.future,
      );
      var expired = 0;
      final api = clientFor(backend.client)..onSessionExpired = () => expired++;

      final inFlight = [
        for (final p in ['/users/me', '/services', '/notifications'])
          api.get(p).then<Object?>((v) => v, onError: (e) => e),
      ];
      await pumpEventQueue();
      gate.complete();
      final results = await Future.wait(inFlight);

      expect(backend.refreshCalls, 1);
      expect(results.whereType<ApiException>().length, 3);
      for (final e in results.cast<ApiException>()) {
        expect(e.isUnauthorized, isTrue);
      }
      expect(expired, 1);                                   // not once per request
      expect(await storedTokens(), {'access': null, 'refresh': null});
    });

    test('a later request can refresh again after an earlier refresh failed', () async {
      // The refresh state must be reset whether it succeeded or failed.
      var refreshes = 0;
      var refuse = true;
      final client = MockClient((request) async {
        if (request.url.path.endsWith(_refreshPath)) {
          refreshes++;
          if (refuse) {
            return http.Response(jsonEncode({'detail': 'no'}), 500, headers: jsonHeaders);
          }
          return http.Response(
            jsonEncode({'access_token': 'new-access', 'refresh_token': 'new-refresh'}),
            200, headers: jsonHeaders);
        }
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return http.Response(jsonEncode({'ok': true}), 200, headers: jsonHeaders);
        }
        return http.Response(jsonEncode({'detail': 'expired'}), 401, headers: jsonHeaders);
      });
      final api = clientFor(client);

      await expectLater(api.get('/users/me'), throwsA(isA<ApiException>()));
      expect(refreshes, 1);

      refuse = false;
      expect(await api.get('/users/me'), {'ok': true});
      expect(refreshes, 2);                                  // not stuck
    });
  });

  group('D. the retried request is the same request', () {
    test('GET keeps its path and query', () async {
      final backend = FakeAuthBackend();

      await clientFor(backend.client).get('/search/smart?q=%D8%B3%D8%A8%D8%A7%D9%83&limit=5');

      final sent = backend.to('/search/smart').toList();
      expect(sent.length, 2);
      for (final request in sent) {
        expect(request.method, 'GET');
        expect(request.url.queryParameters, {'q': 'سباك', 'limit': '5'});
      }
    });

    for (final (verb, path, send) in <(String, String, Future<dynamic> Function(ApiClient))>[
      ('POST', '/services', (api) => api.post('/services', body: {'title': 'سباك', 'price': 25.5})),
      ('PATCH', '/services/1', (api) => api.patch('/services/1', body: {'price': null})),
      ('PUT', '/users/me/location', (api) => api.put('/users/me/location', body: {'latitude': 33.5})),
    ]) {
      test('$verb keeps its method, headers and body', () async {
        final backend = FakeAuthBackend();

        await send(clientFor(backend.client));

        // By path: the refresh call is itself a POST.
        final sent = backend.to(path).toList();
        expect(sent.every((r) => r.method == verb), isTrue);
        expect(sent.length, 2);                    // original + retry
        expect(sent[0].body, sent[1].body);        // byte-for-byte the same body
        expect(sent[0].body, isNotEmpty);
        expect(sent[1].headers['Content-Type'], contains('application/json'));
        expect(sent[1].headers['Authorization'], 'Bearer new-access');
        expect(sent[0].url, sent[1].url);
      });
    }

    test('DELETE is retried', () async {
      final backend = FakeAuthBackend();

      await clientFor(backend.client).delete('/services/7');

      expect(backend.to('/services/7').length, 2);
      expect(backend.authHeadersFor('/services/7').last, 'Bearer new-access');
    });

    test('a multipart upload is rebuilt and retried with the same file', () async {
      final sentBodies = <String>[];
      var refreshed = false;
      final client = MockClient((request) async {
        if (request.url.path.endsWith(_refreshPath)) {
          refreshed = true;
          return http.Response(
            jsonEncode({'access_token': 'new-access', 'refresh_token': 'new-refresh'}),
            200, headers: jsonHeaders);
        }
        sentBodies.add(String.fromCharCodes(request.bodyBytes));
        if (request.headers['Authorization'] == 'Bearer new-access') {
          return http.Response(
            jsonEncode({'url': '/uploads/new.png'}), 200, headers: jsonHeaders);
        }
        return http.Response(jsonEncode({'detail': 'expired'}), 401, headers: jsonHeaders);
      });

      final result = await clientFor(client).uploadFile(
        '/uploads/image',
        fieldName: 'file',
        bytes: [1, 2, 3, 4],
        filename: 'photo.png',
      );

      expect(result, {'url': '/uploads/new.png'});
      expect(refreshed, isTrue);
      expect(sentBodies.length, 2);                      // sent again, not reused
      for (final body in sentBodies) {
        expect(body, contains('name="file"'));
        expect(body, contains('filename="photo.png"'));
        expect(body.codeUnits, containsAllInOrder([1, 2, 3, 4]));
      }
    });
  });

  group('F. HTTP client ownership', () {
    test('ApiClient.shared is one instance for the whole app', () {
      expect(identical(ApiClient.shared, ApiClient.shared), isTrue);
    });

    test('the shared client refuses to be closed', () {
      expect(ApiClient.shared.close, throwsStateError);
    });

    test('an injected HTTP client is never closed by ApiClient (it belongs to the caller)',
        () async {
      final injected = _ClosableClient();
      clientFor(injected).close();
      expect(injected.closed, isFalse);
      // ...and it still works afterwards.
      expect(await clientFor(injected).get('/x', auth: false), {'ok': true});
    });
  });
}

class _ClosableClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'ok': true}))),
        200,
        headers: {'content-type': 'application/json'},
      );

  @override
  void close() => closed = true;
}
