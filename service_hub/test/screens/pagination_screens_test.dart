// Incremental paging on the two Group 1 screens.
//
// What is pinned down here is the behaviour a user would notice: the first
// page arrives, reaching the bottom fetches the next one, it stops when
// `has_next` says so, a row that shifts between requests is not shown
// twice, a failed page keeps what is already on screen and offers a retry
// (without retrying forever by itself), pull-to-refresh starts over, a
// reply from a superseded request never overwrites newer rows, and reading
// a page never marks a notification read.
//
// A legacy backend — one that ignores `page` and returns the whole array —
// is covered too: the screen shows everything and asks for nothing more.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/config/api_config.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/admin/admin_dashboard_screen.dart';
import 'package:service_hub/features/admin/data/admin_service.dart';
import 'package:service_hub/core/api/paged_result.dart';
import 'package:service_hub/features/admin/data/admin_models.dart';
import 'package:service_hub/features/notifications/data/notification_models.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/notifications/notifications_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

/// The shared [apiFor] takes a RoutedBackend; this file has its own fake.
ApiClient _apiFor(_Backend backend) =>
    ApiClient(httpClient: backend.client, tokenStore: TokenStore());

/// A fake backend that answers per METHOD + path + query, and can hold a
/// single route's reply open — which is how the stale-request tests get two
/// requests in flight and finish them in the wrong order on purpose.
class _Backend {
  _Backend(Map<String, Reply> routes) : routes = Map.of(routes) {
    client = MockClient((req) async {
      requests.add(req);
      final withQuery = _key(req, withQuery: true);
      final bare = _key(req);
      final hold = _holds[withQuery] ?? _holds[bare];
      if (hold != null) await hold.future;
      final reply = this.routes[withQuery] ??
          this.routes[bare] ??
          Reply({'detail': 'No fake route for $withQuery'}, status: 404);
      return http.Response(
        reply.body == null ? '' : jsonEncode(reply.body),
        reply.status,
        headers: jsonHeaders,
      );
    });
  }

  final Map<String, Reply> routes;
  final List<http.Request> requests = [];
  final Map<String, Completer<void>> _holds = {};
  late final http.Client client;

  static String _key(http.Request r, {bool withQuery = false}) {
    final path = r.url.path.replaceFirst(ApiConfig.apiPrefix, '');
    return withQuery ? '${r.method} $path?${r.url.query}' : '${r.method} $path';
  }

  /// Makes the next request to [key] wait until [release] is called.
  void hold(String key) => _holds[key] = Completer<void>();

  void release(String key) => _holds.remove(key)?.complete();

  int callsTo(String key) => requests.where((r) => _key(r) == key).length;

  List<String> queriesFor(String key) =>
      requests.where((r) => _key(r) == key).map((r) => r.url.query).toList();
}

// The exact URLs the services build, so a route can answer one page only.
String _notificationsPage(int page) =>
    'GET /notifications?unread_only=false&page=$page&page_size=20';
String _usersPage(int page) => 'GET /admin/users?page=$page&page_size=20';
String _servicesPage(int page) => 'GET /admin/services?page=$page&page_size=20';

Map<String, dynamic> _n(int id, {bool read = false}) => {
      'id': id,
      'type': 'system',
      'title': 'Title $id',
      'message': 'Message $id',
      'is_read': read,
      'created_at': '2026-10-05T10:00:00Z',
    };

Map<String, dynamic> _user(int id) => {
      'id': id,
      'email': 'user$id@example.com',
      'role': 'user',
      'is_provider': false,
      'is_active': true,
      'profile': {'full_name': 'User $id'},
    };

Map<String, dynamic> _listing(int id) => {
      'id': id,
      'title': 'Listing $id',
      'price': '25.50',
      'status': 'active',
      'provider_id': 3,
      'category_id': 1,
    };

