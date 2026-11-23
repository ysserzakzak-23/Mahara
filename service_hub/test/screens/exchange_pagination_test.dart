// Incremental paging in the Exchange Hub's five tabs (Phase 4, Group 3.4).
//
// Four data flows behind five tabs: Browse (which switches between the
// open-requests list and the smart search as the query changes), My
// Requests, My Interests, and My Proposals in its sent and received
// halves. Each tab is its own State object, so each keeps its own page
// number, its own has_next, its own errors and its own request
// generation — and this file checks that they really are separate.
//
// What is pinned down: the first page is asked for with the page size,
// reaching the bottom fetches the next one, it stops at has_next false, a
// row arriving twice is listed once, a failed page keeps what is loaded
// and offers a retry without looping, a mutation reloads from page 1, a
// new search query resets paging and never mixes the two result sets, and
// a reply to a superseded request is dropped.

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
import 'package:service_hub/features/exchange/data/exchange_models.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:service_hub/features/exchange/exchange_hub_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _myId = 99;
const _firstPage = 'page=1&page_size=20';

/// A request whose card text identifies it: the card shows the offered
/// service's title.
Map<String, dynamic> _request(int id, {int ownerId = 10}) =>
    exchangeRequestNoAvatar(
      id: id,
      ownerId: ownerId,
      offeredTitle: 'Request $id',
      offeredServiceId: 1000 + id,
    );

Map<String, dynamic> _ranked(int id, {double? rating, double? relevance}) {
  final json = _request(id);
  json['offered_service_rating'] = rating;
  json['offered_service_review_count'] = rating == null ? 0 : 3;
  json['relevance_score'] = relevance;
  return json;
}

Map<String, dynamic> _proposal(int id, {String title = 'Offer'}) =>
    exchangeProposalNoAvatar(id: id, proposedTitle: '$title $id');

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

  List<Uri> urlsFor(String key) =>
      requests.where((r) => _key(r) == key).map((r) => r.url).toList();
}

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

// The exact URLs each tab builds.
String browseKey(int page) =>
    'GET /exchange-requests?exclude_user_id=$_myId&page=$page&page_size=20';
String mineKey(int page) => 'GET /exchange-requests/me?page=$page&page_size=20';
String interestsKey(int page) =>
    'GET /exchange-requests/interests?page=$page&page_size=20';
String proposalsKey(int page, {required bool sent}) =>
    'GET /exchange-proposals/me?sent=$sent&page=$page&page_size=20';
String searchKey(String q, int page) =>
    'GET /exchange-requests/search?q=${Uri.encodeQueryComponent(q)}'
    '&page=$page&page_size=20';

/// Every tab's first page, so a test only overrides what it cares about.
Map<String, Reply> _baseRoutes() => {
      'GET /users/me': const Reply(
        {'id': _myId, 'email': 'me@b.com', 'role': 'user', 'is_provider': true, 'is_active': true},
      ),
      browseKey(1): _page([]),
      mineKey(1): _page([]),
      interestsKey(1): _page([]),
      proposalsKey(1, sent: true): _page([]),
      proposalsKey(1, sent: false): _page([]),
    };

_Backend _backend([Map<String, Reply> extra = const {}]) =>
    _Backend({..._baseRoutes(), ...extra});

Widget _app(_Backend backend, {ExchangeService? exchange}) {
  final store = TokenStore();
  final api = ApiClient(httpClient: backend.client, tokenStore: store);
  return MaterialApp(
    home: ExchangeHubScreen(
      tokenStore: store,
      exchangeService: exchange ?? ExchangeService(apiClient: api),
      detailBuilder: (r) => Scaffold(
        appBar: AppBar(),
        body: Text('DETAIL ${r.id}'),
      ),
      createRequestBuilder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('DONE'),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester, _Backend backend,
    {ExchangeService? exchange}) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend, exchange: exchange));
  await tester.pumpAndSettle();
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

/// Pumps a fixed stretch of frames instead of settling: the stub-driven
/// tests leave a page unanswered on purpose, so the footer indicator keeps
/// animating and pumpAndSettle would never return.
Future<void> _pumpAWhile(WidgetTester tester) => pumpFrames(tester, frames: 25);

