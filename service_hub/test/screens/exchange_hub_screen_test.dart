import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:service_hub/features/exchange/exchange_hub_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _me = {'id': 99, 'email': 'me@b.com', 'role': 'user', 'is_provider': true, 'is_active': true};
const _myId = 99;

/// Every tab asks for page 1 with the screen's page size, so a route that
/// pins down a query has to include that too. The bare paths stay
/// registered as well: a backend that ignores the parameters answers with
/// the whole list, which is the legacy shape the parser also accepts.
const _firstPage = 'page=1&page_size=20';

/// The route the Browse tab actually calls: it asks the backend to leave
/// its own requests out, so a test overriding the browse reply must
/// override this one, not the bare path.
const _browseRoute =
    'GET /exchange-requests?exclude_user_id=$_myId&$_firstPage';

/// What the real endpoint answers to `?exclude_user_id=99`: the same list
/// without that user's own requests. The fake applies the parameter so a
/// screen that forgot to send it falls through to the unfiltered route and
/// fails the test.
List<Map<String, dynamic>> _withoutMine(List<Map<String, dynamic>> all) => [
      for (final r in all)
        if ((r['user'] as Map)['id'] != _myId) r,
    ];

RoutedBackend _backend({
  List<Map<String, dynamic>>? open,
  List<Map<String, dynamic>>? mine,
  List<Map<String, dynamic>>? received,
  List<Map<String, dynamic>>? sent,
  List<Map<String, dynamic>>? interests,
  List<Map<String, dynamic>>? search,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/me': const Reply(_me),
      'GET /exchange-requests': Reply(open ?? []),
      _browseRoute: Reply(_withoutMine(open ?? [])),
      'GET /exchange-requests/me': Reply(mine ?? []),
      'GET /exchange-proposals/me?sent=false&$_firstPage': Reply(received ?? []),
      'GET /exchange-proposals/me?sent=true&$_firstPage': Reply(sent ?? []),
      'GET /exchange-requests/interests': Reply(interests ?? []),
      'GET /exchange-requests/search': Reply(search ?? []),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  await tester.pumpWidget(MaterialApp(
    home: ExchangeHubScreen(
      tokenStore: store,
      exchangeService: ExchangeService(apiClient: api),
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
  ));
  await tester.pumpAndSettle();
}

/// An exchange request as «اهتماماتي» / the search return it: with the
/// offered service's own rating.
Map<String, dynamic> _ranked({
  required int id,
  required String title,
  double? rating,
  int reviews = 0,
  int ownerId = 10,
}) =>
    exchangeRequestNoAvatar(id: id, ownerId: ownerId, offeredTitle: title)
      ..['offered_service_rating'] = rating
      ..['offered_service_review_count'] = reviews
      ..['relevance_score'] = null;

/// Types into the search field of the visible tab and waits out the debounce.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// The `q` sent in the last call to [path] (null when there was none).
String? _lastQuery(RoutedBackend backend, String path) => backend.requests
    .lastWhere((r) => r.url.path.endsWith(path))
    .url
    .queryParameters['q'];

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  // A real-shaped token: the Browse tab reads its own id out of this
  // instead of asking /users/me for it.
  setUp(() => SharedPreferences.setMockInitialValues({
        'access_token': tokenFor(_myId),
      }));

  testWidgets('is titled المقايضة and has all five tabs in order', (tester) async {
    await _open(tester, _backend());

    expect(find.text('المقايضة'), findsOneWidget);
    final tabs = tester.widgetList<Tab>(find.byType(Tab)).map((t) => t.text).toList();
    expect(tabs, ['تصفح', 'طلباتي', 'العروض الواردة', 'العروض المرسلة', 'اهتماماتي']);
  });

  group('browse', () {
    testWidgets('lists other people\'s open requests and hides mine', (tester) async {
      await _open(
        tester,
        _backend(open: [
          exchangeRequestNoAvatar(id: 1, ownerId: 10, offeredTitle: 'Fix pipes'),
          exchangeRequestNoAvatar(id: 2, ownerId: 99, offeredTitle: 'My own offer'), // mine
        ]),
      );

      expect(find.text('Fix pipes'), findsOneWidget);
      // Hidden by the backend now: the fake only drops it on the
      // exclude_user_id route, so seeing it gone proves the screen asked
      // for the filtered list instead of filtering one itself.
      expect(find.text('My own offer'), findsNothing);
      expect(find.text('Ahmad Ali · يريد كهرباء'), findsOneWidget);
      expect(find.text('مفتوح'), findsOneWidget); // internal status 'open'
      expect(find.text('open'), findsNothing);
    });

    testWidgets('it asks the backend to leave my own requests out',
        (tester) async {
      final backend = _backend(open: [
        exchangeRequestNoAvatar(id: 1, ownerId: 10, offeredTitle: 'Fix pipes'),
      ]);
      await _open(tester, backend);

      final asked = backend.requests
          .map((r) => r.url)
          .where((u) => u.path.endsWith('/exchange-requests'))
          .toList();
      expect(asked, hasLength(1));
      expect(asked.single.queryParameters['exclude_user_id'], '$_myId');
    });

    testWidgets('the id comes from the stored token, not from /users/me',
        (tester) async {
      final backend = _backend(open: [
        exchangeRequestNoAvatar(id: 1, ownerId: 10, offeredTitle: 'Fix pipes'),
      ]);
      await _open(tester, backend);

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(backend.callsTo('GET /users/me'), 0,
          reason: 'the exclusion id must not cost a round trip');
    });

    testWidgets('an unreadable token excludes nobody rather than guessing',
        (tester) async {
      SharedPreferences.setMockInitialValues({'access_token': 'not-a-jwt'});
      final backend = _backend(open: [
        exchangeRequestNoAvatar(id: 1, ownerId: 10, offeredTitle: 'Fix pipes'),
        exchangeRequestNoAvatar(id: 2, ownerId: _myId, offeredTitle: 'My own offer'),
      ]);
      await _open(tester, backend);

      // No exclusion is sent, so the backend answers with the full public
      // list - the same thing a visitor sees. Nothing invented, nothing
      // crashed, and the tab still works.
      final asked = backend.requests
          .map((r) => r.url)
          .where((u) => u.path.endsWith('/exchange-requests'))
          .single;
      expect(asked.queryParameters.containsKey('exclude_user_id'), isFalse);
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(backend.callsTo('GET /users/me'), 0);
    });

    testWidgets('empty state', (tester) async {
      await _open(tester, _backend());
      expect(find.text('لا توجد طلبات تبادل مفتوحة حالياً.'), findsOneWidget);
    });

    testWidgets('shows the error when loading fails', (tester) async {
      await _open(
        tester,
        _backend(extra: {_browseRoute: const Reply({'detail': 'boom'}, status: 500)}),
      );
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('a request showing "أخرى" uses the custom wanted label', (tester) async {
      await _open(
        tester,
        _backend(open: [
          exchangeRequestNoAvatar(
            id: 1,
            wantedCategory: categoryJson(id: 9, name: 'أخرى', isOther: true),
            wantedLabel: 'نجار',
          ),
        ]),
      );
      expect(find.text('Ahmad Ali · يريد نجار'), findsOneWidget);
    });

    testWidgets('tapping a request opens its detail and refreshes on return', (tester) async {
      final backend = _backend(open: [exchangeRequestNoAvatar(id: 1)]);
      await _open(tester, backend);

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();
      expect(find.text('DETAIL 1'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /exchange-requests'), 2);
    });

    testWidgets('the + button opens the create screen and refreshes after success',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('DONE'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /exchange-requests'), 2);
    });
  });

  group('my requests', () {
    testWidgets('lists my own requests', (tester) async {
      await _open(
        tester,
        _backend(mine: [exchangeRequestNoAvatar(id: 3, ownerId: 99, offeredTitle: 'My offer', status: 'matched')]),
      );
      await _tab(tester, 'طلباتي');

      expect(find.text('My offer'), findsOneWidget);
      expect(find.text('محجوز'), findsOneWidget); // internal 'matched'
      expect(find.text('matched'), findsNothing);
    });

    testWidgets('empty state', (tester) async {
      await _open(tester, _backend());
      await _tab(tester, 'طلباتي');
      expect(find.text('لم تفتح أي طلب تبادل بعد.'), findsOneWidget);
    });
  });

  group('proposals', () {
    testWidgets('received: shows who offered what', (tester) async {
      await _open(
        tester,
        _backend(received: [exchangeProposalNoAvatar(proposedTitle: 'Painting', proposerName: 'Sara Hassan')]),
      );
      await _tab(tester, 'العروض الواردة');

      expect(find.text('Sara Hassan عرض: Painting'), findsOneWidget);
      expect(find.text('مقابل: Fix pipes'), findsOneWidget);
      expect(find.text('قيد الانتظار'), findsOneWidget); // internal 'pending'
      expect(find.text('pending'), findsNothing);
    });

    testWidgets('sent: uses the first-person wording', (tester) async {
      await _open(tester, _backend(sent: [exchangeProposalNoAvatar(proposedTitle: 'Painting')]));
      await _tab(tester, 'العروض المرسلة');

      expect(find.text('عرضت: Painting'), findsOneWidget);
    });

    testWidgets('empty states', (tester) async {
      await _open(tester, _backend());

      await _tab(tester, 'العروض الواردة');
      expect(find.text('لم يصلك أي اقتراح بعد.'), findsOneWidget);

      await _tab(tester, 'العروض المرسلة');
      expect(find.text('لم ترسل أي اقتراح بعد.'), findsOneWidget);
    });

    testWidgets('tapping a proposal opens the request it belongs to', (tester) async {
      await _open(
        tester,
        _backend(received: [exchangeProposalNoAvatar(request: exchangeRequestNoAvatar(id: 42))]),
      );
      await _tab(tester, 'العروض الواردة');

      await tester.tap(find.textContaining('عرض: Painting'));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL 42'), findsOneWidget);
    });
  });

  group('browse search', () {
    testWidgets('has an Arabic search field', (tester) async {
      await _open(tester, _backend());
      expect(find.widgetWithText(TextField, 'ابحث في طلبات المقايضة..'), findsOneWidget);
    });

    testWidgets('typing searches exchange requests with the smart search', (tester) async {
      final backend = _backend(
        open: [exchangeRequestNoAvatar(id: 1, offeredTitle: 'Fix pipes')],
        search: [
          // /search is sent the token and leaves the caller's own requests
          // out itself, so a realistic reply holds none.
          _ranked(id: 5, title: 'صيانة مكيفات', rating: 4.0),
        ],
      );
      await _open(tester, backend);
      final lookupsBefore = backend.callsTo('GET /users/me');

      await _search(tester, '  تصليح مكيف ');

      expect(backend.callsTo('GET /exchange-requests/search'), 1);
      expect(_lastQuery(backend, '/exchange-requests/search'), 'تصليح مكيف');
      expect(find.text('صيانة مكيفات'), findsOneWidget);
      expect(find.text('Fix pipes'), findsNothing); // replaced by the results
      // Searching no longer costs a round trip just to learn who I am:
      // the server knows from the token.
      expect(backend.callsTo('GET /users/me'), lookupsBefore);
    });

    testWidgets('waits until the user stops typing before searching', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(find.byType(TextField), 'بر');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byType(TextField), 'برمجة');
      await tester.pump(const Duration(milliseconds: 200));
      expect(backend.callsTo('GET /exchange-requests/search'), 0);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /exchange-requests/search'), 1);
      expect(_lastQuery(backend, '/exchange-requests/search'), 'برمجة');
    });

    testWidgets('no results shows an Arabic hint', (tester) async {
      await _open(tester, _backend(open: [exchangeRequestNoAvatar(id: 1)]));
      await _search(tester, 'نجارة');
      expect(find.text('لم نجد طلبات مطابقة لبحثك، جرّب كلمات أخرى.'), findsOneWidget);
    });

    testWidgets('clearing the search brings back every open request', (tester) async {
      final backend = _backend(open: [exchangeRequestNoAvatar(id: 1, offeredTitle: 'Fix pipes')]);
      await _open(tester, backend);

      await _search(tester, 'نجارة');
      expect(find.text('Fix pipes'), findsNothing);
      await _search(tester, '');

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests'), 2);
    });

    testWidgets('a search error is shown with a working Retry', (tester) async {
      final backend = _backend(extra: {
        'GET /exchange-requests/search': const Reply({'detail': 'تعذّر البحث'}, status: 500),
      });
      await _open(tester, backend);

      await _search(tester, 'برمجة');
      expect(find.text('تعذّر البحث'), findsOneWidget);

      backend.routes['GET /exchange-requests/search'] =
          Reply([_ranked(id: 5, title: 'برمجة مواقع')]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('برمجة مواقع'), findsOneWidget);
      expect(_lastQuery(backend, '/exchange-requests/search'), 'برمجة');
    });

    testWidgets('shows a spinner while searching', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      backend.gate = Completer<void>();
      await tester.enterText(find.byType(TextField), 'برمجة');
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('my interests (اهتماماتي)', () {
    testWidgets('lists the requests the backend matched to my services', (tester) async {
      final backend = _backend(interests: [
        _ranked(id: 11, title: 'Electrical work', rating: 4.5, reviews: 8),
      ]);
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');

      expect(backend.callsTo('GET /exchange-requests/interests'), 1);
      expect(_lastQuery(backend, '/exchange-requests/interests'), isNull);
      expect(find.text('Electrical work'), findsOneWidget);
      expect(find.text('Ahmad Ali · يريد كهرباء'), findsOneWidget);
      expect(find.text('4.5 (8 تقييم)'), findsOneWidget);
    });

    testWidgets('keeps the backend order: highest offered-service rating first, unrated last',
        (tester) async {
      await _open(tester, _backend(interests: [
        _ranked(id: 1, title: 'Request A', rating: 4.9, reviews: 3),
        _ranked(id: 2, title: 'Request B', rating: 4.5, reviews: 10),
        _ranked(id: 3, title: 'Request C', rating: 4.2, reviews: 7),
        _ranked(id: 4, title: 'Request D'),
      ]));
      await _tab(tester, 'اهتماماتي');

      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Request A'), lessThan(top('Request B')));
      expect(top('Request B'), lessThan(top('Request C')));
      expect(top('Request C'), lessThan(top('Request D')));
      expect(find.text('لا توجد تقييمات للخدمة بعد'), findsOneWidget); // D
    });

    testWidgets('empty state explains where interests come from', (tester) async {
      await _open(tester, _backend());
      await _tab(tester, 'اهتماماتي');

      expect(
        find.text('لا توجد حالياً طلبات تبحث عن خدمة تقدّمها.\n'
            'تظهر هنا طلبات من يبحثون عن الخدمات المنشورة في حسابك.'),
        findsOneWidget,
      );
    });

    testWidgets('a loading error is shown', (tester) async {
      await _open(tester, _backend(extra: {
        'GET /exchange-requests/interests': const Reply({'detail': 'خطأ في الخادم'}, status: 500),
      }));
      await _tab(tester, 'اهتماماتي');
      expect(find.text('خطأ في الخادم'), findsOneWidget);
      expect(find.text('إعادة المحاولة'), findsOneWidget);
    });

    testWidgets('searching stays inside my interests (same endpoint, with q)', (tester) async {
      final backend = _backend(interests: [
        _ranked(id: 1, title: 'Request A', rating: 4.9),
        _ranked(id: 2, title: 'Request B', rating: 4.5),
      ]);
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');
      expect(find.widgetWithText(TextField, 'ابحث ضمن اهتماماتي..'), findsOneWidget);

      backend.routes['GET /exchange-requests/interests'] =
          Reply([_ranked(id: 2, title: 'Request B', rating: 4.5)]);
      await _search(tester, 'كهربا');

      expect(_lastQuery(backend, '/exchange-requests/interests'), 'كهربا');
      expect(backend.callsTo('GET /exchange-requests/search'), 0); // never the browse search
      expect(find.text('Request B'), findsOneWidget);
      expect(find.text('Request A'), findsNothing);
    });

    testWidgets('a search with no result inside my interests says so', (tester) async {
      final backend = _backend(interests: [_ranked(id: 1, title: 'Request A')]);
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');

      backend.routes['GET /exchange-requests/interests'] = const Reply([]);
      await _search(tester, 'نجارة');

      expect(find.text('لم نجد طلبات مطابقة لبحثك، جرّب كلمات أخرى.'), findsOneWidget);
    });

    testWidgets('tapping an interest opens the request and refreshes on return',
        (tester) async {
      final backend = _backend(interests: [_ranked(id: 11, title: 'Electrical work')]);
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');

      await tester.tap(find.text('Electrical work'));
      await tester.pumpAndSettle();
      expect(find.text('DETAIL 11'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /exchange-requests/interests'), 2);
    });

    testWidgets('shows a spinner while loading', (tester) async {
      final backend = _backend(interests: [_ranked(id: 11, title: 'Electrical work')]);
      await _open(tester, backend);

      backend.gate = Completer<void>();
      await tester.tap(find.widgetWithText(Tab, 'اهتماماتي'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Electrical work'), findsOneWidget);
    });
  });

  testWidgets('my requests has no search field', (tester) async {
    await _open(tester, _backend());
    await _tab(tester, 'طلباتي');
    expect(find.widgetWithText(TextField, 'ابحث في طلبات المقايضة..'), findsNothing);
    expect(find.widgetWithText(TextField, 'ابحث ضمن اهتماماتي..'), findsNothing);
  });

  group('Arabic status labels', () {
    final englishStatus = find.textContaining(RegExp(r'^(open|matched|closed|pending|accepted|rejected|withdrawn|active|inactive|suspended)$'));

    testWidgets('sent proposals: every proposal status is shown in Arabic', (tester) async {
      await _open(tester, _backend(sent: [
        exchangeProposalNoAvatar(id: 1, status: 'pending', proposedTitle: 'A'),
        exchangeProposalNoAvatar(id: 2, status: 'accepted', proposedTitle: 'B'),
        exchangeProposalNoAvatar(id: 3, status: 'rejected', proposedTitle: 'C'),
        exchangeProposalNoAvatar(id: 4, status: 'withdrawn', proposedTitle: 'D'),
      ]));
      await _tab(tester, 'العروض المرسلة');

      for (final label in ['قيد الانتظار', 'مقبول', 'مرفوض', 'مسحوب']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(englishStatus, findsNothing);
    });

    testWidgets('my requests: every request status is shown in Arabic', (tester) async {
      await _open(tester, _backend(mine: [
        exchangeRequestNoAvatar(id: 1, ownerId: 99, offeredTitle: 'A', status: 'open'),
        exchangeRequestNoAvatar(id: 2, ownerId: 99, offeredTitle: 'B', status: 'matched'),
        exchangeRequestNoAvatar(id: 3, ownerId: 99, offeredTitle: 'C', status: 'closed'),
      ]));
      await _tab(tester, 'طلباتي');

      for (final label in ['مفتوح', 'محجوز', 'مغلق']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(englishStatus, findsNothing);
    });

    testWidgets('an unknown status does not crash and is not shown in English', (tester) async {
      await _open(tester, _backend(
        mine: [exchangeRequestNoAvatar(id: 1, ownerId: 99, offeredTitle: 'A', status: 'archived')],
        received: [exchangeProposalNoAvatar(id: 2, status: 'expired', proposedTitle: 'B')],
      ));

      await _tab(tester, 'طلباتي');
      expect(find.text('A'), findsOneWidget);
      expect(find.text('غير معروف'), findsOneWidget);
      expect(find.text('archived'), findsNothing);

      await _tab(tester, 'العروض الواردة');
      expect(find.text('غير معروف'), findsOneWidget);
      expect(find.text('expired'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unexpected response shows an Arabic message, not a Dart error',
        (tester) async {
      // A map where a list is expected: parsing fails with a TypeError.
      await _open(tester, _backend(extra: {_browseRoute: const Reply({'oops': 1})}));

      expect(find.text('حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.'), findsOneWidget);
      expect(find.textContaining('subtype'), findsNothing);
      expect(find.textContaining('TypeError'), findsNothing);
    });
  });


  // =============== the lists after a proposal is answered (stale UI)
  //
  // Accepting a proposal moves the request to «محجوز». Each tab shows
  // that same request from its own angle, so the chip in every one of them is
  // out of date the moment it happens. The list the user came from reloads
  // when the detail screen is popped, and the tabs they are not looking at
  // are not kept by the TabBarView at all, so each one is built — and
  // fetched — again on the way back to it.

  group('a request matched from inside the detail screen', () {
    /// Everything the backend serves about request 1 once a proposal has
    /// been accepted.
    void nowMatched(RoutedBackend backend) {
      final matched = exchangeRequestNoAvatar(id: 1, status: 'matched');
      backend.routes['GET /exchange-requests'] = Reply([matched]);
      backend.routes[_browseRoute] = Reply(_withoutMine([matched]));
      backend.routes['GET /exchange-requests/me'] = Reply([matched]);
      backend.routes['GET /exchange-requests/interests'] = Reply([
        _ranked(id: 1, title: 'Fix pipes')..['status'] = 'matched',
      ]);
    }

    /// Opens request 1 from the tab on screen, where the user answers a
    /// proposal: from then on the backend reports the request as matched.
    Future<void> answerAProposal(
      WidgetTester tester,
      RoutedBackend backend,
    ) async {
      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();
      expect(find.text('DETAIL 1'), findsOneWidget);
      nowMatched(backend);
    }

    testWidgets('the browsing list shows the new status on the way back',
        (tester) async {
      final backend = _backend(open: [exchangeRequestNoAvatar(id: 1)]);
      await _open(tester, backend);
      expect(find.text('مفتوح'), findsOneWidget);

      await answerAProposal(tester, backend);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('my own requests show the new status on the way back',
        (tester) async {
      final backend = _backend(mine: [exchangeRequestNoAvatar(id: 1, ownerId: _myId)]);
      await _open(tester, backend);
      await _tab(tester, 'طلباتي');
      expect(find.text('مفتوح'), findsOneWidget);

      await answerAProposal(tester, backend);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('اهتماماتي shows the new status on the way back', (tester) async {
      final backend = _backend(interests: [_ranked(id: 1, title: 'Fix pipes')]);
      await _open(tester, backend);
      await _tab(tester, 'اهتماماتي');
      expect(find.text('مفتوح'), findsOneWidget);

      await answerAProposal(tester, backend);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('a tab the user left is not found on «مفتوح» when they return',
        (tester) async {
      final backend = _backend(
        open: [exchangeRequestNoAvatar(id: 1)],
        interests: [_ranked(id: 1, title: 'Fix pipes')],
      );
      await _open(tester, backend);              // تصفح, on screen first
      await _tab(tester, 'اهتماماتي');
      await answerAProposal(tester, backend);    // answered from اهتماماتي
      await tester.pageBack();
      await tester.pumpAndSettle();

      await _tab(tester, 'تصفح');
      expect(find.text('مفتوح'), findsNothing);
      expect(find.text('محجوز'), findsWidgets);
    });

    testWidgets('a tab is fetched again when the user comes back to it, '
        'which is what keeps it from going stale', (tester) async {
      final backend = _backend(
        open: [exchangeRequestNoAvatar(id: 1)],
        interests: [_ranked(id: 1, title: 'Fix pipes')],
      );
      await _open(tester, backend);                 // تصفح asks once
      expect(backend.callsTo('GET /exchange-requests'), 1);

      await _tab(tester, 'اهتماماتي');
      await answerAProposal(tester, backend);
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Nothing refreshed تصفح behind the user's back: TabBarView does not
      // keep the tab they left, so there was no list there to refresh.
      expect(backend.callsTo('GET /exchange-requests'), 1);

      // It is built from scratch when they return, which is why it cannot
      // show them the old status. Were the tab ever kept alive instead,
      // this count would stay at 1 and the test above ('a tab the user
      // left...') would find «مفتوح» still on screen.
      await _tab(tester, 'تصفح');
      expect(backend.callsTo('GET /exchange-requests'), 2);
    });

    testWidgets('the list the user came from is asked once, on the way back',
        (tester) async {
      final backend = _backend(open: [exchangeRequestNoAvatar(id: 1)]);
      await _open(tester, backend);
      expect(backend.callsTo('GET /exchange-requests'), 1);

      await answerAProposal(tester, backend);
      expect(backend.callsTo('GET /exchange-requests'), 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // One reload for the one trip back, so the new status costs a single
      // request and no more.
      expect(backend.callsTo('GET /exchange-requests'), 2);
    });
  });


  // ================= a settled two-way exchange, from both sides' phones
  //
  // Accepting a proposal settles TWO requests: the one that received it and
  // the sender's own request that it completes. Both owners must see their
  // own request as «محجوز» under «طلباتي», and neither request may still be
  // on offer under «تصفح» or «اهتماماتي». The screen takes all of that from
  // the backend, so these say what each tab does with the answers it gets
  // after the match.

  group('after a two-way exchange is settled', () {
    Map<String, dynamic> settled({int id = 1, required int ownerId}) =>
        exchangeRequestNoAvatar(id: id, ownerId: ownerId, status: 'matched');

    testWidgets('the owner who accepted sees «محجوز» under طلباتي',
        (tester) async {
      await _open(tester, _backend(mine: [settled(ownerId: _myId)]));
      await _tab(tester, 'طلباتي');

      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
      expect(find.text('مغلق'), findsNothing);   // matched is not withdrawn
    });

    testWidgets('the sender sees «محجوز» on their own request too',
        (tester) async {
      // The other side's phone: their own request, settled by the same
      // acceptance, is the one listed here.
      await _open(tester, _backend(mine: [settled(id: 2, ownerId: _myId)]));
      await _tab(tester, 'طلباتي');

      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('neither request is still offered under تصفح', (tester) async {
      // Both are matched, so the browse endpoint has nothing left to send.
      final backend = _backend(open: []);
      await _open(tester, backend);

      expect(find.text('لا توجد طلبات تبادل مفتوحة حالياً.'), findsOneWidget);
      expect(find.text('محجوز'), findsNothing);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('neither request is still offered under اهتماماتي',
        (tester) async {
      await _open(tester, _backend(interests: []));
      await _tab(tester, 'اهتماماتي');

      expect(
        find.textContaining('لا توجد حالياً طلبات تبحث عن خدمة تقدّمها.'),
        findsOneWidget,
      );
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('a tab left open before the match is not stale on the way back',
        (tester) async {
      final backend = _backend(
        open: [exchangeRequestNoAvatar(id: 1)],
        interests: [_ranked(id: 1, title: 'Fix pipes')],
      );
      await _open(tester, backend);                  // تصفح, before the match
      expect(find.text('مفتوح'), findsOneWidget);

      await _tab(tester, 'اهتماماتي');
      // The exchange is settled elsewhere while the user is on another tab.
      backend.routes[_browseRoute] = const Reply([]);
      backend.routes['GET /exchange-requests'] = const Reply([]);
      backend.routes['GET /exchange-requests/interests'] = const Reply([]);

      await _tab(tester, 'تصفح');

      expect(find.text('مفتوح'), findsNothing);
      expect(find.text('لا توجد طلبات تبادل مفتوحة حالياً.'), findsOneWidget);
    });

    testWidgets('the other side keeps its own open requests', (tester) async {
      // Only the two requests of this exchange close; everyone else's stay.
      await _open(
        tester,
        _backend(open: [exchangeRequestNoAvatar(id: 9, offeredTitle: 'Painting')]),
      );

      expect(find.text('Painting'), findsOneWidget);
      expect(find.text('مفتوح'), findsOneWidget);
    });
  });
}
