import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/exchange/data/exchange_models.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:service_hub/features/exchange/exchange_request_detail_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/core/utils/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _owner = 10; // owner of request 7
const _stranger = 99;

Map<String, dynamic> _me(int id) =>
    {'id': id, 'email': 'u$id@b.com', 'role': 'user', 'is_provider': true, 'is_active': true};

RoutedBackend _backend({
  int me = _owner,
  List<Map<String, dynamic>> matches = const [],
  List<Map<String, dynamic>> received = const [],
  List<Map<String, dynamic>> sent = const [],
  List<Map<String, dynamic>>? myServices,
  Map<String, Reply> extra = const {},
}) {
  // Seeds the access token for [me] as well: the screen reads its own id
  // from the token now, not from /users/me, so the two have to agree for
  // the owner check to mean anything.
  SharedPreferences.setMockInitialValues({'access_token': tokenFor(me)});
  return RoutedBackend({
      'GET /users/me': Reply(_me(me)),
      'GET /exchange-requests/7/matches': Reply(matches),
      // The screen now asks for one request's proposals, and the backend
      // decides what that holds: everything on it for its owner, only my
      // own for anyone else. `received` and `sent` keep their meaning per
      // test (no test passes both) and feed that single route.
      'GET /exchange-requests/7/proposals': Reply([...received, ...sent]),
      'GET /services/provider/$me': Reply(myServices ?? [serviceListItemJson(id: 55)..['title'] = 'Painting']),
      ...extra,
  });
}

