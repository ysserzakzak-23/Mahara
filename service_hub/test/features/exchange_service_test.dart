import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/exchange/data/exchange_models.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

ExchangeService serviceFor(FakeBackend backend) => ExchangeService(
      apiClient: ApiClient(httpClient: backend.client, tokenStore: TokenStore()),
    );

Map<String, dynamic> proposalJson({String status = 'pending'}) => {
      'id': 3,
      'status': status,
      'message': 'hi',
      'proposer': providerJson(),
      'proposed_service': serviceListItemJson(),
      'request': exchangeRequestJson(),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  test('createRequest posts offered service and wanted category', () async {
    final backend = FakeBackend(exchangeRequestJson(), status: 201);
    final result = await serviceFor(backend)
        .createRequest(offeredServiceId: 1, wantedCategoryId: 2);

    expect(backend.last.url.path, endsWith('/exchange-requests'));
    expect(backend.lastJsonBody, {'offered_service_id': 1, 'wanted_category_id': 2});
    expect(result.id, 7);
  });

  test('createRequest includes the custom label when provided', () async {
    final backend = FakeBackend(exchangeRequestJson(), status: 201);
    await serviceFor(backend).createRequest(
      offeredServiceId: 1, wantedCategoryId: 9, wantedCustomCategoryLabel: 'نجار',
    );
    expect(backend.lastJsonBody, containsPair('wanted_custom_category_label', 'نجار'));
  });

  test('listOpenRequests sends exclude_user_id when given one', () async {
    final backend = FakeBackend([exchangeRequestJson()]);
    await serviceFor(backend).listOpenRequests(excludeUserId: 99);

    expect(backend.last.url.path, endsWith('/exchange-requests'));
    expect(backend.last.url.queryParameters['exclude_user_id'], '99');
  });

  test('listOpenRequests sends no exclusion when none is given', () async {
    final backend = FakeBackend(<dynamic>[]);
    await serviceFor(backend).listOpenRequests();

    expect(backend.last.url.query, isEmpty);
  });

  test('listOpenRequests stays public with the exclusion', () async {
    final backend = FakeBackend(<dynamic>[]);
    await serviceFor(backend).listOpenRequests(excludeUserId: 99);

    expect(backend.last.headers.containsKey('Authorization'), isFalse);
  });

  test('listOpenRequests is public (no auth header)', () async {
    final backend = FakeBackend([exchangeRequestJson()]);
    final list = await serviceFor(backend).listOpenRequests();

    expect(backend.last.headers.containsKey('Authorization'), isFalse);
    expect(list.items.single.isOpen, isTrue);
  });

  test('listMyRequests is authenticated', () async {
    final backend = FakeBackend([exchangeRequestJson()]);
    await serviceFor(backend).listMyRequests();

    expect(backend.last.url.path, endsWith('/exchange-requests/me'));
    expect(backend.last.headers['Authorization'], 'Bearer acc');
  });

  test('matchesForRequest parses direct matches', () async {
    final backend = FakeBackend([
      {'match_type': 'direct', 'other_request': exchangeRequestJson()},
    ]);
    final matches = await serviceFor(backend).matchesForRequest(7);

    expect(backend.last.url.path, endsWith('/exchange-requests/7/matches'));
    expect(matches.single.otherRequest.id, 7);
  });

  test('closeRequest issues DELETE', () async {
    final backend = FakeBackend(null, status: 204);
    await serviceFor(backend).closeRequest(7);

    expect(backend.last.method, 'DELETE');
    expect(backend.last.url.path, endsWith('/exchange-requests/7'));
  });

  group('proposals', () {
    test('createProposal sends the service and optional message', () async {
      final backend = FakeBackend(proposalJson(), status: 201);
      await serviceFor(backend)
          .createProposal(requestId: 7, proposedServiceId: 5, message: 'deal?');

      expect(backend.last.url.path, endsWith('/exchange-requests/7/proposals'));
      expect(backend.lastJsonBody, {'proposed_service_id': 5, 'message': 'deal?'});
    });

    test('createProposal omits an empty message', () async {
      final backend = FakeBackend(proposalJson(), status: 201);
      await serviceFor(backend)
          .createProposal(requestId: 7, proposedServiceId: 5, message: '');
      expect(backend.lastJsonBody, {'proposed_service_id': 5});
    });

    test('proposalsForRequest asks for that request only', () async {
      final backend = FakeBackend([proposalJson()]);
      final proposals = await serviceFor(backend).proposalsForRequest(7);

      expect(backend.last.url.path, endsWith('/exchange-requests/7/proposals'));
      expect(backend.last.url.query, isEmpty);
      expect(backend.last.method, 'GET');
      expect(proposals, hasLength(1));
    });

    test('proposalsForRequest puts the id in the path, not a filter', () async {
      final backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).proposalsForRequest(123);

      expect(backend.last.url.path, endsWith('/exchange-requests/123/proposals'));
      expect(backend.last.url.path, isNot(contains('exchange-proposals')));
    });

    test('proposalsForRequest reads an empty list as no proposals', () async {
      final backend = FakeBackend(<dynamic>[]);
      expect(await serviceFor(backend).proposalsForRequest(7), isEmpty);
    });

    test('listMyProposals toggles the sent flag', () async {
      var backend = FakeBackend([proposalJson()]);
      await serviceFor(backend).listMyProposals(sent: true);
      expect(backend.last.url.queryParameters['sent'], 'true');

      backend = FakeBackend(<dynamic>[]);
      await serviceFor(backend).listMyProposals(sent: false);
      expect(backend.last.url.queryParameters['sent'], 'false');
    });

    test('accept and reject hit their endpoints', () async {
      var backend = FakeBackend(proposalJson(status: 'accepted'));
      final accepted = await serviceFor(backend).acceptProposal(3);
      expect(backend.last.url.path, endsWith('/exchange-proposals/3/accept'));
      expect(accepted.isPending, isFalse);

      backend = FakeBackend(proposalJson(status: 'rejected'));
      await serviceFor(backend).rejectProposal(3);
      expect(backend.last.url.path, endsWith('/exchange-proposals/3/reject'));
    });
  });

  group('My Interests and exchange search', () {
    Map<String, dynamic> ranked({double? rating, int count = 0, double? relevance}) =>
        exchangeRequestJson()
          ..['offered_service_rating'] = rating
          ..['offered_service_review_count'] = count
          ..['relevance_score'] = relevance;

    test('listInterests calls /exchange-requests/interests with the token', () async {
      final backend = FakeBackend([ranked(rating: 4.9, count: 12)]);
      final list = await serviceFor(backend).listInterests();

      expect(backend.last.url.path, endsWith('/exchange-requests/interests'));
      expect(backend.last.url.queryParameters, isEmpty);
      expect(backend.last.headers['Authorization'], 'Bearer acc');
      expect(list.items.single.offeredServiceRating, 4.9);
      expect(list.items.single.offeredServiceReviewCount, 12);
      expect(list.items.single.relevanceScore, isNull);
    });

    test('listInterests sends the trimmed Arabic search text, and none when blank', () async {
      final backend = FakeBackend([]);
      await serviceFor(backend).listInterests(query: '  تصليح مكيف ');
      expect(backend.last.url.queryParameters['q'], 'تصليح مكيف');

      await serviceFor(backend).listInterests(query: '   ');
      expect(backend.last.url.queryParameters.containsKey('q'), isFalse);
    });

    test('searchRequests calls /exchange-requests/search and parses requests', () async {
      final backend = FakeBackend([ranked(relevance: 0.82)]);
      final list = await serviceFor(backend).searchRequests(' برمجة ');

      expect(backend.last.url.path, endsWith('/exchange-requests/search'));
      expect(backend.last.url.queryParameters['q'], 'برمجة');
      expect(list.items.single.relevanceScore, 0.82);
      expect(list.items.single.wantedCategory.name, 'كهرباء');   // a real exchange request
    });

    test('a ranked request without reviews parses as unrated', () {
      final model = ExchangeRequestModel.fromRankedJson(exchangeRequestJson());
      expect(model.offeredServiceRating, isNull);
      expect(model.offeredServiceReviewCount, 0);
      expect(model.relevanceScore, isNull);
    });

    test('integer ratings from JSON are read as doubles', () {
      final model = ExchangeRequestModel.fromRankedJson(ranked()..['offered_service_rating'] = 5);
      expect(model.offeredServiceRating, 5.0);
    });
  });
}
