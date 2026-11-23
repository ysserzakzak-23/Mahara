// The shared category cache (Phase 5, Step 2).
//
// Five screens ask for the categories and each builds its own
// CatalogService, so the list used to be downloaded again on every visit.
// It is now fetched once and shared, for a bounded time.
//
// What these tests pin down: one request for many callers and many
// instances, one shared request when several ask at the same moment, a
// fresh fetch once the TTL has passed, nothing cached from a failure or a
// malformed answer, and an explicit invalidation that forces a refetch.
// The TTL is reached by moving an injected clock, never by waiting.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

/// A backend that counts its calls and can be told what to answer next,
/// including holding an answer open so two callers overlap.
class _Backend {
  int calls = 0;
  Object? body = const [];
  int status = 200;
  Completer<void>? gate;

  /// One gate and one reply per request, taken in call order; a request
  /// past the end of these falls back to [gate], [body] and [status].
  /// Only the invalidation-race tests need to steer two requests
  /// independently — every other test uses the single [gate].
  final List<Completer<void>> gates = [];
  final List<Reply> replies = [];

  http.Client get client => MockClient((req) async {
        final index = calls++;
        final hold = index < gates.length ? gates[index] : gate;
        if (hold != null) await hold.future;
        final reply =
            index < replies.length ? replies[index] : Reply(body, status: status);
        return http.Response(
          reply.body == null ? '' : jsonEncode(reply.body),
          reply.status,
          headers: jsonHeaders,
        );
      });

  /// A new CatalogService on its own ApiClient — as a new screen builds one.
  CatalogService service() => CatalogService(
        apiClient: ApiClient(httpClient: client, tokenStore: TokenStore()),
      );
}