/// An ExchangeService whose list calls are answered by hand, so a test
/// decides which of two in-flight replies lands first. Going through HTTP
/// would hand that decision to ApiClient's own 20 s timeout.
class _StubExchangeService extends ExchangeService {
  _StubExchangeService() : super(apiClient: _unusedApi());

  final List<String> asked = [];
  final List<Completer<PagedResult<ExchangeRequestModel>>> _calls = [];

  @override
  Future<PagedResult<ExchangeRequestModel>> listOpenRequests({
    int? excludeUserId,
    int? page,
    int? pageSize,
  }) =>
      _record('browse', page);

  @override
  Future<PagedResult<ExchangeRequestModel>> searchRequests(
    String query, {
    int? page,
    int? pageSize,
  }) =>
      _record('search:$query', page);

  @override
  Future<PagedResult<ExchangeRequestModel>> listMyRequests({
    int? page,
    int? pageSize,
  }) =>
      _record('mine', page);

  @override
  Future<PagedResult<ExchangeRequestModel>> listInterests({
    String? query,
    int? page,
    int? pageSize,
  }) =>
      _record('interests:${query ?? ''}', page);

  @override
  Future<PagedResult<ExchangeProposalModel>> listMyProposals({
    required bool sent,
    int? page,
    int? pageSize,
  }) async =>
      PagedResult<ExchangeProposalModel>.complete(const []);

  Future<PagedResult<ExchangeRequestModel>> _record(String what, int? page) {
    asked.add('$what#${page ?? 1}');
    final completer = Completer<PagedResult<ExchangeRequestModel>>();
    _calls.add(completer);
    return completer.future;
  }