Reply _page(
  List<Map<String, dynamic>> items, {
  int page = 1,
  bool hasNext = false,
}) =>
    Reply({
      'items': items,
      'page': page,
      'page_size': 20,
      'has_next': hasNext,
    });

const _stats = {
  'total_users': 120,
  'total_providers': 30,
  'active_services': 55,
  'total_appointments': 400,
  'completed_appointments': 250,
  'total_reviews': 99,
  'average_platform_rating': 4.5,
};

Future<void> _openNotifications(WidgetTester tester, _Backend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: NotificationsScreen(
      service: NotificationService(apiClient: _apiFor(backend)),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openAdmin(WidgetTester tester, _Backend backend, String tab) async {
  useTallScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: AdminDashboardScreen(
      adminService: AdminService(apiClient: _apiFor(backend)),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, tab));
  await tester.pumpAndSettle();
}

/// Pulls the list down far enough to trigger RefreshIndicator.
Future<void> _pullToRefresh(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).last, const Offset(0, 400), 1200);
  await tester.pumpAndSettle();
}

/// Pumps a fixed stretch of frames instead of settling.
///
/// The stub-driven tests below leave a page request unanswered on purpose,
/// so the footer's progress indicator keeps animating and pumpAndSettle
/// would never return.
Future<void> _pumpAWhile(WidgetTester tester) => pumpFrames(tester, frames: 25);

Future<void> _pullToRefreshWhileLoading(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).last, const Offset(0, 400), 1200);
  await _pumpAWhile(tester);
}

/// A NotificationService whose every `list` call is answered by hand, so a
/// test decides exactly which of two in-flight requests lands first.
class _StubNotificationService extends NotificationService {
  _StubNotificationService() : super(apiClient: _unusedApi());

  final List<int> requestedPages = [];
  final List<int> markedRead = [];
  final List<Completer<PagedResult<AppNotification>>> _calls = [];

  @override
  Future<PagedResult<AppNotification>> list({
    bool unreadOnly = false,
    int? page,
    int? pageSize,
  }) {
    requestedPages.add(page ?? 1);
    final completer = Completer<PagedResult<AppNotification>>();
    _calls.add(completer);
    return completer.future;
  }

  @override
  Future<void> markRead(int id) async => markedRead.add(id);

  @override
  Future<void> markAllRead() async {}

  /// Answers the [call]-th `list` call (0-based, in request order).
  void answer(
    int call, {
    required List<int> ids,
    required int page,
    required bool hasNext,
    bool read = false,
  }) {
    _calls[call].complete(PagedResult<AppNotification>(
      items: [for (final id in ids) AppNotification.fromJson(_n(id, read: read))],
      page: page,
      pageSize: 20,
      hasNext: hasNext,
    ));
  }
}

/// The admin equivalent. Stats answer immediately; the service list is the
/// one driven by hand.
class _StubAdminService extends AdminService {
  _StubAdminService() : super(apiClient: _unusedApi());

  final List<int> requestedServicePages = [];
  final List<Completer<PagedResult<AdminServiceListing>>> _serviceCalls = [];

  @override
  Future<PlatformStats> stats() async => PlatformStats.fromJson(_stats);

  @override
  Future<PagedResult<AdminUser>> users({int? page, int? pageSize}) async =>
      PagedResult<AdminUser>.complete([AdminUser.fromJson(_user(1))]);

  @override
  Future<PagedResult<AdminServiceListing>> services({
    String? status,
    int? page,
    int? pageSize,
  }) {
    requestedServicePages.add(page ?? 1);
    final completer = Completer<PagedResult<AdminServiceListing>>();
    _serviceCalls.add(completer);
    return completer.future;
  }

  void answerServices(
    int call, {
    required List<int> ids,
    required int page,
    required bool hasNext,
  }) {
    _serviceCalls[call].complete(PagedResult<AdminServiceListing>(
      items: [for (final id in ids) AdminServiceListing.fromJson(_listing(id))],
      page: page,
      pageSize: 20,
      hasNext: hasNext,
    ));
  }
}

