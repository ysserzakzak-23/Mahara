import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/shared/widgets/city_picker_field.dart';
import 'package:service_hub/features/auth/data/city_service.dart';
import 'package:service_hub/features/search/search_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart'; 

Map<String, dynamic> _service(int id, String title, {Object price = '30.00'}) =>
    serviceListItemJson(id: id, price: price)..['title'] = title;

RoutedBackend _backend({
  List<Map<String, dynamic>>? services,
  List<Map<String, dynamic>>? categories,
}) =>
    RoutedBackend({
      'GET /services': Reply(services ?? [_service(100, 'Fix pipes'), _service(101, 'Paint walls')]),
      'GET /categories': Reply(categories ??
          [categoryJson(id: 1, name: 'سباكة'), categoryJson(id: 2, name: 'كهرباء')]),
      'GET /cities': const Reply(['دمشق', 'حلب']),
    });

Widget _app(RoutedBackend backend) {
  final api = apiFor(backend);
  return MaterialApp(
    home: SearchScreen(
      catalogService: CatalogService(apiClient: api),
      cityService: CityService(apiClient: api),
      detailsBuilder: (id) => Scaffold(body: Text('DETAILS $id')),
    ),
  );
}

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend));
  await tester.pumpAndSettle();
}

/// Query parameters of the most recent GET /search/smart call.
Map<String, String> _lastSmartQuery(RoutedBackend b) => b.requests
    .where((r) => r.method == 'GET' && r.url.path.endsWith('/search/smart'))
    .last
    .url
    .queryParameters;

/// Types into the search box and waits for the debounce + the request.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// Query parameters of the most recent GET /services call.
Map<String, String> _lastServicesQuery(RoutedBackend b) => b.requests
    .where((r) => r.method == 'GET' && r.url.path.endsWith('/services'))
    .last
    .url
    .queryParameters;

