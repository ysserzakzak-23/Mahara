import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/exchange/create_exchange_request_screen.dart';
import 'package:service_hub/features/exchange/data/exchange_service.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/shared/widgets/category_picker_field.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _me = {'id': 10, 'email': 'me@b.com', 'role': 'user', 'is_provider': true, 'is_active': true};

Map<String, dynamic> _myService(int id, String title) =>
    serviceListItemJson(id: id)..['title'] = title;

RoutedBackend _backend({
  List<Map<String, dynamic>>? myServices,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/me': const Reply(_me),
      'GET /services/provider/10': Reply(myServices ?? [_myService(100, 'Fix pipes'), _myService(101, 'Paint walls')]),
      'GET /categories': Reply([
        categoryJson(id: 9, name: 'أخرى', isOther: true),
        categoryJson(id: 1, name: 'سباكة'),
        categoryJson(id: 2, name: 'كهرباء'),
        categoryJson(id: 3, name: 'Web Design'),
      ]),
      'POST /exchange-requests': Reply(exchangeRequestNoAvatar(), status: 201),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CreateExchangeRequestScreen(
                  tokenStore: store,
                  catalogService: CatalogService(apiClient: api),
                  exchangeService: ExchangeService(apiClient: api),
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

/// index 0 = the offered-service dropdown, 1 = the wanted-category picker.
/// The category one opens the shared searchable sheet instead of a menu.
Future<void> _choose(WidgetTester tester, int dropdownIndex, String label) async {
  if (dropdownIndex == 0) {
    await tester.tap(find.byType(DropdownButtonFormField<int>));
  } else {
    await tester.tap(find.byType(CategoryPickerField));
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder get _searchBox => find.widgetWithText(TextField, 'ابحث عن مهنة...');

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byType(CategoryPickerField));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String query) async {
  await tester.enterText(_searchBox, query);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.text('فتح الطلب'));
  await pumpFrames(tester);
}

void main() {
  // The form reads my id from the stored access token now, so it has to
  // be a real one for user 10 — the provider whose services the fake
  // backend serves.
  // The category list is cached across CatalogService instances, so each
  // test starts from an empty cache rather than another test's list.
  setUp(() {
    CatalogService.invalidateCategoriesCache();
    SharedPreferences.setMockInitialValues({
        'access_token': tokenFor(10),
      });
  });

  testWidgets('loads my services and the categories', (tester) async {
    final backend = _backend();
    await _open(tester, backend);

    // Was 1: the form used to fetch the whole profile to learn my id.
    expect(backend.callsTo('GET /users/me'), 0);
    expect(backend.callsTo('GET /services/provider/10'), 1);
    expect(backend.callsTo('GET /categories'), 1);
    expect(find.text('طلب تبادل جديد'), findsOneWidget);
    expect(find.text('ماذا تريد أن تعرض؟'), findsOneWidget);
    expect(find.text('ماذا تريد بالمقابل؟'), findsOneWidget);
    // one dropdown for my own services, the searchable picker for the category
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    expect(find.byType(CategoryPickerField), findsOneWidget);
  });

  testWidgets('a user without services is told to publish one first', (tester) async {
    await _open(tester, _backend(myServices: []));

    expect(find.textContaining('يجب أن تملك خدمة منشورة'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    expect(find.byType(CategoryPickerField), findsNothing);
  });

  testWidgets('shows the error when the form data cannot be loaded', (tester) async {
    await _open(
      tester,
      _backend(extra: {'GET /categories': const Reply({'detail': 'boom'}, status: 500)}),
    );
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('"أخرى" is listed last among the wanted categories', (tester) async {
    await _open(tester, _backend());
    await _openPicker(tester);

    double y(String label) => tester.getTopLeft(find.text(label).last).dy;
    expect(y('سباكة'), lessThan(y('كهرباء')));
    expect(y('كهرباء'), lessThan(y('أخرى')));
  });

  group('searching the wanted category', () {
    testWidgets('the picker opens with a search box and every category',
        (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);

      expect(_searchBox, findsOneWidget);
      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('كهرباء'), findsOneWidget);
      expect(find.text('Web Design'), findsOneWidget);
      expect(find.text('أخرى'), findsOneWidget);
    });

    testWidgets('typing Arabic narrows the list', (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);

      await _type(tester, 'كهر');

      expect(find.text('كهرباء'), findsOneWidget);
      expect(find.text('سباكة'), findsNothing);
      expect(find.text('Web Design'), findsNothing);
      expect(find.text('أخرى'), findsOneWidget); // always available
    });

    testWidgets('typing English narrows the list, whatever the case',
        (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);

      await _type(tester, 'web');
      expect(find.text('Web Design'), findsOneWidget);
      expect(find.text('سباكة'), findsNothing);

      await _type(tester, 'DESIGN');
      expect(find.text('Web Design'), findsOneWidget);
      expect(find.text('كهرباء'), findsNothing);
    });

    testWidgets('surrounding spaces do not break the match', (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);

      await _type(tester, '  سباكة  ');

      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('كهرباء'), findsNothing);
    });

    testWidgets('clearing the search brings every category back',
        (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);
      await _type(tester, 'كهر');
      expect(find.text('سباكة'), findsNothing);

      await tester.tap(find.byTooltip('مسح'));
      await tester.pumpAndSettle();

      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('كهرباء'), findsOneWidget);
      expect(find.text('Web Design'), findsOneWidget);
    });

    testWidgets('a query that matches nothing shows the empty state',
        (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);

      await _type(tester, 'بيطري');

      expect(find.textContaining('لم نجد مهنة بهذا الاسم'), findsOneWidget);
      expect(find.text('سباكة'), findsNothing);
      expect(find.text('أخرى'), findsOneWidget);
    });

    testWidgets('typing alone selects nothing', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');
      await _openPicker(tester);
      await _type(tester, 'كهر');
      await tester.tap(find.byTooltip('مسح'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10)); // dismiss without choosing
      await tester.pumpAndSettle();

      await _submit(tester);

      expect(find.text('اختر الفئة التي تريد التبادل فيها.'), findsOneWidget);
      expect(backend.callsTo('POST /exchange-requests'), 0);
    });

    testWidgets('picking a searched category sends its real id',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');
      await _openPicker(tester);
      await _type(tester, 'design');
      await tester.tap(find.text('Web Design'));
      await tester.pumpAndSettle();

      await _submit(tester);

      expect(backend.lastBodyOf('POST /exchange-requests'),
          {'offered_service_id': 100, 'wanted_category_id': 3});
    });

    testWidgets('reopening the picker starts from an empty search',
        (tester) async {
      await _open(tester, _backend());
      await _openPicker(tester);
      await _type(tester, 'كهر');
      expect(find.text('سباكة'), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await _openPicker(tester);

      expect(tester.widget<TextField>(_searchBox).controller?.text, '');
      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('كهرباء'), findsOneWidget);
    });

    testWidgets('the chosen category is shown in the field and ticked',
        (tester) async {
      await _open(tester, _backend());
      await _choose(tester, 1, 'كهرباء');

      expect(find.text('كهرباء'), findsOneWidget); // in the closed field
      await _openPicker(tester);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('needs an offered service first', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await _submit(tester);

      expect(find.text('اختر إحدى خدماتك أولاً.'), findsOneWidget);
      expect(backend.callsTo('POST /exchange-requests'), 0);
    });

    testWidgets('then a wanted category', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');

      await _submit(tester);

      expect(find.text('اختر الفئة التي تريد التبادل فيها.'), findsOneWidget);
      expect(backend.callsTo('POST /exchange-requests'), 0);
    });

    testWidgets('the "أخرى" category needs a description', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');
      await _choose(tester, 1, 'أخرى');
      expect(find.byType(TextField), findsOneWidget); // the free-text box appears

      await _submit(tester);

      expect(find.text('اكتب بالضبط ما تحتاجه.'), findsOneWidget);
      expect(backend.callsTo('POST /exchange-requests'), 0);
    });

    testWidgets('the free-text box only exists for "أخرى"', (tester) async {
      await _open(tester, _backend());
      await _choose(tester, 1, 'كهرباء');
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('submitting', () {
    testWidgets('opens the request and closes the screen', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Paint walls');
      await _choose(tester, 1, 'كهرباء');

      await _submit(tester);

      expect(backend.lastBodyOf('POST /exchange-requests'),
          {'offered_service_id': 101, 'wanted_category_id': 2});
      expect(find.text('تم فتح طلب التبادل!'), findsOneWidget);
      expect(find.byType(CreateExchangeRequestScreen), findsNothing);
    });

    testWidgets('"أخرى" sends the trimmed custom label', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');
      await _choose(tester, 1, 'أخرى');
      await tester.enterText(find.byType(TextField), '  نجار  ');

      await _submit(tester);

      expect(backend.lastBodyOf('POST /exchange-requests'), {
        'offered_service_id': 100,
        'wanted_category_id': 9,
        'wanted_custom_category_label': 'نجار',
      });
    });

    testWidgets('a backend refusal is shown and the form stays open', (tester) async {
      final backend = _backend(extra: {
        'POST /exchange-requests': const Reply(
          {'detail': 'You can only offer a service you own'},
          status: 403,
        ),
      });
      await _open(tester, backend);
      await _choose(tester, 0, 'Fix pipes');
      await _choose(tester, 1, 'كهرباء');

      await _submit(tester);

      expect(find.text('You can only offer a service you own'), findsOneWidget);
      expect(find.byType(CreateExchangeRequestScreen), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );
    });
  });
}