/// These stubs never reach the network; the ApiClient is only there because
/// the real services require one.
ApiClient _unusedApi() => ApiClient(
      httpClient: MockClient(
        (_) async => http.Response('[]', 200, headers: jsonHeaders),
      ),
      tokenStore: TokenStore(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  // =================================================== notifications screen

  group('notifications paging', () {
    testWidgets('the first load asks for page 1 and a page size', (tester) async {
      final backend = _Backend({_notificationsPage(1): _page([_n(1)])});
      await _openNotifications(tester, backend);

      expect(backend.requests.first.url.queryParameters, {
        'unread_only': 'false',
        'page': '1',
        'page_size': '20',
      });
      expect(find.text('Title 1'), findsOneWidget);
    });

    testWidgets('reaching the bottom loads the next page and appends it',
        (tester) async {
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)], page: 1, hasNext: true),
        _notificationsPage(2): _page([_n(3)], page: 2),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Title 1'), findsOneWidget);
      expect(find.text('Title 3'), findsOneWidget); // page 2 arrived
      expect(backend.queriesFor('GET /notifications').length, 2);
    });

    testWidgets('it stops asking once has_next is false', (tester) async {
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)]),   // has_next: false
      });
      await _openNotifications(tester, backend);

      expect(backend.callsTo('GET /notifications'), 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a row arriving on two pages is shown once', (tester) async {
      // A new notification between the two requests shifts the window, so
      // page 2 repeats the row that page 1 ended on.
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)], page: 1, hasNext: true),
        _notificationsPage(2): _page([_n(2), _n(3)], page: 2),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Title 2'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('a failed next page keeps the loaded rows and offers a retry',
        (tester) async {
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)], page: 1, hasNext: true),
        _notificationsPage(2):
            const Reply({'detail': 'الخدمة غير متوفرة حالياً'}, status: 503),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Title 1'), findsOneWidget);      // nothing was lost
      expect(find.text('الخدمة غير متوفرة حالياً'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      // It must not keep hammering the failed page by itself.
      expect(backend.callsTo('GET /notifications'), 2);

      backend.routes[_notificationsPage(2)] = _page([_n(3)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Title 3'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsNothing);
      expect(backend.callsTo('GET /notifications'), 3);
    });

    testWidgets('a failed first page offers a retry that reloads', (tester) async {
      final backend = _Backend({
        _notificationsPage(1):
            const Reply({'detail': 'Invalid or expired token'}, status: 401),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Invalid or expired token'), findsOneWidget);

      backend.routes[_notificationsPage(1)] = _page([_n(1)]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Title 1'), findsOneWidget);
    });

    testWidgets('pull-to-refresh starts over at page 1', (tester) async {
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)], page: 1, hasNext: true),
        _notificationsPage(2): _page([_n(3)], page: 2),
      });
      await _openNotifications(tester, backend);
      expect(find.text('Title 3'), findsOneWidget);

      // The list looks different now.
      backend.routes[_notificationsPage(1)] = _page([_n(9)]);
      await _pullToRefresh(tester);

      expect(find.text('Title 9'), findsOneWidget);
      expect(find.text('Title 1'), findsNothing);  // page 1 was replaced
      expect(find.text('Title 3'), findsNothing);  // and page 2 dropped
    });

    testWidgets('loading more pages never marks a notification read',
        (tester) async {
      final backend = _Backend({
        _notificationsPage(1): _page([_n(1), _n(2)], page: 1, hasNext: true),
        _notificationsPage(2): _page([_n(3), _n(4)], page: 2, hasNext: true),
        _notificationsPage(3): _page([_n(5)], page: 3),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Title 5'), findsOneWidget);          // three pages in
      expect(backend.requests.every((r) => r.method == 'GET'), isTrue);
      expect(backend.callsTo('POST /notifications/read-all'), 0);
      for (final id in [1, 2, 3, 4, 5]) {
        expect(backend.callsTo('POST /notifications/$id/read'), 0);
      }
    });

    testWidgets('a superseded page reply does not overwrite newer rows',
        (tester) async {
      // Driven through a stub service, not HTTP: the point is the ORDER in
      // which two in-flight replies land, and ApiClient's own 20 s timeout
      // would otherwise decide that for us.
      final service = _StubNotificationService();
      useTallScreen(tester);
      await tester.pumpWidget(MaterialApp(home: NotificationsScreen(service: service)));
      await tester.pump();

      // Page 1 arrives and the footer asks for page 2, which stays open.
      service.answer(0, ids: [1, 2], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(find.text('Title 1'), findsOneWidget);
      expect(service.requestedPages, [1, 2]);

      // A refresh replaces everything while page 2 is still unanswered.
      await _pullToRefreshWhileLoading(tester);
      expect(service.requestedPages, [1, 2, 1]);
      service.answer(2, ids: [9], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Title 9'), findsOneWidget);

      // Only now does the superseded page 2 answer.
      service.answer(1, ids: [3], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Title 9'), findsOneWidget);
      expect(find.text('Title 3'), findsNothing, reason: 'stale page 2 was applied');
      expect(find.text('Title 1'), findsNothing);
    });

    testWidgets('a page superseded by a mark-read reload is dropped too',
        (tester) async {
      final service = _StubNotificationService();
      useTallScreen(tester);
      await tester.pumpWidget(MaterialApp(home: NotificationsScreen(service: service)));
      await tester.pump();
      service.answer(0, ids: [1, 2], page: 1, hasNext: true);
      await _pumpAWhile(tester);

      // Tapping an unread row marks it read and reloads page 1 - unchanged
      // behaviour - which supersedes the page 2 still in flight.
      await tester.tap(find.text('Title 1'));
      await _pumpAWhile(tester);
      expect(service.markedRead, [1]);
      expect(service.requestedPages, [1, 2, 1]);

      service.answer(2, ids: [1], page: 1, hasNext: false, read: true);
      await _pumpAWhile(tester);
      service.answer(1, ids: [3], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Title 3'), findsNothing);
      expect(tester.widget<Text>(find.text('Title 1')).style?.fontWeight,
          FontWeight.normal);
    });

    testWidgets('a legacy backend: the whole array, and nothing more asked for',
        (tester) async {
      // Only a bare route, as a server that ignores page/page_size has.
      final backend = _Backend({
        'GET /notifications': Reply([for (var i = 1; i <= 30; i++) _n(i)]),
      });
      await _openNotifications(tester, backend);

      expect(find.text('Title 1'), findsOneWidget);
      expect(backend.callsTo('GET /notifications'), 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  // ================================================== admin users tab

  group('admin users paging', () {
    testWidgets('the first load asks for page 1, then pages on', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/services': Reply([_listing(1)]),
        _usersPage(1): _page([_user(1), _user(2)], page: 1, hasNext: true),
        _usersPage(2): _page([_user(3)], page: 2),
      });
      await _openAdmin(tester, backend, 'المستخدمون');

      expect(backend.queriesFor('GET /admin/users'),
          ['page=1&page_size=20', 'page=2&page_size=20']);
      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('User 3'), findsOneWidget);
    });

    testWidgets('a duplicated row across pages is shown once', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/services': Reply([_listing(1)]),
        _usersPage(1): _page([_user(1), _user(2)], page: 1, hasNext: true),
        _usersPage(2): _page([_user(2), _user(3)], page: 2),
      });
      await _openAdmin(tester, backend, 'المستخدمون');

      expect(find.text('User 2'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(3)); // one row each
    });

    testWidgets('a failed page keeps the rows and retries only when asked',
        (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/services': Reply([_listing(1)]),
        _usersPage(1): _page([_user(1)], page: 1, hasNext: true),
        _usersPage(2): const Reply({'detail': 'Admin access required'}, status: 403),
      });
      await _openAdmin(tester, backend, 'المستخدمون');

      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('Admin access required'), findsOneWidget);
      expect(backend.callsTo('GET /admin/users'), 2);

      backend.routes[_usersPage(2)] = _page([_user(2)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('User 2'), findsOneWidget);
    });

    testWidgets('a moderation action reloads from page 1', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/services': Reply([_listing(1)]),
        _usersPage(1): _page([_user(1)], page: 1, hasNext: true),
        _usersPage(2): _page([_user(2)], page: 2),
        'PUT /admin/users/1/active-status': Reply(_user(1)),
      });
      await _openAdmin(tester, backend, 'المستخدمون');
      expect(find.text('User 2'), findsOneWidget); // two pages loaded

      // After the action only page 1 is on screen again.
      backend.routes[_usersPage(1)] = _page([_user(1)], page: 1);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.text('User 1'), findsOneWidget);
      expect(find.text('User 2'), findsNothing);
    });

    testWidgets('a non-admin is refused, paginated or not', (tester) async {
      const refused = Reply({'detail': 'Admin access required'}, status: 403);
      final backend = _Backend({
        'GET /admin/stats': refused,
        'GET /admin/services': refused,
        'GET /admin/users': refused,
        _usersPage(1): refused,
      });
      await _openAdmin(tester, backend, 'المستخدمون');

      expect(find.text('Admin access required'), findsWidgets);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('a legacy backend fills the tab in one request', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/services': Reply([_listing(1)]),
        'GET /admin/users': Reply([for (var i = 1; i <= 25; i++) _user(i)]),
      });
      await _openAdmin(tester, backend, 'المستخدمون');

      expect(find.text('User 1'), findsOneWidget);
      expect(backend.callsTo('GET /admin/users'), 1);
    });
  });

  // =============================================== admin services tab

  group('admin services paging', () {
    testWidgets('pages on, and stops when has_next is false', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/users': Reply([_user(1)]),
        _servicesPage(1): _page([_listing(1), _listing(2)], page: 1, hasNext: true),
        _servicesPage(2): _page([_listing(3)], page: 2),
      });
      await _openAdmin(tester, backend, 'الخدمات');

      expect(find.text('Listing 1'), findsOneWidget);
      expect(find.text('Listing 3'), findsOneWidget);
      expect(backend.callsTo('GET /admin/services'), 2);
    });

    testWidgets('a superseded page reply does not overwrite newer rows',
        (tester) async {
      final service = _StubAdminService();
      useTallScreen(tester);
      await tester.pumpWidget(
          MaterialApp(home: AdminDashboardScreen(adminService: service)));
      await _pumpAWhile(tester);
      await tester.tap(find.widgetWithText(Tab, 'الخدمات'));
      await _pumpAWhile(tester);

      service.answerServices(0, ids: [1], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(find.text('Listing 1'), findsOneWidget);
      expect(service.requestedServicePages, [1, 2]);

      await _pullToRefreshWhileLoading(tester);
      expect(service.requestedServicePages, [1, 2, 1]);
      service.answerServices(2, ids: [9], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Listing 9'), findsOneWidget);

      service.answerServices(1, ids: [2], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Listing 9'), findsOneWidget);
      expect(find.text('Listing 2'), findsNothing, reason: 'stale page 2 was applied');
    });

    testWidgets('a malformed body is an error, not an empty list', (tester) async {
      final backend = _Backend({
        'GET /admin/stats': const Reply(_stats),
        'GET /admin/users': Reply([_user(1)]),
        _servicesPage(1): const Reply({'unexpected': 'shape'}),
      });
      await _openAdmin(tester, backend, 'الخدمات');

      expect(find.text('حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });
  });
}