  /// Answers the [call]-th list call (0-based, in request order).
  void answer(
    int call, {
    required List<int> ids,
    required int page,
    required bool hasNext,
  }) {
    _calls[call].complete(PagedResult<ExchangeRequestModel>(
      items: [for (final id in ids) ExchangeRequestModel.fromJson(_request(id))],
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
  setUp(() => SharedPreferences.setMockInitialValues({
        'access_token': tokenFor(_myId),
      }));

  // ===================================================== what each tab asks

  group('the first page each tab asks for', () {
    testWidgets('browse sends the exclusion and the page size', (tester) async {
      final backend = _backend({browseKey(1): _page([_request(1)])});
      await _open(tester, backend);

      final url = backend.urlsFor('GET /exchange-requests').single;
      expect(url.queryParameters, {
        'exclude_user_id': '$_myId',
        'page': '1',
        'page_size': '20',
      });
      expect(find.text('Request 1'), findsOneWidget);
    });

    testWidgets('browse stays unauthenticated', (tester) async {
      final backend = _backend({browseKey(1): _page([_request(1)])});
      await _open(tester, backend);

      final request = backend.requests
          .firstWhere((r) => r.url.path.endsWith('/exchange-requests'));
      expect(request.headers.containsKey('Authorization'), isFalse);
    });

    testWidgets('my requests sends page parameters with the token',
        (tester) async {
      final backend = _backend({mineKey(1): _page([_request(2)])});
      await _open(tester, backend);
      await _tab(tester, 'طلباتي');

      final request = backend.requests
          .firstWhere((r) => r.url.path.endsWith('/exchange-requests/me'));
      expect(request.url.queryParameters, {'page': '1', 'page_size': '20'});
      expect(request.headers['Authorization'], isNotNull);
      expect(find.text('Request 2'), findsOneWidget);
    });

    testWidgets('interests sends page parameters with the token',
        (tester) async {
      final backend = _backend({interestsKey(1): _page([_ranked(3, rating: 4.5)])});
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');

      final request = backend.requests.firstWhere(
          (r) => r.url.path.endsWith('/exchange-requests/interests'));
      expect(request.url.queryParameters, {'page': '1', 'page_size': '20'});
      expect(request.headers['Authorization'], isNotNull);
      expect(find.text('Request 3'), findsOneWidget);
    });

    testWidgets('both proposal tabs send their own side and page',
        (tester) async {
      final backend = _backend({
        proposalsKey(1, sent: false): _page([_proposal(1, title: 'In')]),
        proposalsKey(1, sent: true): _page([_proposal(2, title: 'Out')]),
      });
      await _open(tester, backend);
      await _tab(tester, 'العروض الواردة');
      expect(find.textContaining('In 1'), findsOneWidget);

      await _tab(tester, 'العروض المرسلة');
      expect(find.textContaining('Out 2'), findsOneWidget);

      final sides = backend
          .urlsFor('GET /exchange-proposals/me')
          .map((u) => u.queryParameters['sent'])
          .toSet();
      expect(sides, {'true', 'false'});
      for (final url in backend.urlsFor('GET /exchange-proposals/me')) {
        expect(url.queryParameters['page'], '1');
        expect(url.queryParameters['page_size'], '20');
      }
    });

    testWidgets('a legacy bare array is read as one complete page',
        (tester) async {
      // Only the bare route for browse, as a backend that ignores the
      // parameters has: the whole array, which the parser reads as one
      // complete page.
      final routes = _baseRoutes()..remove(browseKey(1));
      final backend = _Backend({
        ...routes,
        'GET /exchange-requests': Reply([for (var i = 1; i <= 30; i++) _request(i)]),
      });
      await _open(tester, backend);

      expect(find.text('Request 1'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests'), 1);
    });
  });

  // ================================================== loading further pages

  group('loading more', () {
    testWidgets('browse appends the next page at the bottom', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1), _request(2)], page: 1, hasNext: true),
        browseKey(2): _page([_request(3)], page: 2),
      });
      await _open(tester, backend);

      expect(find.text('Request 1'), findsOneWidget);
      expect(find.text('Request 3'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests'), 2);
    });

    testWidgets('it stops when has_next is false', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1), _request(2)]),
      });
      await _open(tester, backend);

      expect(backend.callsTo('GET /exchange-requests'), 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('three pages are walked in order', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)], page: 1, hasNext: true),
        browseKey(2): _page([_request(2)], page: 2, hasNext: true),
        browseKey(3): _page([_request(3)], page: 3),
      });
      await _open(tester, backend);

      expect(backend.urlsFor('GET /exchange-requests').map((u) => u.queryParameters['page']),
          ['1', '2', '3']);
      expect(find.text('Request 3'), findsOneWidget);
    });

    testWidgets('a row arriving on two pages is listed once', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1), _request(2)], page: 1, hasNext: true),
        browseKey(2): _page([_request(2), _request(3)], page: 2),
      });
      await _open(tester, backend);

      expect(find.text('Request 2'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('my requests pages too', (tester) async {
      final backend = _backend({
        mineKey(1): _page([_request(1)], page: 1, hasNext: true),
        mineKey(2): _page([_request(2)], page: 2),
      });
      await _open(tester, backend);
      await _tab(tester, 'طلباتي');

      expect(find.text('Request 2'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests/me'), 2);
    });

    testWidgets('interests pages too, keeping the ranking fields',
        (tester) async {
      final backend = _backend({
        interestsKey(1): _page([_ranked(1, rating: 5.0)], page: 1, hasNext: true),
        interestsKey(2): _page([_ranked(2, rating: 3.0)], page: 2),
      });
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');

      expect(find.text('Request 1'), findsOneWidget);
      expect(find.text('Request 2'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests/interests'), 2);
    });

    testWidgets('each proposal side pages on its own', (tester) async {
      final backend = _backend({
        proposalsKey(1, sent: false): _page([_proposal(1)], page: 1, hasNext: true),
        proposalsKey(2, sent: false): _page([_proposal(2)], page: 2),
        proposalsKey(1, sent: true): _page([_proposal(50)]),
      });
      await _open(tester, backend);
      await _tab(tester, 'العروض الواردة');

      expect(find.textContaining('Offer 2'), findsOneWidget);
      final received = backend
          .urlsFor('GET /exchange-proposals/me')
          .where((u) => u.queryParameters['sent'] == 'false')
          .map((u) => u.queryParameters['page']);
      expect(received, ['1', '2']);

      // The sent side is still on its own page 1.
      await _tab(tester, 'العروض المرسلة');
      expect(find.textContaining('Offer 50'), findsOneWidget);
      expect(find.textContaining('Offer 2'), findsNothing);
      final sent = backend
          .urlsFor('GET /exchange-proposals/me')
          .where((u) => u.queryParameters['sent'] == 'true')
          .map((u) => u.queryParameters['page']);
      expect(sent, ['1']);
    });
  });

  // ============================================================ tab isolation

  group('each tab keeps its own state', () {
    testWidgets('switching tabs does not mix items', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)]),
        mineKey(1): _page([_request(2)]),
        interestsKey(1): _page([_ranked(3, rating: 4.0)]),
      });
      await _open(tester, backend);
      expect(find.text('Request 1'), findsOneWidget);

      await _tab(tester, 'طلباتي');
      expect(find.text('Request 2'), findsOneWidget);
      expect(find.text('Request 1'), findsNothing);

      await _tab(tester, 'اهتماماتي');
      expect(find.text('Request 3'), findsOneWidget);
      expect(find.text('Request 2'), findsNothing);
    });

    testWidgets('one tab paging on does not move another tab off page 1',
        (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)], page: 1, hasNext: true),
        browseKey(2): _page([_request(2)], page: 2),
        mineKey(1): _page([_request(9)]),
      });
      await _open(tester, backend);
      expect(find.text('Request 2'), findsOneWidget);   // browse walked to 2

      await _tab(tester, 'طلباتي');

      expect(find.text('Request 9'), findsOneWidget);
      expect(
        backend.urlsFor('GET /exchange-requests/me').single.queryParameters['page'],
        '1',
      );
    });

    testWidgets('a failure in one tab leaves the others working',
        (tester) async {
      final backend = _backend({
        browseKey(1): const Reply({'detail': 'boom'}, status: 500),
        mineKey(1): _page([_request(2)]),
      });
      await _open(tester, backend);
      expect(find.text('boom'), findsOneWidget);

      await _tab(tester, 'طلباتي');
      expect(find.text('Request 2'), findsOneWidget);
      expect(find.text('boom'), findsNothing);
    });
  });

  // ========================================================= failed pages

  group('a failed page', () {
    testWidgets('keeps the loaded rows and offers a retry', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1), _request(2)], page: 1, hasNext: true),
        browseKey(2): const Reply({'detail': 'الخدمة غير متوفرة'}, status: 503),
      });
      await _open(tester, backend);

      expect(find.text('Request 1'), findsOneWidget);     // nothing lost
      expect(find.text('الخدمة غير متوفرة'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      // and it must not keep hammering the failed page
      expect(backend.callsTo('GET /exchange-requests'), 2);

      backend.routes[browseKey(2)] = _page([_request(3)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Request 3'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsNothing);
    });

    testWidgets('the retry asks for the same page again', (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)], page: 1, hasNext: true),
        browseKey(2): const Reply({'detail': 'boom'}, status: 500),
      });
      await _open(tester, backend);

      backend.routes[browseKey(2)] = _page([_request(2)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(
        backend.urlsFor('GET /exchange-requests').map((u) => u.queryParameters['page']),
        ['1', '2', '2'],
      );
    });

    testWidgets('a failed proposal page keeps its rows and retries',
        (tester) async {
      final backend = _backend({
        proposalsKey(1, sent: true): _page([_proposal(1)], page: 1, hasNext: true),
        proposalsKey(2, sent: true): const Reply({'detail': 'boom'}, status: 500),
      });
      await _open(tester, backend);
      await _tab(tester, 'العروض المرسلة');

      expect(find.textContaining('Offer 1'), findsOneWidget);
      expect(find.text('boom'), findsOneWidget);

      backend.routes[proposalsKey(2, sent: true)] = _page([_proposal(2)], page: 2);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Offer 2'), findsOneWidget);
    });
  });

  // ============================================================== searching

  group('search resets pagination', () {
    testWidgets('a new query starts at page 1 and drops the old rows',
        (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1), _request(2)], page: 1, hasNext: true),
        browseKey(2): _page([_request(3)], page: 2),
        searchKey('مكيف', 1): _page([_request(50)]),
      });
      await _open(tester, backend);
      expect(find.text('Request 3'), findsOneWidget);   // two pages loaded

      await _search(tester, 'مكيف');

      expect(find.text('Request 50'), findsOneWidget);
      expect(find.text('Request 1'), findsNothing);
      expect(find.text('Request 3'), findsNothing, reason: 'old page 2 survived');
      expect(
        backend.urlsFor('GET /exchange-requests/search').single.queryParameters['page'],
        '1',
      );
    });

    testWidgets('paging within a search keeps the same query', (tester) async {
      final backend = _backend({
        searchKey('مكيف', 1): _page([_request(50)], page: 1, hasNext: true),
        searchKey('مكيف', 2): _page([_request(51)], page: 2),
      });
      await _open(tester, backend);
      await _search(tester, 'مكيف');

      expect(find.text('Request 51'), findsOneWidget);
      for (final url in backend.urlsFor('GET /exchange-requests/search')) {
        expect(url.queryParameters['q'], 'مكيف');
      }
      expect(
        backend.urlsFor('GET /exchange-requests/search').map((u) => u.queryParameters['page']),
        ['1', '2'],
      );
    });

    testWidgets('a second query never shows the first query rows',
        (tester) async {
      final backend = _backend({
        searchKey('مكيف', 1): _page([_request(50)], page: 1, hasNext: true),
        searchKey('مكيف', 2): _page([_request(51)], page: 2),
        searchKey('سباك', 1): _page([_request(60)]),
      });
      await _open(tester, backend);
      await _search(tester, 'مكيف');
      expect(find.text('Request 51'), findsOneWidget);

      await _search(tester, 'سباك');

      expect(find.text('Request 60'), findsOneWidget);
      expect(find.text('Request 50'), findsNothing);
      expect(find.text('Request 51'), findsNothing);
    });

    testWidgets('clearing the query goes back to the open list, page 1',
        (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)]),
        searchKey('مكيف', 1): _page([_request(50)]),
      });
      await _open(tester, backend);
      await _search(tester, 'مكيف');
      expect(find.text('Request 50'), findsOneWidget);

      await _search(tester, '');

      expect(find.text('Request 1'), findsOneWidget);
      expect(find.text('Request 50'), findsNothing);
      expect(
        backend.urlsFor('GET /exchange-requests').map((u) => u.queryParameters['page']),
        ['1', '1'],
      );
    });

    testWidgets('searching within interests resets its pages too',
        (tester) async {
      final backend = _backend({
        interestsKey(1): _page([_ranked(1, rating: 5.0)], page: 1, hasNext: true),
        interestsKey(2): _page([_ranked(2, rating: 4.0)], page: 2),
        'GET /exchange-requests/interests?q=%D8%B3%D8%A8%D8%A7%D9%83&$_firstPage':
            _page([_ranked(70, rating: 3.0)]),
      });
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');
      expect(find.text('Request 2'), findsOneWidget);

      await _search(tester, 'سباك');

      expect(find.text('Request 70'), findsOneWidget);
      expect(find.text('Request 1'), findsNothing);
      expect(find.text('Request 2'), findsNothing);
    });
  });

  // ========================================================== mutations

  group('mutations reload from page 1', () {
    testWidgets('creating a request reloads browse and my requests',
        (tester) async {
      final backend = _backend({
        browseKey(1): _page([_request(1)], page: 1, hasNext: true),
        browseKey(2): _page([_request(2)], page: 2),
        mineKey(1): _page([_request(9)]),
      });
      await _open(tester, backend);
      expect(find.text('Request 2'), findsOneWidget);

      backend.routes[browseKey(1)] = _page([_request(1)], page: 1);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DONE'));
      await tester.pumpAndSettle();

      // Back on browse, from page 1, with the stale page 2 gone.
      expect(find.text('Request 1'), findsOneWidget);
      expect(find.text('Request 2'), findsNothing);
      final pages = backend
          .urlsFor('GET /exchange-requests')
          .map((u) => u.queryParameters['page'])
          .toList();
      expect(pages.last, '1');
    });

    testWidgets('coming back from a proposal reloads that side from page 1',
        (tester) async {
      final backend = _backend({
        proposalsKey(1, sent: false): _page([_proposal(1)], page: 1, hasNext: true),
        proposalsKey(2, sent: false): _page([_proposal(2)], page: 2),
      });
      await _open(tester, backend);
      await _tab(tester, 'العروض الواردة');
      expect(find.textContaining('Offer 2'), findsOneWidget);

      backend.routes[proposalsKey(1, sent: false)] =
          _page([_proposal(1)], page: 1);
      await tester.tap(find.textContaining('Offer 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('DETAIL'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.textContaining('Offer 1'), findsOneWidget);
      expect(find.textContaining('Offer 2'), findsNothing);
      final pages = backend
          .urlsFor('GET /exchange-proposals/me')
          .where((u) => u.queryParameters['sent'] == 'false')
          .map((u) => u.queryParameters['page']);
      expect(pages.last, '1');
    });
  });

  // ================================================== stale replies dropped

  group('a superseded reply is dropped', () {
    testWidgets('a page still in flight when the query changes', (tester) async {
      final stub = _StubExchangeService();
      useTallScreen(tester);
      await tester.pumpWidget(_app(_backend(), exchange: stub));
      await _pumpAWhile(tester);

      // Browse page 1 arrives; the footer asks for page 2, which hangs.
      stub.answer(0, ids: [1, 2], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(find.text('Request 1'), findsOneWidget);
      expect(stub.asked, ['browse#1', 'browse#2']);

      // A search supersedes it.
      await tester.enterText(find.byType(TextField), 'مكيف');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _pumpAWhile(tester);
      expect(stub.asked, ['browse#1', 'browse#2', 'search:مكيف#1']);

      stub.answer(2, ids: [50], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Request 50'), findsOneWidget);

      // Only now does the superseded browse page 2 answer.
      stub.answer(1, ids: [3], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Request 50'), findsOneWidget);
      expect(find.text('Request 3'), findsNothing,
          reason: 'a stale page was appended to the new query');
      expect(find.text('Request 1'), findsNothing);
    });

    testWidgets('a page still in flight when the list is refreshed',
        (tester) async {
      final stub = _StubExchangeService();
      useTallScreen(tester);
      await tester.pumpWidget(_app(_backend(), exchange: stub));
      await _pumpAWhile(tester);

      stub.answer(0, ids: [1, 2], page: 1, hasNext: true);
      await _pumpAWhile(tester);
      expect(stub.asked, ['browse#1', 'browse#2']);

      // Creating a request refreshes browse while page 2 is unanswered.
      await tester.tap(find.byType(FloatingActionButton));
      await _pumpAWhile(tester);
      await tester.tap(find.text('DONE'));
      await _pumpAWhile(tester);
      expect(stub.asked.last, 'browse#1');

      stub.answer(stub.asked.length - 1, ids: [9], page: 1, hasNext: false);
      await _pumpAWhile(tester);
      expect(find.text('Request 9'), findsOneWidget);

      stub.answer(1, ids: [3], page: 2, hasNext: false);
      await _pumpAWhile(tester);

      expect(find.text('Request 9'), findsOneWidget);
      expect(find.text('Request 3'), findsNothing,
          reason: 'a stale page survived the refresh');
    });
  });

  // ===================================== the states that were there before

  group('existing states are unchanged', () {
    testWidgets('the empty message still shows on an empty first page',
        (tester) async {
      await _open(tester, _backend());

      expect(find.text('لا توجد طلبات تبادل مفتوحة حالياً.'), findsOneWidget);
    });

    testWidgets('a first-page failure still shows the Arabic message',
        (tester) async {
      await _open(
        tester,
        _backend({browseKey(1): const Reply({'detail': 'boom'}, status: 500)}),
      );

      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('a malformed body is an error, not an empty list',
        (tester) async {
      await _open(
        tester,
        _backend({browseKey(1): const Reply({'unexpected': 'shape'})}),
      );

      expect(find.text('حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.'),
          findsOneWidget);
      expect(find.text('لا توجد طلبات تبادل مفتوحة حالياً.'), findsNothing);
    });

    testWidgets('the five Arabic tab labels are all still there',
        (tester) async {
      await _open(tester, _backend());

      for (final label in [
        'تصفح', 'طلباتي', 'العروض الواردة', 'العروض المرسلة', 'اهتماماتي',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('an empty proposal side still says so', (tester) async {
      await _open(tester, _backend());

      await _tab(tester, 'العروض الواردة');
      expect(find.text('لم يصلك أي اقتراح بعد.'), findsOneWidget);

      await _tab(tester, 'العروض المرسلة');
      expect(find.text('لم ترسل أي اقتراح بعد.'), findsOneWidget);
    });
  });
}