void main() {
  // The category list is cached across CatalogService instances, so each
  // test starts from an empty cache rather than another test's list.
  setUp(() {
    CatalogService.invalidateCategoriesCache();
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('loads categories, services and cities, then shows them', (tester) async {
    final backend = _backend();
    await _open(tester, backend);

    expect(backend.callsTo('GET /categories'), 1);
    expect(backend.callsTo('GET /services'), 1);
    expect(backend.callsTo('GET /cities'), 1);
    expect(find.text('Fix pipes'), findsOneWidget);
    expect(find.text('Paint walls'), findsOneWidget);
    expect(find.text('بواسطة Ahmad Ali'), findsNWidgets(2));
    expect(find.text('30 \$'), findsNWidgets(2));
  });

  testWidgets('shows a spinner while loading', (tester) async {
    final backend = _backend()..gate = Completer<void>();
    useTallScreen(tester);
    await tester.pumpWidget(_app(backend));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    backend.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Fix pipes'), findsOneWidget);
  });

  testWidgets('the "أخرى" category chip is always listed last', (tester) async {
    final backend = _backend(categories: [
      categoryJson(id: 9, name: 'أخرى', isOther: true),
      categoryJson(id: 1, name: 'سباكة'),
      categoryJson(id: 2, name: 'كهرباء'),
    ]);
    await _open(tester, backend);

    double x(String label) => tester.getTopLeft(find.text(label)).dx;
    expect(x('الكل'), lessThan(x('سباكة')));
    expect(x('سباكة'), lessThan(x('كهرباء')));
    expect(x('كهرباء'), lessThan(x('أخرى')));
  });

  testWidgets('empty result shows a message', (tester) async {
    await _open(tester, _backend(services: []));
    expect(find.text('لم يتم العثور على خدمات.'), findsOneWidget);
  });

  group('smart search', () {
    RoutedBackend smartBackend() => _backend()
      ..routes['GET /search/smart'] = Reply([_service(100, 'سباك محترف')]);

    testWidgets('typing asks the backend (no local filtering)', (tester) async {
      final backend = smartBackend();
      await _open(tester, backend);

      await _type(tester, 'بدي أصلح حنفية');

      expect(backend.callsTo('GET /search/smart'), 1);
      expect(_lastSmartQuery(backend)['q'], 'بدي أصلح حنفية');
      expect(backend.callsTo('GET /services'), 1); // only the initial load
      expect(find.text('سباك محترف'), findsOneWidget);
      expect(find.text('Paint walls'), findsNothing);
    });

    testWidgets('waits until the user pauses typing', (tester) async {
      final backend = smartBackend();
      await _open(tester, backend);

      await tester.enterText(find.byType(TextField), 'حن');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), 'حنفية');
      await tester.pump(const Duration(milliseconds: 100));
      expect(backend.callsTo('GET /search/smart'), 0);

      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /search/smart'), 1);
      expect(_lastSmartQuery(backend)['q'], 'حنفية');
    });

    testWidgets('clearing the box goes back to the plain list', (tester) async {
      final backend = smartBackend();
      await _open(tester, backend);

      await _type(tester, 'حنفية');
      expect(find.text('Paint walls'), findsNothing);

      await _type(tester, '');
      expect(backend.callsTo('GET /services'), 2);
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('Paint walls'), findsOneWidget);
    });

    testWidgets('category and city narrow the smart search', (tester) async {
      final backend = smartBackend();
      await _open(tester, backend);
      await _type(tester, 'حنفية');

      await tester.tap(find.text('سباكة'));
      await tester.pumpAndSettle();
      expect(_lastSmartQuery(backend), {'q': 'حنفية', 'limit': '30', 'category_id': '1'});

      await tester.tap(find.byType(CityPickerField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حلب').last);
      await tester.pumpAndSettle();
      expect(_lastSmartQuery(backend),
          {'q': 'حنفية', 'limit': '30', 'category_id': '1', 'city': 'حلب'});
    });

    testWidgets('no match shows a helpful message', (tester) async {
      final backend = _backend()..routes['GET /search/smart'] = const Reply([]);
      await _open(tester, backend);

      await _type(tester, 'شي غريب');

      expect(find.text('لم نجد خدمات مطابقة لطلبك، جرّب كلمات أخرى.'), findsOneWidget);
    });

    testWidgets('a failed search shows the error and Retry searches again',
        (tester) async {
      final backend = _backend()
        ..routes['GET /search/smart'] = const Reply({'detail': 'down'}, status: 500);
      await _open(tester, backend);

      await _type(tester, 'حنفية');
      expect(find.text('down'), findsOneWidget);

      backend.routes['GET /search/smart'] = Reply([_service(100, 'سباك محترف')]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(find.text('سباك محترف'), findsOneWidget);
    });

    testWidgets('there is no separate "smart search" button any more',
        (tester) async {
      await _open(tester, _backend());
      expect(find.byTooltip('البحث الذكي'), findsNothing);
      expect(find.byTooltip('خدمات قريبة مني'), findsOneWidget);
    });
  });

  testWidgets('choosing a category reloads with category_id; "الكل" clears it',
      (tester) async {
    final backend = _backend();
    await _open(tester, backend);

    await tester.tap(find.text('كهرباء'));
    await tester.pumpAndSettle();
    expect(_lastServicesQuery(backend), {'category_id': '2'});

    await tester.tap(find.text('الكل'));
    await tester.pumpAndSettle();
    expect(_lastServicesQuery(backend), isEmpty);
  });

  testWidgets('choosing a city reloads with the city filter', (tester) async {
    final backend = _backend();
    await _open(tester, backend);

    await tester.tap(find.byType(CityPickerField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حلب').last);
    await tester.pumpAndSettle();

    expect(_lastServicesQuery(backend), {'city': 'حلب'});
  });

  testWidgets('category and city filters combine', (tester) async {
    final backend = _backend();
    await _open(tester, backend);

    await tester.tap(find.byType(CityPickerField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('دمشق').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('سباكة'));
    await tester.pumpAndSettle();

    expect(_lastServicesQuery(backend), {'category_id': '1', 'city': 'دمشق'});
  });

  testWidgets('a failed load shows the error and Retry recovers', (tester) async {
    final backend = _backend();
    backend.routes['GET /services'] = const Reply({'detail': 'db down'}, status: 500);
    await _open(tester, backend);

    expect(find.text('db down'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);

    backend.routes['GET /services'] = Reply([_service(100, 'Fix pipes')]);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(find.text('db down'), findsNothing);
    expect(find.text('Fix pipes'), findsOneWidget);
  });

  testWidgets('tapping a service opens its details', (tester) async {
    await _open(tester, _backend());

    await tester.tap(find.text('Paint walls'));
    await tester.pumpAndSettle();

    expect(find.text('DETAILS 101'), findsOneWidget);
  });
}
