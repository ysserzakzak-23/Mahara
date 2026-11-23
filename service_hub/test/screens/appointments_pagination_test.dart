// Incremental paging on the bookings screen (Phase 4, Group 2).
//
// GET /appointments/me has two consumers in the app, and they are the same
// widget twice: _AppointmentList with asProvider false ("حجوزاتي") and with
// asProvider true ("جدول مواعيدي"). Both are covered here, because each
// keeps its own list, its own page number and its own request generation.
//
// What is pinned down is what a user would notice: the first page arrives,
// reaching the bottom fetches the next one, it stops when `has_next` says
// so, a row that shifts between requests is not listed twice, a failed page
// keeps what is already on screen and offers a retry (without retrying
// forever by itself), pull-to-refresh starts over, an appointment action
// reloads from page 1, and a reply from a superseded request never
// overwrites newer rows.
//
// A legacy backend — one that ignores `page` and returns the whole array —
// is covered too: everything shows and nothing more is asked for.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/paged_result.dart';
import 'package:service_hub/core/config/api_config.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/booking/booking_screen.dart';
import 'package:service_hub/features/booking/data/appointment_models.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _customerUser = {
  'id': 1, 'email': 'a@b.com', 'role': 'user', 'is_provider': false, 'is_active': true,
};
const _providerUser = {
  'id': 2, 'email': 'p@b.com', 'role': 'user', 'is_provider': true, 'is_active': true,
};

/// A booking whose card text identifies it: the card's title is the
/// service title, so each row needs its own.
Map<String, dynamic> _booking(int id, {String status = 'pending'}) => {
      'id': id,
      'service_id': 100 + id,
      'service_title': 'Booking $id',
      'start_time': '2026-10-05T10:00:00',
      'end_time': '2026-10-05T11:00:00',
      'status': status,
      'customer_notes': null,
      'cancellation_reason': null,
      'created_at': '2026-10-05T09:00:00',
      'customer': withoutAvatar(providerJson(id: 1, name: 'Customer')),
      'provider': withoutAvatar(providerJson(id: 2, name: 'Provider')),
    };

/// A fake backend answering per METHOD + path + query.
class _Backend {
  _Backend(Map<String, Reply> routes) : routes = Map.of(routes) {
    client = MockClient((req) async {
      requests.add(req);
      final withQuery = _key(req, withQuery: true);
      final bare = _key(req);
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
  late final http.Client client;

  static String _key(http.Request r, {bool withQuery = false}) {
    final path = r.url.path.replaceFirst(ApiConfig.apiPrefix, '');
    return withQuery ? '${r.method} $path?${r.url.query}' : '${r.method} $path';
  }

  int callsTo(String key) => requests.where((r) => _key(r) == key).length;

  List<String> get appointmentQueries => requests
      .where((r) => _key(r) == 'GET /appointments/me')
      .map((r) => r.url.query)
      .toList();
}

/// The exact URL the service builds for one page of one side.
String _pageKey(int page, {bool asProvider = false}) =>
    'GET /appointments/me?as_provider=$asProvider&page=$page&page_size=20';

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

Widget _app(_Backend backend, {AppointmentService? appointments}) {
  final store = TokenStore();
  final api = ApiClient(httpClient: backend.client, tokenStore: store);
  return MaterialApp(
    home: BookingScreen(
      authService: AuthService(apiClient: api, tokenStore: store),
      appointmentService: appointments ?? AppointmentService(apiClient: api),
    ),
  );
}

Future<void> _open(WidgetTester tester, _Backend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend));
  await tester.pumpAndSettle();
}

Future<void> _openSchedule(WidgetTester tester) async {
  await tester.tap(find.text('جدول مواعيدي'));
  await tester.pumpAndSettle();
}

Future<void> _pullToRefresh(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).last, const Offset(0, 400), 1200);
  await tester.pumpAndSettle();
}

/// Pumps a fixed stretch of frames instead of settling.
///
/// The stub-driven tests leave a page request unanswered on purpose, so the
/// footer's progress indicator keeps animating and pumpAndSettle would
/// never return.
Future<void> _pumpAWhile(WidgetTester tester) => pumpFrames(tester, frames: 25);

Future<void> _pullToRefreshWhileLoading(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).last, const Offset(0, 400), 1200);
  await _pumpAWhile(tester);
}

