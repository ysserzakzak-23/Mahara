import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/theme/app_theme.dart';
import 'package:service_hub/shared/widgets/category_picker_field.dart';
import 'package:service_hub/core/api/upload_service.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/core/location/location_service.dart';
import 'package:service_hub/features/service/add_service_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/core/utils/error_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _created() => {
      'id': 100,
      'title': null,
      'display_title': 'سباكة',
      'description': 'I fix all kinds of pipes',
      'price': '25.50',
      'price_unit': 'fixed',
      'status': 'active',
      'category': categoryJson(),
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

Map<String, dynamic> _workingWindow({bool active = true}) => {
      'id': 1,
      'day_of_week': 0,
      'start_time': '09:00:00',
      'end_time': '17:00:00',
      'is_active': active,
    };

/// By default the provider already has working hours (so nothing is asked).
RoutedBackend _backend({Map<String, Reply> extra = const {}}) => RoutedBackend({
      'GET /users/me': Reply(_me()),
      'GET /providers/1/availability': Reply([_workingWindow()]),
      'GET /categories': Reply([
        categoryJson(id: 9, name: 'أخرى', isOther: true),
        categoryJson(id: 1, name: 'سباكة'),
        categoryJson(id: 2, name: 'كهرباء'),
      ]),
      'POST /services': Reply(_created(), status: 201),
      'POST /uploads/image': const Reply({'url': '/uploads/cover.png'}),
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
    (_) => AddServiceScreen(
      tokenStore: store,
      availabilityService: AvailabilityService(apiClient: api),
      availabilityScreenBuilder: (id) => Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('شاشة الدوام')),
          body: ElevatedButton(
            onPressed: () {
              // pretend the provider saved a window on the hours screen
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

Finder _field(String hint) => find.widgetWithText(TextField, hint);

const _priceHint = 'السعر (اختياري) (\$)';

Future<void> _fill(
  WidgetTester tester, {
  String description = 'I fix all kinds of pipes',
  String price = '25.5',
}) async {
  await tester.enterText(_field('الوصف'), description);
  await tester.enterText(_field(_priceHint), price);
}

Future<void> _chooseCategory(WidgetTester tester, String name) async {
  await tester.tap(find.byType(CategoryPickerField));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

Future<void> _publish(WidgetTester tester) async {
  await tester.tap(find.text('نشر الخدمة'));
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

  testWidgets('shows the empty form', (tester) async {
    await _open(tester, _backend());

    expect(find.text('إضافة خدمة'), findsOneWidget);
    expect(find.text('أضف صورة غلاف'), findsOneWidget);
    expect(find.text('استخدم موقعي'), findsOneWidget);
    expect(find.text('تُقدَّم عن بُعد / أونلاين'), findsOneWidget);
  });

  testWidgets('a categories failure is shown in place of the dropdown', (tester) async {
    await _open(tester, _backend(extra: {'GET /categories': const Reply({'detail': 'boom'}, status: 500)}));

    expect(find.text('تعذّر تحميل التصنيفات: boom'), findsOneWidget);
    expect(find.byType(CategoryPickerField), findsNothing);
  });

  testWidgets('"أخرى" is listed last and reveals a free-text field', (tester) async {
    await _open(tester, _backend());

    await tester.tap(find.byType(CategoryPickerField));
    await tester.pumpAndSettle();
    double y(String t) => tester.getTopLeft(find.text(t).last).dy;
    expect(y('كهرباء'), lessThan(y('أخرى')));

    await tester.tap(find.text('أخرى').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, "ما نوع خدمتك؟ (مثل: سباك)"), findsOneWidget);
  });

  group('form layout', () {
    testWidgets('there is no service-name field any more', (tester) async {
      await _open(tester, _backend());

      expect(_field('اسم الخدمة'), findsNothing);
      expect(find.text('اسم الخدمة'), findsNothing);
      // Exactly the description and the price (no hidden extra text field).
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('the order is category, description, then the optional price',
        (tester) async {
      await _open(tester, _backend());

      final category = tester.getTopLeft(find.byType(CategoryPickerField)).dy;
      final description = tester.getTopLeft(_field('الوصف')).dy;
      final price = tester.getTopLeft(_field(_priceHint)).dy;
      expect(category, lessThan(description));
      expect(description, lessThan(price));
      // The category took the name field's place: it is the first input.
      expect(category, lessThan(tester.getTopLeft(find.text('أضف صورة غلاف')).dy));
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final size in const [Size(390, 844), Size(320, 640)]) {
        testWidgets(
            '${mode.name} ${size.width.toInt()}px: price and its unit side by side, same box',
            (tester) async {
          await _open(tester, _backend(), themeMode: mode, size: size);
          expectPriceAndUnitSideBySide(tester, screenWidth: size.width);
          expect(find.text('سعر ثابت'), findsOneWidget); // the default unit shows
        });
      }
    }

    testWidgets('the «أخرى» label field sits right under the category', (tester) async {
      await _open(tester, _backend());
      await _chooseCategory(tester, 'أخرى');

      final label = tester.getTopLeft(find.widgetWithText(TextField, "ما نوع خدمتك؟ (مثل: سباك)")).dy;
      expect(tester.getTopLeft(find.byType(CategoryPickerField)).dy, lessThan(label));
      expect(label, lessThan(tester.getTopLeft(_field('الوصف')).dy));
    });
  });

  group('validation', () {
    testWidgets('category, description, price - in that order', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await _publish(tester);
      expect(find.text('يرجى اختيار التصنيف.'), findsOneWidget);
      await clearSnackBars(tester);

      await _chooseCategory(tester, 'سباكة');
      await _publish(tester);
      expect(find.text('الوصف يجب أن يتكون من 10 أحرف على الأقل.'), findsOneWidget);
      await clearSnackBars(tester);

      await tester.enterText(_field('الوصف'), 'I fix all kinds of pipes');
      await tester.enterText(_field(_priceHint), 'abc');
      await _publish(tester);
      expect(find.text('يرجى إدخال سعر صحيح، أو اترك حقل السعر فارغاً.'), findsOneWidget);

      expect(backend.callsTo('POST /services'), 0);
    });

    for (final bad in ['0', '-5', 'abc', '1.234']) {
      testWidgets('rejects the price "$bad"', (tester) async {
        final backend = _backend();
        await _open(tester, backend);
        await _fill(tester, price: bad);
        await _chooseCategory(tester, 'سباكة');

        await _publish(tester);

        expect(find.text('يرجى إدخال سعر صحيح، أو اترك حقل السعر فارغاً.'), findsOneWidget);
        expect(backend.callsTo('POST /services'), 0);
      });
    }

    testWidgets('"أخرى" needs a description of the service', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'أخرى');

      await _publish(tester);

      expect(find.text('يرجى كتابة نوع خدمتك بالتحديد.'), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
    });
  });

  group('publishing', () {
    testWidgets('sends the form and closes the screen', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await _publish(tester);

      expect(backend.lastBodyOf('POST /services'), {
        'category_id': 1,
        'description': 'I fix all kinds of pipes',
        'price': 25.5,
        'price_unit': 'fixed',
        'is_remote': false,
      });
      expect(find.text('تم نشر الخدمة!'), findsOneWidget);
      expect(find.byType(AddServiceScreen), findsNothing);
    });

    testWidgets('a unit chosen in the side-by-side field is sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend, themeMode: ThemeMode.light);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await tester.tap(find.byKey(const Key('price-unit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('بالساعة').last);
      await tester.pumpAndSettle();
      expect(find.text('بالساعة'), findsOneWidget);

      await _publish(tester);
      expect(backend.lastBodyOf('POST /services'), containsPair('price_unit', 'per_hour'));
      expect(backend.lastBodyOf('POST /services'), containsPair('price', 25.5));
    });

    for (final empty in ['', '   ']) {
      testWidgets('without a price ("$empty") it publishes and sends no price (not 0)',
          (tester) async {
        final backend = _backend();
        await _open(tester, backend);
        await _fill(tester, price: empty);
        await _chooseCategory(tester, 'سباكة');

        await _publish(tester);

        final body = backend.lastBodyOf('POST /services');
        expect(backend.callsTo('POST /services'), 1);
        expect(body.containsKey('price'), isFalse);
        expect(body.containsKey('title'), isFalse);
        expect(body['category_id'], 1);
        expect(find.text('تم نشر الخدمة!'), findsOneWidget);
      });
    }

    testWidgets('a price typed with Arabic digits is sent as a number', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester, price: '٢٥٫٥');
      await _chooseCategory(tester, 'سباكة');

      await _publish(tester);

      expect(backend.lastBodyOf('POST /services')['price'], 25.5);
    });

    testWidgets('the remote switch is sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');
      await tester.tap(find.byType(Switch));
      await tester.pump();

      await _publish(tester);

      expect(backend.lastBodyOf('POST /services')['is_remote'], true);
    });

    testWidgets('"أخرى" sends the trimmed custom label', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'أخرى');
      await tester.enterText(find.widgetWithText(TextField, "ما نوع خدمتك؟ (مثل: سباك)"), '  سباك  ');

      await _publish(tester);

      expect(backend.lastBodyOf('POST /services'),
          containsPair('custom_category_label', 'سباك'));
    });

    testWidgets('a backend refusal is shown and the form stays open', (tester) async {
      final backend = _backend(extra: {
        'POST /services': const Reply({'detail': 'Service category not found'}, status: 404),
      });
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await _publish(tester);

      expect(find.text('Service category not found'), findsOneWidget);
      expect(find.byType(AddServiceScreen), findsOneWidget);
    });
  });

  group('cover photo', () {
    testWidgets('a chosen photo replaces the placeholder and is uploaded on publish',
        (tester) async {
      final backend = _backend();
      final picker = FakeImagePicker(fakeImageFile(name: 'cover.png'));
      await _open(tester, backend, picker: picker);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await tester.tap(find.text('أضف صورة غلاف'));
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(find.text('أضف صورة غلاف'), findsNothing);

      await _publish(tester);

      expect(backend.callsTo('POST /uploads/image'), 1);
      expect(backend.lastBodyOf('POST /services'), containsPair('cover_image_url', '/uploads/cover.png'));
    });

    testWidgets('cancelling the gallery changes nothing', (tester) async {
      final picker = FakeImagePicker(null);
      await _open(tester, _backend(), picker: picker);

      await tester.tap(find.text('أضف صورة غلاف'));
      await tester.pumpAndSettle();

      expect(find.text('أضف صورة غلاف'), findsOneWidget);
    });

    testWidgets('an upload failure is shown and nothing is published', (tester) async {
      final backend = _backend(extra: {
        'POST /uploads/image': const Reply({'detail': 'Unsupported image type'}, status: 400),
      });
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');
      await tester.tap(find.text('أضف صورة غلاف'));
      await tester.pumpAndSettle();

      await _publish(tester);

      expect(find.text('Unsupported image type'), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
    });
  });

  group('location', () {
    testWidgets('"استخدم موقعي" stores the coordinates and sends them', (tester) async {
      final backend = _backend();
      await _open(tester, backend, gps: FakeLocationService(position: fakePosition(lat: 33.5, lon: 36.3)));
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await tester.tap(find.text('استخدم موقعي'));
      await tester.pumpAndSettle();

      expect(find.text('تم تحديد الموقع — ستظهر هذه الخدمة في البحث عن الخدمات القريبة.'), findsOneWidget);
      expect(find.text('تحديث'), findsOneWidget);

      await _publish(tester);
      expect(backend.lastBodyOf('POST /services'), containsPair('latitude', 33.5));
      expect(backend.lastBodyOf('POST /services'), containsPair('longitude', 36.3));
    });

    testWidgets('without a location the listing carries no coordinates', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');

      await _publish(tester);

      expect(backend.lastBodyOf('POST /services').containsKey('latitude'), isFalse);
    });

    testWidgets('shows the reason when the location cannot be obtained', (tester) async {
      await _open(
        tester,
        _backend(),
        gps: FakeLocationService(error: LocationServiceException('لازم تسمح للتطبيق بالوصول لموقعك')),
      );

      await tester.tap(find.text('استخدم موقعي'));
      await tester.pumpAndSettle();

      expect(find.text('لازم تسمح للتطبيق بالوصول لموقعك'), findsOneWidget);
      expect(find.text('استخدم موقعي'), findsOneWidget);
    });
  });

  group('working hours before an on-site listing', () {
    RoutedBackend noHours() => _backend(extra: {
          'GET /providers/1/availability': const Reply([]),
        });

    Future<void> fillForm(WidgetTester tester, {bool remote = false}) async {
      await _fill(tester);
      await _chooseCategory(tester, 'سباكة');
      if (remote) {
        await tester.tap(find.byType(Switch));
        await tester.pump();
      }
    }

    testWidgets('an on-site service with no hours first asks the provider to set them',
        (tester) async {
      final backend = noHours();
      await _open(tester, backend);
      await fillForm(tester);

      await _publish(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
    });

    testWidgets('cancelling the question publishes nothing', (tester) async {
      final backend = noHours();
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /services'), 0);
      expect(find.byType(AddServiceScreen), findsOneWidget);
    });

    testWidgets('once the hours are saved the service is published automatically',
        (tester) async {
      final backend = noHours();
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      await tester.tap(find.widgetWithText(TextButton, 'تحديد الدوام'));
      await tester.pumpAndSettle();
      expect(find.text('شاشة الدوام'), findsOneWidget);
      await tester.tap(find.text('SAVE HOURS'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /services'), 1);
      expect(find.text('تم نشر الخدمة!'), findsOneWidget);
    });

    testWidgets('leaving the hours screen without saving anything blocks publishing',
        (tester) async {
      final backend = noHours();
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      await tester.tap(find.widgetWithText(TextButton, 'تحديد الدوام'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('لم تحدد أي دوام، لا يمكن نشر خدمة غير عن بعد بدونه.'), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
    });

    testWidgets('a remote service needs no hours at all', (tester) async {
      final backend = noHours();
      await _open(tester, backend);
      await fillForm(tester, remote: true);

      await _publish(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsNothing);
      expect(backend.callsTo('POST /services'), 1);
      expect(backend.callsTo('GET /providers/1/availability'), 0);
    });

    testWidgets('with hours already set, publishing asks nothing (only the first listing asks)',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await fillForm(tester);

      await _publish(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsNothing);
      expect(backend.callsTo('POST /services'), 1);
    });

    testWidgets('switched-off windows count as no hours', (tester) async {
      final backend = _backend(extra: {
        'GET /providers/1/availability': Reply([_workingWindow(active: false)]),
      });
      await _open(tester, backend);
      await fillForm(tester);

      await _publish(tester);

      expect(find.text('تحديد أيام وساعات الدوام'), findsOneWidget);
    });

    testWidgets('the provider id comes from the token, not from /users/me',
        (tester) async {
      // The gate used to fetch the whole profile to learn whose hours to
      // check. A revert would show up twice here: as a /users/me request,
      // and as the wrong provider's availability being asked for.
      final backend = _backend();
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      expect(backend.callsTo('GET /users/me'), 0);
      expect(backend.callsTo('GET /providers/1/availability'), 1);
      expect(backend.callsTo('POST /services'), 1);
    });

    testWidgets('it checks the hours of whoever the token says I am',
        (tester) async {
      // A different signed-in provider: the gate must follow the token.
      SharedPreferences.setMockInitialValues({'access_token': tokenFor(7)});
      final backend = _backend(extra: {
        'GET /providers/7/availability': Reply([_workingWindow()]),
      });
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      expect(backend.callsTo('GET /providers/7/availability'), 1);
      expect(backend.callsTo('GET /providers/1/availability'), 0);
      expect(backend.callsTo('GET /users/me'), 0);
    });

    testWidgets('an unreadable token fails the check and publishes nothing',
        (tester) async {
      // Nothing is guessed: the gate reports the generic error and stops.
      SharedPreferences.setMockInitialValues({'access_token': 'not-a-jwt'});
      final backend = _backend();
      await _open(tester, backend);
      await fillForm(tester);
      await _publish(tester);

      expect(find.text(genericErrorText), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
      expect(backend.callsTo('GET /users/me'), 0);
      // No availability request either - there was no id to ask about.
      expect(backend.callsTo('GET /providers/1/availability'), 0);
    });

    testWidgets('a failure while checking is shown and nothing is published', (tester) async {
      // Was a 401 on /users/me, which the gate no longer calls: it reads
      // the provider's id from the token, so a refused session surfaces on
      // the working-hours request it does make.
      final backend = _backend(extra: {
        'GET /providers/1/availability':
            const Reply({'detail': 'انتهت الجلسة'}, status: 401),
      });
      await _open(tester, backend);
      await fillForm(tester);

      await _publish(tester);

      expect(find.text('انتهت الجلسة'), findsOneWidget);
      expect(backend.callsTo('POST /services'), 0);
      expect(backend.callsTo('GET /users/me'), 0);
    });
  });
}
