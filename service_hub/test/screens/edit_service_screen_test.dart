import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/theme/app_theme.dart';
import 'package:service_hub/shared/widgets/category_picker_field.dart';
import 'package:service_hub/core/api/upload_service.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/core/location/location_service.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/service/edit_service_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _detail({
  Map<String, dynamic>? category,
  String? label,
  bool remote = false,
  String status = 'active',
  double? lat,
  double? lon,
  String? price = '25.50',
}) =>
    {
      'id': 100,
      'title': 'Fix pipes', // a legacy name: kept on the server, never edited
      'display_title': 'سباكة',
      'description': 'I fix all kinds of pipes',
      'price': price,
      'price_unit': 'per_hour',
      'status': status,
      'is_remote': remote,
      'latitude': lat,
      'longitude': lon,
      'category': category ?? categoryJson(),
      'custom_category_label': label,
      'provider': withoutAvatar(providerJson()),
    };

Map<String, dynamic> _me() => {
      'id': 1,
      'email': 'p@example.com',
      'role': 'user',
      'is_provider': true,
      'is_active': true,
      'profile': {'full_name': 'Provider', 'phone_number': '0912345678', 'city': 'دمشق'},
    };

Map<String, dynamic> _workingWindow() => {
      'id': 1,
      'day_of_week': 0,
      'start_time': '09:00:00',
      'end_time': '17:00:00',
      'is_active': true,
    };

RoutedBackend _backend({Map<String, dynamic>? detail, Map<String, Reply> extra = const {}}) => RoutedBackend({
      'GET /users/me': Reply(_me()),
      'GET /providers/1/availability': Reply([_workingWindow()]),
      'GET /services/100': Reply(detail ?? _detail()),
      'GET /categories': Reply([
        categoryJson(id: 9, name: 'أخرى', isOther: true),
        categoryJson(id: 1, name: 'سباكة'),
        categoryJson(id: 2, name: 'كهرباء'),
      ]),
      'PATCH /services/100': Reply(_detail()),
      'POST /uploads/image': const Reply({'url': '/uploads/new-cover.png'}),
      ...extra,
    });

Future<void> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  FakeImagePicker? picker,
  FakeLocationService? gps,
  ThemeMode? themeMode,
  Size? size,
}) async {
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  await openFromLauncher(
    tester,
    // With a theme mode: the app's real themes, in RTL (as in the app).
    theme: themeMode == null ? null : appTheme,
    darkTheme: themeMode == null ? null : darkAppTheme,
    themeMode: themeMode ?? ThemeMode.light,
    rtl: themeMode != null,
    size: size,
    (_) => EditServiceScreen(
      serviceId: 100,
      tokenStore: store,
      availabilityService: AvailabilityService(apiClient: api),
      availabilityScreenBuilder: (id) => Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('شاشة الدوام')),
          body: ElevatedButton(
            onPressed: () {
              backend.routes['GET /providers/1/availability'] = Reply([_workingWindow()]);
              Navigator.pop(context);
            },
            child: const Text('SAVE HOURS'),
          ),
        ),
      ),
      catalogService: CatalogService(apiClient: api),
      uploadService: UploadService(apiClient: api),
      imagePicker: picker ?? FakeImagePicker(),
      locationService: gps ?? FakeLocationService(),
    ),
  );
}

const _priceHint = 'السعر (اختياري) (\$)';
final _descriptionField = find.widgetWithText(TextField, 'الوصف');
final _priceField = find.widgetWithText(TextField, _priceHint);

String _textOf(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

/// The "remote / online" toggle. The screen also has an "active" toggle
/// (نشطة), so the switch is located through its own label.
Finder _remoteSwitch() => find.descendant(
      of: find.widgetWithText(SwitchListTile, 'تُقدَّم عن بُعد / أونلاين'),
      matching: find.byType(Switch),
    );

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('حفظ التغييرات'));
  await pumpFrames(tester);
}