/// An AppointmentService whose every `myAppointments` call is answered by
/// hand, so a test decides which of two in-flight replies lands first.
/// Going through HTTP instead would hand that decision to ApiClient's own
/// 20 s timeout.
class _StubAppointmentService extends AppointmentService {
  _StubAppointmentService() : super(apiClient: _unusedApi());

  final List<bool> requestedSides = [];
  final List<int> requestedPages = [];
  final List<int> accepted = [];
  final List<Completer<PagedResult<Appointment>>> _calls = [];

  @override
  Future<PagedResult<Appointment>> myAppointments({
    bool asProvider = false,
    int? page,
    int? pageSize,
  }) {
    requestedSides.add(asProvider);
    requestedPages.add(page ?? 1);
    final completer = Completer<PagedResult<Appointment>>();
    _calls.add(completer);
    return completer.future;
  }

  @override
  Future<Appointment> accept(int id) async {
    accepted.add(id);
    return Appointment.fromJson(_booking(id, status: 'confirmed'));
  }

  /// Answers the [call]-th `myAppointments` call (0-based, request order).
  void answer(
    int call, {
    required List<int> ids,
    required int page,
    required bool hasNext,
    String status = 'pending',
  }) {
    _calls[call].complete(PagedResult<Appointment>(
      items: [
        for (final id in ids) Appointment.fromJson(_booking(id, status: status)),
      ],
      page: page,
      pageSize: 20,
      hasNext: hasNext,
    ));
  }
}