Future<void> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  Map<String, dynamic>? request,
}) async {
  useTallScreen(tester);
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  final model = ExchangeRequestModel.fromJson(request ?? exchangeRequestNoAvatar());

  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ExchangeRequestDetailScreen(
                  request: model,
                  tokenStore: store,
                  exchangeService: ExchangeService(apiClient: api),
                  catalogService: CatalogService(apiClient: api),
                  bookingBuilder: (sid, title, pid) =>
                      Scaffold(body: Text('BOOKING $sid $title $pid')),
                  profileBuilder: (id) => Scaffold(body: Text('PROFILE $id')),
                ),
              ),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('request summary', () {
    testWidgets('shows owner, offer, wish and status', (tester) async {
      await _open(tester, _backend());

      expect(find.text('تفاصيل طلب التبادل'), findsOneWidget);
      expect(find.text('Ahmad Ali'), findsOneWidget);
      expect(find.text('يعرض: Fix pipes (سباكة)'), findsOneWidget);
      expect(find.text('يريد: كهرباء'), findsOneWidget);
      expect(find.text('مفتوح'), findsOneWidget); // internal status 'open'
      expect(find.text('open'), findsNothing);
    });

    testWidgets('a failure while loading shows the error', (tester) async {
      // Was a 401 on /users/me, which this screen no longer calls: a
      // refused session now surfaces on the request it does make.
      await _open(
        tester,
        _backend(extra: {
          'GET /exchange-requests/7/proposals':
              const Reply({'detail': 'Invalid or expired token'}, status: 401),
        }),
      );
      expect(find.text('Invalid or expired token'), findsOneWidget);
    });

    testWidgets('an unreadable token shows an error, never the owner view',
        (tester) async {
      // Nothing is guessed and nobody is assumed to be the owner: the
      // screen takes the visitor path, whose request then fails.
      final backend = _backend(extra: {
        'GET /exchange-requests/7/proposals':
            const Reply({'detail': 'Invalid or expired token'}, status: 401),
      });
      // After _backend seeded a valid token, make it unreadable.
      SharedPreferences.setMockInitialValues({'access_token': 'not-a-jwt'});
      await _open(tester, backend);

      expect(find.text('Invalid or expired token'), findsOneWidget);
      expect(find.text('الاقتراحات المستلمة'), findsNothing);
      expect(find.text('التطابقات المباشرة'), findsNothing);
      expect(backend.callsTo('GET /users/me'), 0);
    });

    testWidgets('a spinner shows while the proposals are still loading',
        (tester) async {
      final backend = _backend()..gate = Completer<void>();
      useTallScreen(tester);
      final store = TokenStore();
      final api = apiFor(backend, tokenStore: store);
      await tester.pumpWidget(MaterialApp(
        home: ExchangeRequestDetailScreen(
          request: ExchangeRequestModel.fromJson(exchangeRequestNoAvatar()),
          tokenStore: store,
          exchangeService: ExchangeService(apiClient: api),
          catalogService: CatalogService(apiClient: api),
        ),
      ));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a failure from the proposals endpoint shows the error',
        (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /exchange-requests/7/proposals':
              const Reply({'detail': 'تعذر تحميل الاقتراحات'}, status: 500),
        }),
      );

      expect(find.text('تعذر تحميل الاقتراحات'), findsOneWidget);
    });

    testWidgets('tapping the owner opens their profile', (tester) async {
      await _open(tester, _backend(me: _stranger));

      await tester.tap(find.text('Ahmad Ali'));
      await tester.pumpAndSettle();

      expect(find.text('PROFILE 10'), findsOneWidget);
    });
  });

  group('as the owner', () {
    testWidgets('empty matches and proposals', (tester) async {
      await _open(tester, _backend());

      expect(find.text('التطابقات المباشرة'), findsOneWidget);
      expect(find.text('لا توجد تطابقات مباشرة بعد.'), findsOneWidget);
      expect(find.text('الاقتراحات المستلمة'), findsOneWidget);
      expect(find.text('لم يصل أي اقتراح بعد.'), findsOneWidget);
    });

    testWidgets('lists direct matches', (tester) async {
      final other = exchangeRequestNoAvatar(
        id: 8, ownerId: 30, ownerName: 'Omar Khaled', offeredTitle: 'Plumbing help',
      );
      await _open(tester, _backend(matches: [
        {'match_type': 'direct', 'other_request': other},
      ]));

      expect(find.text('Plumbing help'), findsOneWidget);
      expect(find.text('Omar Khaled · يريد كهرباء'), findsOneWidget);
    });

    testWidgets('shows every direct match the backend returns, in order', (tester) async {
      Map<String, dynamic> match(int id, String owner, String title, {String? wantedLabel}) => {
            'match_type': 'direct',
            'other_request': exchangeRequestNoAvatar(
              id: id,
              ownerId: id * 10,
              ownerName: owner,
              offeredTitle: title,
              wantedCategory: wantedLabel == null
                  ? null
                  : categoryJson(id: 9, name: 'أخرى', isOther: true),
              wantedLabel: wantedLabel,
            ),
          };
      final backend = _backend(matches: [
        match(3, 'Omar Khaled', 'Wiring A'),
        match(5, 'Sara Hassan', 'Wiring B'),
        match(7, 'Lina Yousef', 'Wiring C', wantedLabel: 'منسق حفلات'),
      ]);
      await _open(tester, backend);

      expect(backend.callsTo('GET /exchange-requests/7/matches'), 1);
      expect(find.byIcon(Icons.compare_arrows), findsNWidgets(3));
      double top(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(top('Wiring A'), lessThan(top('Wiring B')));
      expect(top('Wiring B'), lessThan(top('Wiring C')));
      expect(find.text('Lina Yousef · يريد منسق حفلات'), findsOneWidget);
      expect(find.text('لا توجد تطابقات مباشرة بعد.'), findsNothing);
    });

    testWidgets('only proposals for THIS request are listed', (tester) async {
      // The request id is now part of the URL, so another request's
      // proposals are never fetched in the first place. Request 99's
      // proposal sits behind its own route, which this screen must not ask
      // for, and the all-proposals route must not be touched either.
      final backend = _backend(
        received: [
          exchangeProposalNoAvatar(id: 3, proposedTitle: 'Painting', message: 'deal?'),
        ],
        extra: {
          'GET /exchange-requests/99/proposals': Reply([
            exchangeProposalNoAvatar(
              id: 4,
              proposedTitle: 'Other thing',
              request: exchangeRequestNoAvatar(id: 99),
            ),
          ]),
          'GET /exchange-proposals/me?sent=false': Reply([
            exchangeProposalNoAvatar(
              id: 4,
              proposedTitle: 'Other thing',
              request: exchangeRequestNoAvatar(id: 99),
            ),
          ]),
        },
      );
      await _open(tester, backend);

      expect(find.textContaining('Painting'), findsOneWidget);
      expect(find.text('deal?'), findsOneWidget);
      expect(find.textContaining('Other thing'), findsNothing);
      expect(backend.callsTo('GET /exchange-requests/7/proposals'), 1);
      expect(backend.callsTo('GET /exchange-requests/99/proposals'), 0);
      expect(backend.callsTo('GET /exchange-proposals/me'), 0,
          reason: 'the screen must no longer fetch every proposal');
    });

    testWidgets('it asks for this request id, not another', (tester) async {
      final backend = _backend(received: [exchangeProposalNoAvatar(id: 3)]);
      await _open(tester, backend);

      final asked = backend.requests
          .map((r) => r.url.path)
          .where((p) => p.contains('/proposals'))
          .toList();
      expect(asked, ['/api/v1/exchange-requests/7/proposals']);
    });

    testWidgets('a pending proposal can be accepted, then the screen reloads', (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {'POST /exchange-proposals/3/accept': Reply(exchangeProposalNoAvatar(id: 3, status: 'accepted'))},
      );
      await _open(tester, backend);

      await tester.tap(find.text('قبول'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /exchange-proposals/3/accept'), 1);
      // Was 2 (the first load and the reload after accepting). Both read
      // /users/me for my id alone, which now comes from the token.
      expect(backend.callsTo('GET /users/me'), 0);
      // The reload still happened — the proposals were fetched again.
      expect(backend.callsTo('GET /exchange-requests/7/proposals'), 2);
    });

    testWidgets('a pending proposal can be rejected', (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {'POST /exchange-proposals/3/reject': Reply(exchangeProposalNoAvatar(id: 3, status: 'rejected'))},
      );
      await _open(tester, backend);

      await tester.tap(find.text('رفض'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /exchange-proposals/3/reject'), 1);
    });

    testWidgets('a refused action shows the backend message', (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {
          'POST /exchange-proposals/3/accept': const Reply(
            {'detail': 'This proposal has already been responded to'},
            status: 422,
          ),
        },
      );
      await _open(tester, backend);

      await tester.tap(find.text('قبول'));
      await pumpFrames(tester);

      expect(find.text('This proposal has already been responded to'), findsOneWidget);
    });

    testWidgets('no accept/reject buttons once the proposal is answered or the request is closed',
        (tester) async {
      await _open(tester, _backend(received: [exchangeProposalNoAvatar(id: 3, status: 'rejected')]));
      expect(find.text('قبول'), findsNothing);
    });

    testWidgets('no accept/reject buttons when the request is no longer open', (tester) async {
      await _open(
        tester,
        _backend(received: [exchangeProposalNoAvatar(id: 3)]),
        request: exchangeRequestNoAvatar(status: 'matched'),
      );
      expect(find.text('قبول'), findsNothing);
    });

    testWidgets('an accepted proposal offers to book with the proposer', (tester) async {
      await _open(tester, _backend(received: [
        exchangeProposalNoAvatar(id: 3, status: 'accepted', proposedServiceId: 55, proposerId: 20),
      ]));

      await tester.tap(find.text('احجز موعداً مع Sara Hassan'));
      await tester.pumpAndSettle();

      expect(find.text('BOOKING 55 Painting 20'), findsOneWidget);
    });

    testWidgets('tapping a proposer opens their profile', (tester) async {
      await _open(tester, _backend(received: [exchangeProposalNoAvatar(id: 3, proposerId: 20)]));

      await tester.tap(find.text('Sara Hassan'));
      await tester.pumpAndSettle();

      expect(find.text('PROFILE 20'), findsOneWidget);
    });

    group('withdrawing the request', () {
      testWidgets('the close button is only shown for an open request', (tester) async {
        await _open(tester, _backend());
        expect(find.byTooltip('سحب الطلب'), findsOneWidget);
      });

      testWidgets('hidden once the request is not open', (tester) async {
        await _open(tester, _backend(), request: exchangeRequestNoAvatar(status: 'closed'));
        expect(find.byTooltip('سحب الطلب'), findsNothing);
      });

      testWidgets('asks for confirmation; "back" keeps it', (tester) async {
        final backend = _backend();
        await _open(tester, backend);

        await tester.tap(find.byTooltip('سحب الطلب'));
        await tester.pumpAndSettle();
        expect(find.text('سحب طلب التبادل؟'), findsOneWidget);

        await tester.tap(find.widgetWithText(TextButton, 'رجوع'));
        await tester.pumpAndSettle();

        expect(backend.callsTo('DELETE /exchange-requests/7'), 0);
        expect(find.byType(ExchangeRequestDetailScreen), findsOneWidget);
      });

      testWidgets('confirming closes the request and leaves the screen', (tester) async {
        final backend = _backend(extra: {'DELETE /exchange-requests/7': const Reply(null, status: 204)});
        await _open(tester, backend);

        await tester.tap(find.byTooltip('سحب الطلب'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'سحب الطلب'));
        await tester.pumpAndSettle();

        expect(backend.callsTo('DELETE /exchange-requests/7'), 1);
        expect(find.byType(ExchangeRequestDetailScreen), findsNothing);
      });
    });
  });

  group('as another user', () {
    testWidgets('no close button and no owner sections', (tester) async {
      await _open(tester, _backend(me: _stranger));

      expect(find.byTooltip('سحب الطلب'), findsNothing);
      expect(find.text('التطابقات المباشرة'), findsNothing);
    });

    testWidgets('can send a proposal when none exists yet', (tester) async {
      await _open(tester, _backend(me: _stranger));
      expect(find.text('أرسل اقتراح'), findsOneWidget);
    });

    testWidgets('a pending proposal of mine is acknowledged', (tester) async {
      await _open(tester, _backend(me: _stranger, sent: [exchangeProposalNoAvatar(proposerId: _stranger)]));

      expect(find.text('اقتراحك بانتظار موافقة صاحب الطلب.'), findsOneWidget);
      expect(find.text('أرسل اقتراح'), findsNothing);
    });

    testWidgets('a rejected proposal is reported', (tester) async {
      await _open(
        tester,
        _backend(me: _stranger, sent: [exchangeProposalNoAvatar(status: 'rejected', proposerId: _stranger)]),
      );
      expect(find.text('تم رفض اقتراحك على هذا الطلب.'), findsOneWidget);
    });

    testWidgets('an accepted proposal shows a banner and the booking button', (tester) async {
      await _open(
        tester,
        _backend(me: _stranger, sent: [exchangeProposalNoAvatar(status: 'accepted', proposerId: _stranger)]),
      );

      expect(find.text('تم قبول اقتراحك! احجز موعدك مع الطرف الآخر.'), findsOneWidget);

      await tester.tap(find.text('احجز موعداً مع Ahmad Ali'));
      await tester.pumpAndSettle();
      expect(find.text('BOOKING 100 Fix pipes 10'), findsOneWidget);
    });

    testWidgets('a request that is not open cannot receive proposals', (tester) async {
      await _open(tester, _backend(me: _stranger), request: exchangeRequestNoAvatar(status: 'closed'));
      expect(find.text('هذا الطلب غير مفتوح حالياً.'), findsOneWidget);
      expect(find.text('أرسل اقتراح'), findsNothing);
    });

    testWidgets('a matched request says so and takes no more proposals', (tester) async {
      // What the backend leaves behind once the owner accepts someone:
      // ExchangeRequestStatus.MATCHED.
      await _open(tester, _backend(me: _stranger), request: exchangeRequestNoAvatar(status: 'matched'));

      expect(find.text('محجوز'), findsOneWidget);   // the status chip
      expect(find.text('مفتوح'), findsNothing);
      expect(find.text('هذا الطلب غير مفتوح حالياً.'), findsOneWidget);
      expect(find.text('أرسل اقتراح'), findsNothing);
    });

    testWidgets('proposals on other requests do not count', (tester) async {
      // My proposal is on request 99, so request 7's endpoint has nothing
      // of mine — the backend decides that now, and the screen must treat
      // the empty answer as "you have not proposed here yet".
      final backend = _backend(me: _stranger, extra: {
        'GET /exchange-requests/99/proposals': Reply([
          exchangeProposalNoAvatar(
            request: exchangeRequestNoAvatar(id: 99), proposerId: _stranger,
          ),
        ]),
      });
      await _open(tester, backend);

      expect(find.text('أرسل اقتراح'), findsOneWidget);
      expect(backend.callsTo('GET /exchange-requests/99/proposals'), 0);
      expect(backend.callsTo('GET /exchange-proposals/me'), 0);
    });
  });

  group('sending a proposal', () {
    Future<void> openSheet(WidgetTester tester, RoutedBackend backend) async {
      await _open(tester, backend);
      await tester.tap(find.text('أرسل اقتراح'));
      await tester.pumpAndSettle();
    }

    testWidgets('the sheet lists my services without asking /users/me',
        (tester) async {
      // The sheet used to fetch the whole profile to learn which
      // provider's services to offer. A revert shows up as a /users/me
      // request; a wrong id as the wrong provider route.
      final backend = _backend(me: _stranger);
      await openSheet(tester, backend);

      expect(backend.callsTo('GET /users/me'), 0);
      expect(backend.callsTo('GET /services/provider/$_stranger'), 1);
      // The services loaded: the picker is there rather than the error or
      // the "publish a service first" message.
      expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
      expect(find.text(genericErrorText), findsNothing);
    });

    testWidgets('an unreadable token shows the sheet error, not an empty list',
        (tester) async {
      final backend = _backend(me: _stranger);
      // _backend seeded a valid token; make it unreadable.
      SharedPreferences.setMockInitialValues({'access_token': 'not-a-jwt'});
      await openSheet(tester, backend);

      expect(find.text(genericErrorText), findsOneWidget);
      expect(backend.callsTo('GET /users/me'), 0);
      expect(backend.callsTo('GET /services/provider/$_stranger'), 0);
    });

    testWidgets('picking a service and a message sends them and closes both screens',
        (tester) async {
      final backend = _backend(me: _stranger, extra: {
        'POST /exchange-requests/7/proposals': Reply(exchangeProposalNoAvatar(), status: 201),
      });
      await openSheet(tester, backend);

      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Painting').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  deal?  ');
      await tester.tap(find.text('إرسال'));
      await pumpFrames(tester);

      expect(jsonDecode(backend.requests.last.body), {'proposed_service_id': 55, 'message': 'deal?'});
      expect(find.text('تم إرسال الاقتراح!'), findsOneWidget);
      expect(find.byType(ExchangeRequestDetailScreen), findsNothing);
    });

    testWidgets('a service must be chosen', (tester) async {
      final backend = _backend(me: _stranger);
      await openSheet(tester, backend);

      await tester.tap(find.text('إرسال'));
      await pumpFrames(tester);

      expect(find.text('اختر إحدى خدماتك التي تريد عرضها.'), findsOneWidget);
      expect(backend.callsTo('POST /exchange-requests/7/proposals'), 0);
    });

    testWidgets('a user without services is told to publish one', (tester) async {
      await openSheet(tester, _backend(me: _stranger, myServices: []));
      expect(find.text('يجب أن تملك خدمة منشورة قبل إرسال اقتراح.'), findsOneWidget);
    });

    testWidgets('a backend refusal is shown and the sheet stays open', (tester) async {
      final backend = _backend(me: _stranger, extra: {
        'POST /exchange-requests/7/proposals': const Reply(
          {'detail': 'This exchange request is no longer open'},
          status: 422,
        ),
      });
      await openSheet(tester, backend);

      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Painting').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('إرسال'));
      await pumpFrames(tester);

      expect(find.text('This exchange request is no longer open'), findsOneWidget);
      expect(find.text('إرسال'), findsOneWidget); // sheet still there
    });
  });

  group('Arabic status labels', () {
    testWidgets('the request and its proposals show Arabic statuses, the workflow is unchanged',
        (tester) async {
      final backend = _backend(received: [
        exchangeProposalNoAvatar(id: 3, status: 'pending', proposedTitle: 'Painting'),
        exchangeProposalNoAvatar(id: 4, status: 'accepted', proposedTitle: 'Wiring'),
        exchangeProposalNoAvatar(id: 5, status: 'rejected', proposedTitle: 'Tiling'),
      ]);
      await _open(tester, backend);

      expect(find.text('مفتوح'), findsOneWidget);      // the request
      expect(find.text('قيد الانتظار'), findsOneWidget);
      expect(find.text('مقبول'), findsOneWidget);
      expect(find.text('مرفوض'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^(open|matched|closed|pending|accepted|rejected|withdrawn|active|inactive|suspended)$')), findsNothing);

      // Only the PENDING proposal (decided by its internal status) can be answered.
      expect(find.text('قبول'), findsOneWidget);
      expect(find.text('رفض'), findsOneWidget);
    });

    testWidgets('a closed request reads «مغلق»', (tester) async {
      await _open(tester, _backend(me: _stranger),
          request: exchangeRequestNoAvatar(status: 'closed'));
      expect(find.text('مغلق'), findsOneWidget);
      expect(find.text('closed'), findsNothing);
    });
  });


  // =============== the status shown after answering a proposal (stale UI)
  //
  // The screen is handed the request by whichever list the user tapped, and
  // used to keep that copy for its whole life: answering a proposal reloaded
  // the proposals but never the request, so the badge stayed on «مفتوح»
  // until the user left and came back. The answer from the backend carries
  // the request as it now stands, so there is nothing to re-fetch.

  group('the status after answering a proposal', () {
    Map<String, dynamic> accepted({String requestStatus = 'matched'}) =>
        exchangeProposalNoAvatar(
          id: 3,
          status: 'accepted',
          request: exchangeRequestNoAvatar(status: requestStatus),
        );

    testWidgets('an open request starts out as «مفتوح»', (tester) async {
      await _open(tester, _backend(received: [exchangeProposalNoAvatar(id: 3)]));

      expect(find.text('مفتوح'), findsOneWidget);
      expect(find.text('محجوز'), findsNothing);
      expect(find.text('قبول'), findsOneWidget);
    });

    testWidgets('accepting shows «محجوز» at once, without reopening',
        (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {'POST /exchange-proposals/3/accept': Reply(accepted())},
      );
      await _open(tester, backend);
      expect(find.text('مفتوح'), findsOneWidget);

      await tester.tap(find.text('قبول'));
      await tester.pumpAndSettle();

      // Still the same screen — nothing was popped or pushed.
      expect(find.byType(ExchangeRequestDetailScreen), findsOneWidget);
      expect(find.text('محجوز'), findsOneWidget);
      expect(find.text('مفتوح'), findsNothing);
    });

    testWidgets('the accept and reject actions go away once it is matched',
        (tester) async {
      final backend = _backend(
        // Two pending proposals: answering one must take the other one's
        // buttons away too, because the request is no longer open.
        received: [exchangeProposalNoAvatar(id: 3), exchangeProposalNoAvatar(id: 4)],
        extra: {'POST /exchange-proposals/3/accept': Reply(accepted())},
      );
      await _open(tester, backend);
      expect(find.text('قبول'), findsNWidgets(2));

      await tester.tap(find.text('قبول').first);
      await tester.pumpAndSettle();

      expect(find.text('قبول'), findsNothing);
      expect(find.text('رفض'), findsNothing);
    });

    testWidgets('the new status needs no extra request of its own',
        (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {'POST /exchange-proposals/3/accept': Reply(accepted())},
      );
      await _open(tester, backend);

      await tester.tap(find.text('قبول'));
      await tester.pumpAndSettle();

      // The answer already carried the request: only the usual reload ran.
      expect(backend.callsTo('POST /exchange-proposals/3/accept'), 1);
      expect(backend.callsTo('GET /exchange-requests/7/proposals'), 2);
      expect(backend.callsTo('GET /exchange-requests/7'), 0);
    });

    testWidgets('a refused acceptance leaves the request open', (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3)],
        extra: {
          'POST /exchange-proposals/3/accept': const Reply(
            {'detail': 'This proposal has already been responded to'},
            status: 422,
          ),
        },
      );
      await _open(tester, backend);

      await tester.tap(find.text('قبول'));
      await pumpFrames(tester);

      expect(find.text('مفتوح'), findsOneWidget);
      expect(find.text('محجوز'), findsNothing);
      expect(find.text('قبول'), findsOneWidget);     // still answerable
    });

    testWidgets('rejecting one proposal keeps the request open', (tester) async {
      final backend = _backend(
        received: [exchangeProposalNoAvatar(id: 3), exchangeProposalNoAvatar(id: 4)],
        extra: {
          'POST /exchange-proposals/3/reject': Reply(
            exchangeProposalNoAvatar(
              id: 3,
              status: 'rejected',
              request: exchangeRequestNoAvatar(status: 'open'),
            ),
          ),
        },
      );
      await _open(tester, backend);

      await tester.tap(find.text('رفض').first);
      await tester.pumpAndSettle();

      expect(find.text('مفتوح'), findsOneWidget);
      expect(find.text('محجوز'), findsNothing);
    });

    testWidgets('a closed request still reads «مغلق»', (tester) async {
      await _open(
        tester,
        _backend(received: [exchangeProposalNoAvatar(id: 3)]),
        request: exchangeRequestNoAvatar(status: 'closed'),
      );

      expect(find.text('مغلق'), findsOneWidget);
      expect(find.text('محجوز'), findsNothing);
      expect(find.text('مفتوح'), findsNothing);
    });
  });
}
