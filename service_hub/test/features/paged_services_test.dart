// The two Group 1 services read through the shared pagination parser.
//
// Each endpoint can answer in either shape, and both have to work against
// the REAL service methods, not just the parser in isolation:
//
//   * a bare JSON array — the request asked for no page, or the backend
//     predates pagination and ignored the parameters;
//   * the envelope {items, page, page_size, has_next}.
//
// Also pinned down here: the parameters are absent unless asked for (that
// absence is what keeps the legacy response), and a malformed body is an
// error rather than an empty list.

import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/admin/data/admin_service.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

ApiClient apiFor(FakeBackend backend) =>
    ApiClient(httpClient: backend.client, tokenStore: TokenStore());

Map<String, dynamic> _notification(int id) => {
      'id': id,
      'type': 'system',
      'title': 'Title $id',
      'message': 'Message $id',
      'is_read': false,
      'created_at': '2026-10-05T10:00:00Z',
    };

Map<String, dynamic> _user(int id) => {
      'id': id,
      'email': 'user$id@example.com',
      'role': 'user',
      'is_provider': false,
      'is_active': true,
      'profile': null,
    };

Map<String, dynamic> _listing(int id) => {
      'id': id,
      'title': 'Listing $id',
      'price': '25.50',
      'status': 'active',
      'provider_id': 3,
      'category_id': 1,
    };

Map<String, dynamic> _envelope(
  List<Map<String, dynamic>> items, {
  int page = 1,
  int pageSize = 20,
  bool hasNext = false,
}) =>
    {
      'items': items,
      'page': page,
      'page_size': pageSize,
      'has_next': hasNext,
    };

final _throwsMalformed = throwsA(
  isA<ApiException>().having(
    (e) => e.message,
    'message',
    'حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.',
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('NotificationService.list', () {
    test('a legacy bare array is one complete page', () async {
      final backend = FakeBackend([_notification(1), _notification(2)]);

      final result = await NotificationService(apiClient: apiFor(backend)).list();

      expect(result.length, 2);
      expect(result.items.first.title, 'Title 1');
      expect(result.hasNext, isFalse); // nothing more to ask for
      expect(result.page, 1);
      expect(result.total, isNull);
    });

    test('the envelope is read field by field', () async {
      final backend = FakeBackend(
        _envelope([_notification(3)], page: 2, pageSize: 20, hasNext: true),
      );

      final result = await NotificationService(apiClient: apiFor(backend))
          .list(page: 2, pageSize: 20);

      expect(result.length, 1);
      expect(result.items.single.id, 3);
      expect(result.page, 2);
      expect(result.pageSize, 20);
      expect(result.hasNext, isTrue);
      expect(result.total, isNull); // the backend sends none
    });

    test('no pagination parameters are sent unless asked for', () async {
      final backend = FakeBackend(<dynamic>[]);

      await NotificationService(apiClient: apiFor(backend)).list();

      final query = backend.last.url.queryParameters;
      expect(query['unread_only'], 'false');
      expect(query.containsKey('page'), isFalse);
      expect(query.containsKey('page_size'), isFalse);
    });

    test('page, page_size and unread_only travel together', () async {
      final backend = FakeBackend(<dynamic>[]);

      await NotificationService(apiClient: apiFor(backend))
          .list(unreadOnly: true, page: 3, pageSize: 15);

      expect(backend.last.url.queryParameters, {
        'unread_only': 'true',
        'page': '3',
        'page_size': '15',
      });
    });

    test('an older backend ignoring the parameters still works', () async {
      // FastAPI drops unknown query parameters, so a pre-pagination server
      // answers ?page=1&page_size=20 with the whole list.
      final backend = FakeBackend([for (var i = 1; i <= 50; i++) _notification(i)]);

      final result = await NotificationService(apiClient: apiFor(backend))
          .list(page: 1, pageSize: 20);

      expect(result.length, 50);
      expect(result.hasNext, isFalse);
    });

    test('a malformed body is an error, never an empty list', () async {
      final backend = FakeBackend({'detail': 'something unexpected'});

      await expectLater(
        NotificationService(apiClient: apiFor(backend)).list(page: 1),
        _throwsMalformed,
      );
    });
  });

  group('AdminService.users', () {
    test('a legacy bare array is one complete page', () async {
      final backend = FakeBackend([_user(5), _user(6)]);

      final result = await AdminService(apiClient: apiFor(backend)).users();

      expect(result.length, 2);
      expect(result.items.first.email, 'user5@example.com');
      expect(result.hasNext, isFalse);
    });

    test('the envelope is read, and carries no total', () async {
      final backend = FakeBackend(_envelope([_user(5)], page: 1, hasNext: true));

      final result =
          await AdminService(apiClient: apiFor(backend)).users(page: 1, pageSize: 20);

      expect(result.length, 1);
      expect(result.hasNext, isTrue);
      expect(result.total, isNull); // the dashboard shows no count
    });

    test('an unpaginated call sends a bare path', () async {
      final backend = FakeBackend(<dynamic>[]);

      await AdminService(apiClient: apiFor(backend)).users();

      expect(backend.last.url.query, isEmpty);
    });

    test('a paginated call sends page and page_size', () async {
      final backend = FakeBackend(<dynamic>[]);

      await AdminService(apiClient: apiFor(backend)).users(page: 2, pageSize: 20);

      expect(backend.last.url.queryParameters, {'page': '2', 'page_size': '20'});
    });

    test('a malformed body is an error, never an empty list', () async {
      final backend = FakeBackend('not a list');

      await expectLater(
        AdminService(apiClient: apiFor(backend)).users(page: 1),
        _throwsMalformed,
      );
    });
  });

  group('AdminService.services', () {
    test('a legacy bare array is one complete page', () async {
      final backend = FakeBackend([_listing(1)]);

      final result = await AdminService(apiClient: apiFor(backend)).services();

      expect(result.length, 1);
      expect(result.items.single.title, 'Listing 1');
      expect(result.hasNext, isFalse);
    });

    test('the status filter and the page parameters travel together', () async {
      final backend = FakeBackend(_envelope([_listing(1)], hasNext: true));

      final result = await AdminService(apiClient: apiFor(backend))
          .services(status: 'suspended', page: 2, pageSize: 10);

      expect(backend.last.url.queryParameters, {
        'status': 'suspended',
        'page': '2',
        'page_size': '10',
      });
      expect(result.hasNext, isTrue);
    });

    test('the status filter alone keeps the legacy request', () async {
      final backend = FakeBackend(<dynamic>[]);

      await AdminService(apiClient: apiFor(backend)).services(status: 'suspended');

      expect(backend.last.url.queryParameters, {'status': 'suspended'});
    });

    test('a malformed body is an error, never an empty list', () async {
      final backend = FakeBackend(_envelope([_listing(1)])..remove('has_next'));

      await expectLater(
        AdminService(apiClient: apiFor(backend)).services(page: 1),
        _throwsMalformed,
      );
    });
  });
}