ApiClient _unusedApi() => ApiClient(
      httpClient: MockClient(
        (_) async => http.Response('[]', 200, headers: jsonHeaders),
      ),
      tokenStore: TokenStore(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  // ======================================================= customer bookings

  group('my bookings (asProvider: false)', () {
    testWidgets('the first load asks for page 1 of the customer side',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1)]),
      });
      await _open(tester, backend);

      expect(backend.appointmentQueries, ['as_provider=false&page=1&page_size=20']);
      expect(find.text('Booking 1'), findsOneWidget);
    });

    testWidgets('reaching the bottom loads the next page and appends it',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1), _booking(2)], page: 1, hasNext: true),
        _pageKey(2): _page([_booking(3)], page: 2),
      });
      await _open(tester, backend);

      expect(find.text('Booking 1'), findsOneWidget);
      expect(find.text('Booking 3'), findsOneWidget);   // page 2 arrived
      expect(backend.appointmentQueries.length, 2);
    });

    testWidgets('three pages are walked and then it stops', (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1)], page: 1, hasNext: true),
        _pageKey(2): _page([_booking(2)], page: 2, hasNext: true),
        _pageKey(3): _page([_booking(3)], page: 3),
      });
      await _open(tester, backend);

      expect(find.text('Booking 3'), findsOneWidget);
      expect(backend.appointmentQueries.length, 3);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('it asks for nothing more when has_next is false',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1), _booking(2)]),   // has_next: false
      });
      await _open(tester, backend);

      expect(backend.appointmentQueries.length, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a booking arriving on two pages is listed once',
        (tester) async {
      // A new booking between the two requests shifts the window, so page 2
      // repeats the row page 1 ended on.
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1), _booking(2)], page: 1, hasNext: true),
        _pageKey(2): _page([_booking(2), _booking(3)], page: 2),
      });
      await _open(tester, backend);

      expect(find.text('Booking 2'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('a failed next page keeps the loaded rows and offers a retry',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1), _booking(2)], page: 1, hasNext: true),
        _pageKey(2): const Reply({'detail': 'الخدمة غير متوفرة حالياً'}, status: 503),
      });
      await _open(tester, backend);

      expect(find.text('Booking 1'), findsOneWidget);    // nothing was lost
      expect(find.text('الخدمة غير متوفرة حالياً'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      // It must not keep hammering the failed page by itself.
      expect(backend.appointmentQueries.length, 2);

      backend.routes[_pageKey(2)] = _page([_booking(3)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Booking 3'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsNothing);
      expect(backend.appointmentQueries.length, 3);
    });

    testWidgets('a failed first page offers a retry that reloads',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): const Reply({'detail': 'boom'}, status: 500),
      });
      await _open(tester, backend);

      expect(find.text('boom'), findsOneWidget);

      backend.routes[_pageKey(1)] = _page([_booking(1)]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Booking 1'), findsOneWidget);
    });

    testWidgets('pull-to-refresh starts over at page 1', (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([_booking(1), _booking(2)], page: 1, hasNext: true),
        _pageKey(2): _page([_booking(3)], page: 2),
      });
      await _open(tester, backend);
      expect(find.text('Booking 3'), findsOneWidget);

      backend.routes[_pageKey(1)] = _page([_booking(9)]);
      await _pullToRefresh(tester);

      expect(find.text('Booking 9'), findsOneWidget);
      expect(find.text('Booking 1'), findsNothing);   // page 1 was replaced
      expect(find.text('Booking 3'), findsNothing);   // and page 2 dropped
    });

    testWidgets('a malformed body is an error, not an empty list',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): const Reply({'unexpected': 'shape'}),
      });
      await _open(tester, backend);

      expect(find.text('حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.'), findsOneWidget);
      expect(find.text('ليس لديك حجوزات بعد.'), findsNothing);
    });

    testWidgets('a legacy backend: the whole array, and nothing more asked for',
        (tester) async {
      // Only a bare route, as a server that ignores page/page_size has.
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        'GET /appointments/me': Reply([for (var i = 1; i <= 30; i++) _booking(i)]),
      });
      await _open(tester, backend);

      expect(find.text('Booking 1'), findsOneWidget);
      expect(backend.appointmentQueries.length, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an empty first page still shows the empty message',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_customerUser),
        _pageKey(1): _page([]),
      });
      await _open(tester, backend);

      expect(find.text('ليس لديك حجوزات بعد.'), findsOneWidget);
    });

    testWidgets('a superseded page reply does not overwrite newer rows',
        (tester) async {
      final stub = _StubAppointmentService();
      final backend = _Backend({'GET /users/me': const Reply(_customerUser)});
      useTallScreen(tester);
      await tester.pumpWidget(_app(backend, appointments: stub));
      await _pumpAWhile(tester);

      // Page 1 arrives and the footer asks for page 2, which stays open.
      stub.answer(0, ids: [1, 2], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(find.text('Booking 1'), findsOneWidget);
      expect(stub.requestedPages, [1, 2]);

      // A refresh replaces everything while page 2 is still unanswered.
      await _pullToRefreshWhileLoading(tester);
      expect(stub.requestedPages, [1, 2, 1]);
      stub.answer(2, ids: [9], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Booking 9'), findsOneWidget);

      // Only now does the superseded page 2 answer.
      stub.answer(1, ids: [3], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Booking 9'), findsOneWidget);
      expect(find.text('Booking 3'), findsNothing, reason: 'stale page 2 was applied');
      expect(find.text('Booking 1'), findsNothing);
    });
  });

  // ====================================================== provider schedule

  group('my schedule (asProvider: true)', () {
    testWidgets('the schedule tab pages the provider side on its own',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([_booking(1)]),
        _pageKey(1, asProvider: true):
            _page([_booking(50), _booking(51)], page: 1, hasNext: true),
        _pageKey(2, asProvider: true): _page([_booking(52)], page: 2),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      expect(find.text('Booking 50'), findsOneWidget);
      expect(find.text('Booking 52'), findsOneWidget);   // page 2 arrived
      expect(
        backend.appointmentQueries,
        [
          'as_provider=false&page=1&page_size=20',
          'as_provider=true&page=1&page_size=20',
          'as_provider=true&page=2&page_size=20',
        ],
      );
    });

    testWidgets('the two tabs keep separate lists and page numbers',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([_booking(1)], page: 1, hasNext: true),
        _pageKey(2): _page([_booking(2)], page: 2),
        _pageKey(1, asProvider: true): _page([_booking(50)]),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      // The provider side stopped at its own page 1; the customer side had
      // walked to page 2. Neither leaked into the other.
      expect(find.text('Booking 50'), findsOneWidget);
      expect(find.text('Booking 1'), findsNothing);
      expect(find.text('Booking 2'), findsNothing);
      expect(backend.callsTo('GET /appointments/me'), 3);
    });

    testWidgets('a duplicated row across pages is listed once', (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([]),
        _pageKey(1, asProvider: true):
            _page([_booking(50), _booking(51)], page: 1, hasNext: true),
        _pageKey(2, asProvider: true):
            _page([_booking(51), _booking(52)], page: 2),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      expect(find.text('Booking 51'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('a failed page on the schedule keeps its rows and retries',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([]),
        _pageKey(1, asProvider: true): _page([_booking(50)], page: 1, hasNext: true),
        _pageKey(2, asProvider: true): const Reply({'detail': 'boom'}, status: 500),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      expect(find.text('Booking 50'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);

      backend.routes[_pageKey(2, asProvider: true)] =
          _page([_booking(51)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Booking 51'), findsOneWidget);
    });

    testWidgets('accepting a pending request reloads the schedule from page 1',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([]),
        _pageKey(1, asProvider: true): _page([_booking(50)], page: 1, hasNext: true),
        _pageKey(2, asProvider: true): _page([_booking(51)], page: 2),
        'POST /appointments/50/accept': Reply(_booking(50, status: 'confirmed')),
      });
      await _open(tester, backend);
      await _openSchedule(tester);
      expect(find.text('Booking 51'), findsOneWidget);     // two pages loaded

      // After the action only page 1 is on screen again, as this screen has
      // always behaved.
      backend.routes[_pageKey(1, asProvider: true)] =
          _page([_booking(50, status: 'confirmed')], page: 1);
      await tester.tap(find.byTooltip('قبول').first);   // Booking 50's
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/50/accept'), 1);
      expect(find.text('Booking 50'), findsOneWidget);
      expect(find.text('Booking 51'), findsNothing);
      expect(find.text('مؤكد'), findsOneWidget);
    });

    testWidgets('completing a confirmed booking reloads the schedule',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([]),
        _pageKey(1, asProvider: true):
            _page([_booking(50, status: 'confirmed')], page: 1),
        'POST /appointments/50/complete':
            Reply(_booking(50, status: 'completed')),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      await tester.tap(find.text('مؤكد'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تحديد كمكتمل'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/50/complete'), 1);
      expect(backend.callsTo('GET /appointments/me'), 3);  // customer + 2 schedule
    });

    testWidgets('a legacy backend fills the schedule in one request',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        'GET /appointments/me': Reply([for (var i = 50; i < 70; i++) _booking(i)]),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      expect(find.text('Booking 50'), findsOneWidget);
      // One per tab, and no page 2 for either.
      expect(backend.callsTo('GET /appointments/me'), 2);
    });

    testWidgets('an empty schedule page still shows the empty message',
        (tester) async {
      final backend = _Backend({
        'GET /users/me': const Reply(_providerUser),
        _pageKey(1): _page([]),
        _pageKey(1, asProvider: true): _page([]),
      });
      await _open(tester, backend);
      await _openSchedule(tester);

      expect(find.text('لم يحجزك أحد حتى الآن.'), findsOneWidget);
    });

    testWidgets('a superseded page reply does not overwrite newer rows',
        (tester) async {
      final stub = _StubAppointmentService();
      final backend = _Backend({'GET /users/me': const Reply(_providerUser)});
      useTallScreen(tester);
      await tester.pumpWidget(_app(backend, appointments: stub));
      await _pumpAWhile(tester);

      // The customer tab builds first; answer it and leave it alone.
      expect(stub.requestedSides, [false]);
      stub.answer(0, ids: [1], page: 1, hasNext: false);
      await _pumpAWhile(tester);

      await tester.tap(find.text('جدول مواعيدي'));
      await _pumpAWhile(tester);
      expect(stub.requestedSides, [false, true]);

      stub.answer(1, ids: [50, 51], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(find.text('Booking 50'), findsOneWidget);
      expect(stub.requestedSides, [false, true, true]);   // page 2 in flight

      await _pullToRefreshWhileLoading(tester);
      expect(stub.requestedPages, [1, 1, 2, 1]);
      stub.answer(3, ids: [59], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Booking 59'), findsOneWidget);

      // The superseded page 2 answers last.
      stub.answer(2, ids: [52], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Booking 59'), findsOneWidget);
      expect(find.text('Booking 52'), findsNothing, reason: 'stale page 2 was applied');
      expect(find.text('Booking 50'), findsNothing);
    });
  });
}
