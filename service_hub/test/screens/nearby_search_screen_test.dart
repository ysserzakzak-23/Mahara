import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/config/nearby_search_config.dart';
import 'package:service_hub/core/location/location_service.dart';
import 'package:service_hub/features/search/nearby_search_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/shared/widgets/category_picker_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _plumbing = 1;
const _electrical = 2;

Map<String, dynamic> _result(
  int id,
  String title, {
  double? distance = 1.5,
  int categoryId = _plumbing,
  String? price = '30.00',
}) =>
    serviceListItemJson(id: id, price: price ?? '0')
      ..['title'] = title
      ..['price'] = price
      ..['distance_km'] = distance
      ..['category'] = categoryJson(
        id: categoryId,
        name: categoryId == _plumbing ? 'سباكة' : 'كهرباء',
      );

RoutedBackend _backend({List<Map<String, dynamic>>? results, Map<String, Reply> extra = const {}}) =>
    RoutedBackend({
      'GET /categories': Reply([
        categoryJson(id: _plumbing, name: 'سباكة'),
        categoryJson(id: _electrical, name: 'كهرباء'),
      ]),
      'GET /search/services': Reply(results ?? [_result(100, 'Fix pipes')]),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend, FakeLocationService location) async {
  useTallScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: NearbySearchScreen(
      catalogService: CatalogService(apiClient: apiFor(backend)),
      locationService: location,
      detailsBuilder: (id) => Scaffold(body: Text('DETAILS $id')),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _chooseCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byType(CategoryPickerField));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

final _searchButton = find.text('ابحث عن خدمات قريبة');

Future<void> _pressSearch(WidgetTester tester) async {
  await tester.tap(_searchButton);
  await tester.pumpAndSettle();
}

/// Opens the screen, picks [category] and searches.
Future<void> _searchFor(
  WidgetTester tester,
  RoutedBackend backend,
  FakeLocationService gps, {
  String category = 'سباكة',
}) async {
  await _open(tester, backend, gps);
  await _chooseCategory(tester, category);
  await _pressSearch(tester);
}

Map<String, String> _lastSearch(RoutedBackend b) => b.requests
    .where((r) => r.url.path.endsWith('/search/services'))
    .last
    .url
    .queryParameters;

bool _searchEnabled(WidgetTester tester) => tester
    .widget<ButtonStyleButton>(find.ancestor(
      of: _searchButton,
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ))
    .enabled;

void main() {
  // The category list is cached across CatalogService instances, so each
  // test starts from an empty cache rather than another test's list.
  setUp(() {
    CatalogService.invalidateCategoriesCache();
    SharedPreferences.setMockInitialValues({'access_token': 'acc'});
  });

  group('before searching', () {
    testWidgets('nothing is searched and no location is read until the user asks',
        (tester) async {
      final backend = _backend();
      final gps = FakeLocationService();
      await _open(tester, backend, gps);

      expect(backend.callsTo('GET /search/services'), 0);
      expect(gps.calls, 0);
      expect(find.text('اختر التصنيف الذي تبحث عنه، ثم اضغط «ابحث عن خدمات قريبة».'),
          findsOneWidget);
    });

    testWidgets('the category picker uses the shared categories; search needs a category',
        (tester) async {
      await _open(tester, _backend(), FakeLocationService());

      expect(find.byType(CategoryPickerField), findsOneWidget);
      expect(find.text('اختر التصنيف الذي تبحث عنه'), findsOneWidget);
      expect(_searchEnabled(tester), isFalse);

      await _chooseCategory(tester, 'كهرباء');

      expect(find.text('كهرباء'), findsOneWidget); // shown as the selection
      expect(_searchEnabled(tester), isTrue);
      expect(find.text('اضغط «ابحث عن خدمات قريبة» لعرض الخدمات الأقرب إليك.'), findsOneWidget);
    });

    testWidgets('a categories failure is shown with a retry', (tester) async {
      final backend = _backend(extra: {'GET /categories': const Reply({'detail': 'boom'}, status: 500)});
      await _open(tester, backend, FakeLocationService());
      expect(find.text('تعذّر تحميل التصنيفات: boom'), findsOneWidget);

      backend.routes['GET /categories'] = Reply([categoryJson(id: _plumbing, name: 'سباكة')]);
      await tester.tap(find.text('حاول مرة أخرى'));
      await tester.pumpAndSettle();
      expect(find.byType(CategoryPickerField), findsOneWidget);
    });
  });

  group('searching', () {
    testWidgets('sends the device position, the category id and the default radius',
        (tester) async {
      final backend = _backend();
      final gps = FakeLocationService(position: fakePosition(lat: 33.5138, lon: 36.2765));
      await _searchFor(tester, backend, gps, category: 'كهرباء');

      expect(_lastSearch(backend), {
        'latitude': '33.5138',          // latitude stays latitude...
        'longitude': '36.2765',         // ...and longitude stays longitude
        'radius_km': '${NearbySearchConfig.defaultRadiusKm}',
        'category_id': '$_electrical',  // the id, not a text match
      });
      expect(gps.calls, 1);
      expect(find.text('نطاق البحث: 25 كم'), findsOneWidget);
    });

    testWidgets('reads a fresh position for every search (never a stale one)', (tester) async {
      final backend = _backend();
      final gps = FakeLocationService(position: fakePosition(lat: 33.5, lon: 36.3));
      await _searchFor(tester, backend, gps);

      gps.position = fakePosition(lat: 34.7, lon: 36.7); // the user moved
      await _pressSearch(tester);

      expect(gps.calls, 2);
      expect(_lastSearch(backend)['latitude'], '34.7');
      expect(_lastSearch(backend)['longitude'], '36.7');
    });

    testWidgets('shows a "locating" state, then a "searching" state', (tester) async {
      final backend = _backend();
      final gps = FakeLocationService(gate: Completer<void>());
      await _open(tester, backend, gps);
      await _chooseCategory(tester, 'سباكة');

      await tester.tap(_searchButton);
      await tester.pump();
      expect(find.text('جارٍ تحديد موقعك...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(_searchEnabled(tester), isFalse); // no double search

      backend.gate = Completer<void>();
      gps.gate!.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('جارٍ البحث عن الخدمات القريبة...'), findsOneWidget);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Fix pipes'), findsOneWidget);
    });

    testWidgets('changing the radius is sent with the next search', (tester) async {
      final backend = _backend();
      await _searchFor(tester, backend, FakeLocationService());
      final before = backend.callsTo('GET /search/services');

      await tester.drag(find.byType(Slider), const Offset(150, 0));
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /search/services'), before); // waits for «ابحث»

      await _pressSearch(tester);
      expect(double.parse(_lastSearch(backend)['radius_km']!), greaterThan(25));
    });

    testWidgets('changing the category clears the old results until searching again',
        (tester) async {
      final backend = _backend();
      await _searchFor(tester, backend, FakeLocationService());
      expect(find.text('Fix pipes'), findsOneWidget);

      await _chooseCategory(tester, 'كهرباء');
      expect(find.text('Fix pipes'), findsNothing);

      await _pressSearch(tester);
      expect(_lastSearch(backend)['category_id'], '$_electrical');
    });
  });

  group('results', () {
    testWidgets('show the name, provider, price and the distance in Arabic', (tester) async {
      await _searchFor(tester, _backend(results: [
        _result(1, 'Near', distance: 0.5),
        _result(2, 'Mid', distance: 1.24),
        _result(3, 'Far', distance: 3.0),
      ]), FakeLocationService());

      expect(find.text('Near'), findsOneWidget);
      expect(find.text('بواسطة Ahmad Ali'), findsNWidgets(3));
      expect(find.text('30 \$'), findsNWidgets(3));
      expect(find.text('500 متر'), findsOneWidget);
      expect(find.text('1.2 كم'), findsOneWidget);
      expect(find.text('3 كم'), findsOneWidget);
    });

    testWidgets('are listed nearest first', (tester) async {
      await _searchFor(tester, _backend(results: [
        _result(3, 'Far', distance: 9.0),
        _result(1, 'Near', distance: 0.3),
        _result(2, 'Mid', distance: 4.0),
      ]), FakeLocationService());

      double top(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(top('Near'), lessThan(top('Mid')));
      expect(top('Mid'), lessThan(top('Far')));
    });

    testWidgets('only services of the selected category are shown', (tester) async {
      await _searchFor(tester, _backend(results: [
        _result(1, 'Plumber', categoryId: _plumbing),
        _result(2, 'Electrician', categoryId: _electrical),
      ]), FakeLocationService());

      expect(find.text('Plumber'), findsOneWidget);
      expect(find.text('Electrician'), findsNothing);
    });

    testWidgets('services outside the radius are never shown', (tester) async {
      await _searchFor(tester, _backend(results: [
        _result(1, 'Inside', distance: 24.9),
        _result(2, 'Outside', distance: 25.1),
        _result(3, 'No distance', distance: null),
      ]), FakeLocationService());

      expect(find.text('Inside'), findsOneWidget);
      expect(find.text('Outside'), findsNothing);
      expect(find.text('No distance'), findsNothing);
    });

    testWidgets('a service without a price says «السعر غير محدد»', (tester) async {
      await _searchFor(tester, _backend(results: [_result(1, 'Free form', price: null)]),
          FakeLocationService());
      expect(find.text('السعر غير محدد'), findsOneWidget);
    });

    testWidgets('no results: an Arabic message naming the category and radius', (tester) async {
      await _searchFor(tester, _backend(results: []), FakeLocationService());

      expect(
        find.text('لا توجد خدمات من تصنيف «سباكة» ضمن 25 كم من موقعك.\nجرّب توسيع نطاق البحث.'),
        findsOneWidget,
      );
    });

    testWidgets('tapping a result opens its details', (tester) async {
      await _searchFor(tester, _backend(results: [_result(55, 'Fix pipes')]), FakeLocationService());

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();

      expect(find.text('DETAILS 55'), findsOneWidget);
    });
  });

  group('location problems', () {
    testWidgets('permission denied: explains why location is needed, and retries',
        (tester) async {
      final backend = _backend();
      final gps = FakeLocationService(
        error: LocationServiceException(
          'لازم تسمح للتطبيق بالوصول لموقعك عشان يلاقي الخدمات القريبة منك.',
          reason: LocationFailure.permissionDenied,
        ),
      );
      await _searchFor(tester, backend, gps);

      expect(find.text('لازم تسمح للتطبيق بالوصول لموقعك عشان يلاقي الخدمات القريبة منك.'),
          findsOneWidget);
      expect(find.byIcon(Icons.location_off), findsOneWidget);
      expect(backend.callsTo('GET /search/services'), 0); // no fake coordinates used
      expect(find.text('فتح إعدادات الموقع'), findsNothing);

      gps.error = null;
      await tester.tap(find.text('حاول مرة أخرى'));
      await tester.pumpAndSettle();

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(gps.calls, 2);
    });

    testWidgets('location switched off: offers the location settings and a retry',
        (tester) async {
      final backend = _backend();
      final gps = FakeLocationService(
        error: LocationServiceException(
          'خدمة الموقع مطفية على جهازك. فعّلها من الإعدادات وحاول مرة ثانية.',
          reason: LocationFailure.serviceDisabled,
        ),
      );
      await _searchFor(tester, backend, gps);

      expect(find.text('خدمة الموقع مطفية على جهازك. فعّلها من الإعدادات وحاول مرة ثانية.'),
          findsOneWidget);
      await tester.tap(find.text('فتح إعدادات الموقع'));
      await tester.pumpAndSettle();
      expect(gps.locationSettingsOpened, 1);

      expect(find.text('حاول مرة أخرى'), findsOneWidget);
      expect(backend.callsTo('GET /search/services'), 0);
    });

    testWidgets('permission denied forever: offers the app settings', (tester) async {
      final gps = FakeLocationService(
        error: LocationServiceException(
          'صلاحية الموقع مرفوضة بشكل دائم.',
          reason: LocationFailure.permissionDeniedForever,
        ),
      );
      await _searchFor(tester, _backend(), gps);

      await tester.tap(find.text('فتح إعدادات التطبيق'));
      await tester.pumpAndSettle();
      expect(gps.appSettingsOpened, 1);
    });

    testWidgets('an unexpected location failure gets a generic Arabic message', (tester) async {
      final backend = _backend();
      await _searchFor(tester, backend, FakeLocationService(error: StateError('gps exploded')));

      expect(find.text('تعذّر تحديد موقعك الحالي. حاول مرة ثانية.'), findsOneWidget);
      expect(find.textContaining('gps exploded'), findsNothing);
      expect(backend.callsTo('GET /search/services'), 0);
    });

    testWidgets('a failing search shows the backend message and can be retried', (tester) async {
      final backend = _backend(extra: {
        'GET /search/services': const Reply({'detail': 'search down'}, status: 500),
      });
      await _searchFor(tester, backend, FakeLocationService());
      expect(find.text('search down'), findsOneWidget);

      backend.routes['GET /search/services'] = Reply([_result(1, 'Back again')]);
      await tester.tap(find.text('حاول مرة أخرى'));
      await tester.pumpAndSettle();
      expect(find.text('Back again'), findsOneWidget);
    });
  });
}