List<Map<String, dynamic>> _categories([int count = 2]) => [
      for (var i = 1; i <= count; i++) categoryJson(id: i, name: 'تصنيف $i'),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({'access_token': 'acc'});
    CatalogService.invalidateCategoriesCache();
    // A clock the tests move by hand: the TTL is reached without waiting.
    now = DateTime.utc(2026, 11, 15, 12);
    CatalogService.clock = () => now;
  });

  tearDown(() {
    // No static state is left for the next test, here or anywhere else.
    CatalogService.invalidateCategoriesCache();
    CatalogService.clock = DateTime.now;
  });

  group('one fetch, shared', () {
    test('the first call fetches exactly once', () async {
      final backend = _Backend()..body = _categories();

      final list = await backend.service().categories();

      expect(backend.calls, 1);
      expect(list.map((c) => c.name), ['تصنيف 1', 'تصنيف 2']);
    });

    test('a second call inside the TTL sends no request', () async {
      final backend = _Backend()..body = _categories();
      final catalog = backend.service();

      final first = await catalog.categories();
      final second = await catalog.categories();

      expect(backend.calls, 1);
      expect(second.map((c) => c.id), first.map((c) => c.id));
    });

    test('a different CatalogService instance shares the cache', () async {
      // This is the case an instance field could not have solved: every
      // screen builds its own CatalogService.
      final backend = _Backend()..body = _categories();

      await backend.service().categories();
      final other = await backend.service().categories();

      expect(backend.calls, 1);
      expect(other, hasLength(2));
    });

    test('five instances, as the five screens would, cost one request',
        () async {
      final backend = _Backend()..body = _categories(3);

      for (var i = 0; i < 5; i++) {
        final list = await backend.service().categories();
        expect(list, hasLength(3), reason: 'instance $i');
      }

      expect(backend.calls, 1);
    });

    test('the cached list cannot be changed by a caller', () async {
      final backend = _Backend()..body = _categories();

      final first = await backend.service().categories();
      first.clear();

      final second = await backend.service().categories();
      expect(second, hasLength(2));
      expect(backend.calls, 1);
    });

    test('the order the backend sent is the order every caller sees',
        () async {
      final backend = _Backend()
        ..body = [
          categoryJson(id: 9, name: 'أخرى', isOther: true),
          categoryJson(id: 1, name: 'سباكة'),
          categoryJson(id: 2, name: 'كهرباء'),
        ];

      final first = await backend.service().categories();
      final cached = await backend.service().categories();

      expect(first.map((c) => c.id), [9, 1, 2]);
      expect(cached.map((c) => c.id), [9, 1, 2]);
    });
  });

  group('concurrent callers share one request', () {
    test('two callers at the same moment make one request', () async {
      final backend = _Backend()
        ..body = _categories()
        ..gate = Completer<void>();
      final catalog = backend.service();

      final first = catalog.categories();
      final second = catalog.categories();
      backend.gate!.complete();
      final results = await Future.wait([first, second]);

      expect(backend.calls, 1);
      expect(results[0].map((c) => c.id), results[1].map((c) => c.id));
    });

    test('five screens opening at once make one request', () async {
      final backend = _Backend()
        ..body = _categories()
        ..gate = Completer<void>();

      final pending = [for (var i = 0; i < 5; i++) backend.service().categories()];
      backend.gate!.complete();
      final results = await Future.wait(pending);

      expect(backend.calls, 1);
      for (final list in results) {
        expect(list, hasLength(2));
      }
    });

    test('each concurrent caller gets its own copy', () async {
      final backend = _Backend()
        ..body = _categories()
        ..gate = Completer<void>();

      final first = backend.service().categories();
      final second = backend.service().categories();
      backend.gate!.complete();
      final lists = await Future.wait([first, second]);

      lists[0].clear();
      expect(lists[1], hasLength(2));
    });

    test('a shared request that fails fails every caller, and is not cached',
        () async {
      final backend = _Backend()
        ..body = {'detail': 'تعذر تحميل التصنيفات'}
        ..status = 500
        ..gate = Completer<void>();

      final first = backend.service().categories();
      final second = backend.service().categories();
      backend.gate!.complete();

      await expectLater(first, throwsA(isA<ApiException>()));
      await expectLater(second, throwsA(isA<ApiException>()));
      expect(backend.calls, 1);

      // Nothing was cached, so a later call really tries again.
      backend
        ..body = _categories()
        ..status = 200
        ..gate = null;
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 2);
    });
  });

  group('the TTL is bounded', () {
    test('just before it expires the cache is still used', () async {
      final backend = _Backend()..body = _categories();
      await backend.service().categories();

      now = now.add(CatalogService.categoriesCacheTtl - const Duration(seconds: 1));
      await backend.service().categories();

      expect(backend.calls, 1);
    });

    test('once it expires the next call fetches again', () async {
      final backend = _Backend()..body = _categories();
      await backend.service().categories();

      now = now.add(CatalogService.categoriesCacheTtl);
      await backend.service().categories();

      expect(backend.calls, 2);
    });

    test('a category added by an administrator arrives after the TTL',
        () async {
      final backend = _Backend()..body = _categories(2);
      expect(await backend.service().categories(), hasLength(2));

      backend.body = _categories(3);
      // Still the old list while it is fresh...
      expect(await backend.service().categories(), hasLength(2));

      now = now.add(CatalogService.categoriesCacheTtl + const Duration(seconds: 1));

      // ...and the new one once it is not.
      expect(await backend.service().categories(), hasLength(3));
      expect(backend.calls, 2);
    });

    test('the refreshed list is cached in its turn', () async {
      final backend = _Backend()..body = _categories();
      await backend.service().categories();
      now = now.add(CatalogService.categoriesCacheTtl);
      await backend.service().categories();

      await backend.service().categories();

      expect(backend.calls, 2);
    });

    test('the TTL is five minutes', () {
      expect(CatalogService.categoriesCacheTtl, const Duration(minutes: 5));
    });
  });

  group('nothing bad is ever cached', () {
    test('a failed request is not cached and the next call retries',
        () async {
      final backend = _Backend()
        ..body = {'detail': 'تعذر تحميل التصنيفات'}
        ..status = 500;

      await expectLater(
        backend.service().categories(),
        throwsA(isA<ApiException>().having(
          (e) => e.message,
          'message',
          'تعذر تحميل التصنيفات',
        )),
      );

      backend
        ..body = _categories()
        ..status = 200;
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 2);
    });

    test('a malformed answer is not cached and the next call retries',
        () async {
      // A map where a list belongs: parsing throws.
      final backend = _Backend()..body = {'oops': 1};

      await expectLater(backend.service().categories(), throwsA(isA<Object>()));

      backend.body = _categories();
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 2);
    });

    test('a row that is not an object is not cached either', () async {
      final backend = _Backend()..body = [1, 2, 3];

      await expectLater(backend.service().categories(), throwsA(isA<Object>()));

      backend.body = _categories();
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 2);
    });

    test('a failure leaves an earlier good list unusable rather than wrong',
        () async {
      final backend = _Backend()..body = _categories();
      await backend.service().categories();

      // The cache expires, and the refresh fails.
      now = now.add(CatalogService.categoriesCacheTtl);
      backend
        ..body = {'detail': 'انقطع الاتصال'}
        ..status = 503;

      await expectLater(
        backend.service().categories(),
        throwsA(isA<ApiException>()),
      );

      // The caller saw the error — no stale list was served in its place.
      backend
        ..body = _categories(4)
        ..status = 200;
      expect(await backend.service().categories(), hasLength(4));
    });

    test('an empty list is a valid answer and is cached', () async {
      final backend = _Backend()..body = const [];

      expect(await backend.service().categories(), isEmpty);
      expect(await backend.service().categories(), isEmpty);
      expect(backend.calls, 1);
    });
  });

  group('explicit invalidation', () {
    test('it forces the next call to fetch fresh data', () async {
      final backend = _Backend()..body = _categories(2);
      await backend.service().categories();

      CatalogService.invalidateCategoriesCache();
      backend.body = _categories(5);

      expect(await backend.service().categories(), hasLength(5));
      expect(backend.calls, 2);
    });

    test('it is what a future category mutation would call on success',
        () async {
      // The app has no screen that creates or edits a category today, so
      // nothing calls this in production; this is the contract such a
      // screen would rely on.
      final backend = _Backend()..body = _categories(2);
      await backend.service().categories();

      // A mutation that failed must NOT invalidate: the list is untouched.
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 1);

      // A mutation that succeeded invalidates, and the new list arrives.
      CatalogService.invalidateCategoriesCache();
      backend.body = _categories(3);
      expect(await backend.service().categories(), hasLength(3));
      expect(backend.calls, 2);
    });

    test('a request settling after an invalidation leaves a newer one alone',
        () async {
      // The audited sequence. Without the ownership check in categories()'s
      // `finally`, A's cleanup clears the slot that B had already claimed,
      // and C — finding it empty — sends a third identical request.
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final backend = _Backend()
        // A and B answer differently, so it is visible which one C got.
        ..replies.addAll([
          Reply(_categories(2)),
          Reply(_categories(5)),
        ])
        ..gates.addAll([gateA, gateB]);

      // 1. A starts and its answer is held.
      final a = backend.service().categories();
      await pumpEventQueue();
      expect(backend.calls, 1);

      // 2. The cache is invalidated while A is still pending.
      CatalogService.invalidateCategoriesCache();

      // 3. B starts afterwards and is held independently. It cannot share
      //    A: the invalidation released the slot, so B claims it.
      final b = backend.service().categories();
      await pumpEventQueue();
      expect(backend.calls, 2);

      // 4 & 5. A completes, and its `finally` runs before `a` resolves.
      gateA.complete();
      expect(await a, hasLength(2));

      // 6. C starts while B is still pending.
      var cResolved = false;
      final c = backend.service().categories().then((list) {
        cResolved = true;
        return list;
      });
      await pumpEventQueue();

      // 7. C shared B's request: no third call, and C is still waiting on
      //    B rather than having been answered by one of its own (a third
      //    request would not have been gated, so it would have resolved).
      expect(backend.calls, 2, reason: 'C issued a duplicate request');
      expect(cResolved, isFalse, reason: 'C did not share B');

      // 8. B completes; B and C both get B's answer — which also shows
      //    A's pre-invalidation list was never cached, or C would hold it.
      gateB.complete();
      expect(await b, hasLength(5));
      expect(await c, hasLength(5));
      expect(backend.calls, 2);

      // And the cache now holds B's list: B's generation was current, so
      // it stored, and the next caller is served without a request.
      expect(await backend.service().categories(), hasLength(5));
      expect(backend.calls, 2);
    });

    test('the same holds when the earlier request fails', () async {
      // `finally` runs on the error path too, so the clobbering would
      // happen there as well.
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final backend = _Backend()
        ..replies.addAll([
          const Reply({'detail': 'انقطع الاتصال'}, status: 503),
          Reply(_categories(4)),
        ])
        ..gates.addAll([gateA, gateB]);

      final a = backend.service().categories();
      await pumpEventQueue();
      CatalogService.invalidateCategoriesCache();
      final b = backend.service().categories();
      await pumpEventQueue();
      expect(backend.calls, 2);

      gateA.complete();
      await expectLater(a, throwsA(isA<ApiException>()));

      var cResolved = false;
      final c = backend.service().categories().then((list) {
        cResolved = true;
        return list;
      });
      await pumpEventQueue();

      expect(backend.calls, 2, reason: 'C issued a duplicate request');
      expect(cResolved, isFalse, reason: 'C did not share B');

      gateB.complete();
      expect(await b, hasLength(4));
      expect(await c, hasLength(4));
      expect(backend.calls, 2);
    });

    test('invalidating while a request is in flight does not wedge it',
        () async {
      final backend = _Backend()
        ..body = _categories()
        ..gate = Completer<void>();

      final pending = backend.service().categories();
      CatalogService.invalidateCategoriesCache();
      backend.gate!.complete();

      expect(await pending, hasLength(2));

      // The next call fetches, because the invalidation dropped the entry.
      expect(await backend.service().categories(), hasLength(2));
      expect(backend.calls, 2);
    });
  });

  group('the request itself is unchanged', () {
    test('it is still a public GET /categories with no token', () async {
      final backend = _Backend()..body = _categories();
      http.Request? sent;
      final catalog = CatalogService(
        apiClient: ApiClient(
          httpClient: MockClient((req) async {
            sent = req;
            return http.Response(
              jsonEncode(_categories()),
              200,
              headers: jsonHeaders,
            );
          }),
          tokenStore: TokenStore(),
        ),
      );

      await catalog.categories();

      expect(sent!.method, 'GET');
      expect(sent!.url.path, endsWith('/categories'));
      expect(sent!.url.hasQuery, isFalse);
      expect(sent!.headers.containsKey('Authorization'), isFalse);
      expect(backend.calls, 0); // the other backend was never used
    });
  });
}