void main() {
  // The working-hours gate reads the provider's id from the stored
  // access token now, so the token has to be a real one for provider 1.
  // The category list is cached across CatalogService instances, so each
  // test starts from an empty cache rather than another test's list.
  setUp(() {
    CatalogService.invalidateCategoriesCache();
    SharedPreferences.setMockInitialValues({
        'access_token': tokenFor(1),
      });
  });

  group('loading', () {
    testWidgets('pre-fills the form with the current listing', (tester) async {
      await _open(tester, _backend());

      expect(find.text('تعديل الخدمة'), findsOneWidget);
      expect(_textOf(tester, _descriptionField), 'I fix all kinds of pipes');
      expect(_textOf(tester, _priceField), '25.50');
      expect(find.text('سباكة'), findsOneWidget); // selected category
    });

    testWidgets('has no service-name field; category, description, price in that order',
        (tester) async {
      await _open(tester, _backend());

      expect(find.widgetWithText(TextField, 'اسم الخدمة'), findsNothing);
      expect(find.text('Fix pipes'), findsNothing); // the legacy name isn't an input
      final category = tester.getTopLeft(find.byType(CategoryPickerField)).dy;
      final description = tester.getTopLeft(_descriptionField).dy;
      final price = tester.getTopLeft(_priceField).dy;
      expect(category, lessThan(description));
      expect(description, lessThan(price));
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final size in const [Size(390, 844), Size(320, 640)]) {
        testWidgets(
            '${mode.name} ${size.width.toInt()}px: price and its unit side by side, same box',
            (tester) async {
          await _open(tester, _backend(), themeMode: mode, size: size);
          expectPriceAndUnitSideBySide(tester, screenWidth: size.width);
          expect(find.text('بالساعة'), findsOneWidget); // the listing's unit
        });
      }
    }

    testWidgets('changing the unit in the side-by-side field is sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend, themeMode: ThemeMode.light);

      await tester.tap(find.byKey(const Key('price-unit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('باليوم').last);
      await tester.pumpAndSettle();
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('price_unit', 'per_day'));
    });

    testWidgets('a listing without a price opens with an empty price field', (tester) async {
      await _open(tester, _backend(detail: _detail(price: null)));
      expect(_textOf(tester, _priceField), '');
    });

    testWidgets('shows the error when the listing cannot be loaded', (tester) async {
      await _open(
        tester,
        _backend(extra: {'GET /services/100': const Reply({'detail': 'Service not found'}, status: 404)}),
      );
      expect(find.text('Service not found'), findsOneWidget);
    });

    testWidgets('the switches mirror the listing', (tester) async {
      await _open(tester, _backend(detail: _detail(remote: true, status: 'inactive')));

      final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
      expect(switches[0].value, isTrue); // remote
      expect(switches[1].value, isFalse); // active
    });

    testWidgets('an "أخرى" listing shows its custom label', (tester) async {
      await _open(
        tester,
        _backend(detail: _detail(category: categoryJson(id: 9, name: 'أخرى', isOther: true), label: 'Gardener')),
      );
      expect(find.widgetWithText(TextField, 'Gardener'), findsOneWidget);
    });

    testWidgets('a located listing says so', (tester) async {
      await _open(tester, _backend(detail: _detail(lat: 33.5, lon: 36.3)));
      expect(find.text('تم تحديد الموقع — تظهر هذه الخدمة في البحث عن الخدمات القريبة.'), findsOneWidget);
      expect(find.text('تحديث'), findsOneWidget);
    });
  });

  group('saving', () {
    testWidgets('an untouched form re-sends the current values and closes', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await _save(tester);

      final body = backend.lastBodyOf('PATCH /services/100');
      expect(body.containsKey('title'), isFalse); // the legacy name is preserved
      expect(body, containsPair('price', 25.5));
      expect(body, containsPair('category_id', 1));
      expect(body, containsPair('status', 'active'));
      expect(body, containsPair('is_remote', false));
      expect(body.containsKey('cover_image_url'), isFalse);
      expect(find.text('تم تحديث الخدمة!'), findsOneWidget);
      expect(find.byType(EditServiceScreen), findsNothing);
    });

    testWidgets('edited fields are sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(_descriptionField, 'I fix every kind of pipe');
      await tester.enterText(_priceField, '40');
      await _save(tester);

      final body = backend.lastBodyOf('PATCH /services/100');
      expect(body, containsPair('description', 'I fix every kind of pipe'));
      expect(body, containsPair('price', 40.0));
    });

    testWidgets('emptying the price removes it (sends null, not 0)', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(_priceField, '');
      await _save(tester);

      final body = backend.lastBodyOf('PATCH /services/100');
      expect(body.containsKey('price'), isTrue);
      expect(body['price'], isNull);
      expect(find.text('تم تحديث الخدمة!'), findsOneWidget);
    });

    testWidgets('a listing without a price can be saved without adding one', (tester) async {
      final backend = _backend(detail: _detail(price: null));
      await _open(tester, backend);

      await _save(tester);

      expect(backend.callsTo('PATCH /services/100'), 1);
      expect(backend.lastBodyOf('PATCH /services/100')['price'], isNull);
    });

    testWidgets('a price can be added to a listing that had none', (tester) async {
      final backend = _backend(detail: _detail(price: null));
      await _open(tester, backend);

      await tester.enterText(_priceField, '15');
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('price', 15.0));
    });

    testWidgets('switching "نشطة" off sends status=inactive', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byType(Switch).at(1));
      await tester.pump();
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('status', 'inactive'));
    });

    testWidgets('switching to another category is sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byType(CategoryPickerField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('كهرباء').last);
      await tester.pumpAndSettle();
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('category_id', 2));
    });

    testWidgets('moving to "أخرى" requires a label', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byType(CategoryPickerField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('أخرى').last);
      await tester.pumpAndSettle();
      await _save(tester);

      expect(find.text('يرجى كتابة نوع خدمتك بالتحديد.'), findsOneWidget);
      expect(backend.callsTo('PATCH /services/100'), 0);
    });

    testWidgets('a backend refusal is shown and the screen stays', (tester) async {
      final backend = _backend(extra: {
        'PATCH /services/100': const Reply({'detail': 'You can only edit your own services'}, status: 403),
      });
      await _open(tester, backend);

      await _save(tester);

      expect(find.text('You can only edit your own services'), findsOneWidget);
      expect(find.byType(EditServiceScreen), findsOneWidget);
    });
  });

  group('validation', () {
    testWidgets('rejects a short description and a bad (non-empty) price', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(_descriptionField, 'short');
      await _save(tester);
      expect(find.text('الوصف يجب أن يتكون من 10 أحرف على الأقل.'), findsOneWidget);
      await clearSnackBars(tester);

      await tester.enterText(_descriptionField, 'I fix all kinds of pipes');
      await tester.enterText(_priceField, '0');
      await _save(tester);
      expect(find.text('يرجى إدخال سعر صحيح، أو اترك حقل السعر فارغاً.'), findsOneWidget);

      expect(backend.callsTo('PATCH /services/100'), 0);
    });
  });

  group('cover photo', () {
    testWidgets('a new photo is uploaded and its URL sent', (tester) async {
      final backend = _backend();
      final picker = FakeImagePicker(fakeImageFile());
      await _open(tester, backend, picker: picker);

      await tester.tap(find.text('أضف صورة غلاف'));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(backend.callsTo('POST /uploads/image'), 1);
      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('cover_image_url', '/uploads/new-cover.png'));
    });

    testWidgets('an upload failure aborts the save', (tester) async {
      final backend = _backend(extra: {
        'POST /uploads/image': const Reply({'detail': 'File too large'}, status: 413),
      });
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.text('أضف صورة غلاف'));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(find.text('File too large'), findsOneWidget);
      expect(backend.callsTo('PATCH /services/100'), 0);
    });
  });

  group('location', () {
    testWidgets('updating the location sends the new coordinates', (tester) async {
      final backend = _backend();
      await _open(tester, backend, gps: FakeLocationService(position: fakePosition(lat: 34.0, lon: 36.0)));

      await tester.tap(find.text('استخدم موقعي'));
      await tester.pumpAndSettle();
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('latitude', 34.0));
      expect(backend.lastBodyOf('PATCH /services/100'), containsPair('longitude', 36.0));
    });

    testWidgets('a location failure is shown', (tester) async {
      await _open(
        tester,
        _backend(),
        gps: FakeLocationService(error: LocationServiceException('خدمة الموقع مطفية')),
      );

      await tester.tap(find.text('استخدم موقعي'));
      await tester.pumpAndSettle();

      expect(find.text('خدمة الموقع مطفية'), findsOneWidget);
    });
  });

  group('working hours when switching to an on-site service', () {
    final noHours = {'GET /providers/1/availability': const Reply([])};

    testWidgets('the gate asks no /users/me and checks the right provider',
        (tester) async {
      // The same gate reached from this screen: a revert to /users/me
      // shows up as a request, a wrong id as the wrong provider route.
      final backend = _backend(detail: _detail(remote: true), extra: noHours);
      await _open(tester, backend);

      await tester.tap(_remoteSwitch());
      await tester.pump();
      await _save(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsOneWidget);
      expect(backend.callsTo('GET /users/me'), 0);
      expect(backend.callsTo('GET /providers/1/availability'), greaterThan(0));
    });

    testWidgets('remote -> on-site without hours asks to set them first', (tester) async {
      final backend = _backend(detail: _detail(remote: true), extra: noHours);
      await _open(tester, backend);

      await tester.tap(_remoteSwitch());        // turn "remote" off
      await tester.pump();
      await _save(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsOneWidget);
      expect(backend.callsTo('PATCH /services/100'), 0);
    });

    testWidgets('after saving the hours the change goes through', (tester) async {
      final backend = _backend(detail: _detail(remote: true), extra: noHours);
      await _open(tester, backend);
      await tester.tap(_remoteSwitch());
      await tester.pump();
      await _save(tester);

      await tester.tap(find.widgetWithText(TextButton, 'تحديد الدوام'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SAVE HOURS'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('PATCH /services/100'), 1);
      expect(backend.lastBodyOf('PATCH /services/100')['is_remote'], false);
    });

    testWidgets('remote -> on-site with hours already set just saves', (tester) async {
      final backend = _backend(detail: _detail(remote: true));
      await _open(tester, backend);
      await tester.tap(_remoteSwitch());
      await tester.pump();

      await _save(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsNothing);
      expect(backend.callsTo('PATCH /services/100'), 1);
    });

    testWidgets('editing a service that is already on-site never asks', (tester) async {
      final backend = _backend(detail: _detail(remote: false), extra: noHours);
      await _open(tester, backend);

      await _save(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsNothing);
      expect(backend.callsTo('PATCH /services/100'), 1);
      expect(backend.callsTo('GET /providers/1/availability'), 0);
    });

    testWidgets('a service that stays remote never asks', (tester) async {
      final backend = _backend(detail: _detail(remote: true), extra: noHours);
      await _open(tester, backend);

      await _save(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsNothing);
      expect(backend.callsTo('PATCH /services/100'), 1);
    });
  });
}
