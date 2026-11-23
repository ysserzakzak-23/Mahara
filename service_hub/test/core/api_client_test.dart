import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/config/api_config.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

ApiClient clientFor(http.Client client) =>
    ApiClient(httpClient: client, tokenStore: TokenStore());

http.Client respond(int status, String body) => MockClient(
      (_) async => http.Response(body, status, headers: jsonHeaders),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('requests', () {
    test('prefixes the path with the API base URL', () async {
      final backend = FakeBackend({'ok': true});
      await clientFor(backend.client).get('/users/me');

      expect(backend.last.url.toString(), '${ApiConfig.apiBaseUrl}/users/me');
      expect(backend.last.method, 'GET');
    });

    test('attaches the bearer token when one is stored', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'abc'});
      final backend = FakeBackend({});
      await clientFor(backend.client).get('/users/me');

      expect(backend.last.headers['Authorization'], 'Bearer abc');
    });

    test('does not send Authorization when auth is false', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'abc'});
      final backend = FakeBackend({});
      await clientFor(backend.client).post('/auth/login', auth: false, body: {});

      expect(backend.last.headers.containsKey('Authorization'), isFalse);
    });

    test('does not send Authorization when there is no token', () async {
      final backend = FakeBackend({});
      await clientFor(backend.client).get('/categories');

      expect(backend.last.headers.containsKey('Authorization'), isFalse);
    });

    test('encodes the body as JSON with a JSON content type', () async {
      final backend = FakeBackend({});
      await clientFor(backend.client).post('/x', body: {'a': 1, 'b': 'two'});

      expect(backend.last.headers['Content-Type'], startsWith('application/json'));
      expect(backend.lastJsonBody, {'a': 1, 'b': 'two'});
    });

    test('verbs map to the right HTTP methods', () async {
      final backend = FakeBackend({});
      final api = clientFor(backend.client);
      await api.get('/x');
      await api.post('/x');
      await api.patch('/x');
      await api.put('/x');
      await api.delete('/x');

      expect(backend.requests.map((r) => r.method),
          ['GET', 'POST', 'PATCH', 'PUT', 'DELETE']);
    });
  });

  group('responses', () {
    test('decodes JSON objects and lists', () async {
      expect(await clientFor(respond(200, '{"a":1}')).get('/x'), {'a': 1});
      expect(await clientFor(respond(200, '[1,2]')).get('/x'), [1, 2]);
    });

    test('an empty 2xx body returns null', () async {
      expect(await clientFor(respond(204, '')).delete('/x'), isNull);
    });

    test('unicode (Arabic) responses are decoded correctly', () async {
      final result = await clientFor(respond(200, jsonEncode({'name': 'دمشق'})))
          .get('/x');
      expect(result['name'], 'دمشق');
    });
  });

  group('errors', () {
    Future<ApiException> failure(int status, String body) async {
      try {
        await clientFor(respond(status, body)).get('/x');
      } on ApiException catch (e) {
        return e;
      }
      fail('expected an ApiException');
    }

    test('uses the string detail from domain errors', () async {
      final e = await failure(409, '{"detail":"Email taken","error_type":"ConflictError"}');
      expect(e.message, 'Email taken');
      expect(e.statusCode, 409);
    });

    test('uses the first msg of Pydantic validation errors', () async {
      final e = await failure(422, '{"detail":[{"msg":"field required","loc":["body"]}]}');
      expect(e.message, 'field required');
    });

    test('falls back to a generic message for unknown error shapes', () async {
      final e = await failure(500, '{"oops":true}');
      expect(e.message, 'حدث خطأ ما، يرجى المحاولة مرة أخرى.');
    });

    test('handles non-JSON error bodies (e.g. a proxy 502 page)', () async {
      final e = await failure(502, 'Bad Gateway');
      expect(e.statusCode, 502);
      expect(e.message, 'حدث خطأ ما، يرجى المحاولة مرة أخرى.');
    });

    test('401 is flagged as unauthorized', () async {
      final e = await failure(401, '{"detail":"Invalid or expired token"}');
      expect(e.isUnauthorized, isTrue);
    });
  });

  group('network failures', () {
    test('retries once on a connection failure and then succeeds', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) throw http.ClientException('connection reset');
        return http.Response('{"ok":true}', 200, headers: jsonHeaders);
      });

      expect(await clientFor(client).get('/x'), {'ok': true});
      expect(calls, 2);
    });

    test('gives a friendly error when the retry also fails', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        throw http.ClientException('down');
      });

      await expectLater(
        clientFor(client).get('/x'),
        throwsA(isA<ApiException>().having(
          (e) => e.message,
          'message',
          startsWith('تعذّر الوصول إلى السيرفر'),
        )),
      );
      expect(calls, 2);
    });

    test('HTTP error responses are NOT retried', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{"detail":"boom"}', 500, headers: jsonHeaders);
      });

      await expectLater(clientFor(client).get('/x'), throwsA(isA<ApiException>()));
      expect(calls, 1);
    });
  });

  group('uploadFile', () {
    test('sends multipart form data with the file and auth header', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'abc'});
      final backend = FakeBackend({'url': '/uploads/new.png'});

      final result = await clientFor(backend.client).uploadFile(
        '/uploads/image',
        fieldName: 'file',
        bytes: [1, 2, 3],
        filename: 'photo.png',
      );

      expect(result, {'url': '/uploads/new.png'});
      expect(backend.last.method, 'POST');
      expect(backend.last.url.path, endsWith('/uploads/image'));
      expect(backend.last.headers['content-type'], startsWith('multipart/form-data'));
      expect(backend.last.headers['Authorization'], 'Bearer abc');

      final raw = String.fromCharCodes(backend.last.bodyBytes);
      expect(raw, contains('name="file"'));
      expect(raw, contains('filename="photo.png"'));
    });

    test('surfaces server errors as ApiException', () async {
      await expectLater(
        clientFor(respond(400, '{"detail":"not an allowed image type"}')).uploadFile(
          '/uploads/image',
          fieldName: 'file',
          bytes: [1],
          filename: 'x.txt',
        ),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', 'not an allowed image type')),
      );
    });
  });
}
