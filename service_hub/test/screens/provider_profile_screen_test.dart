import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/profile/data/public_profile_service.dart';
import 'package:service_hub/features/profile/provider_profile_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/service/data/portfolio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _provider({String? phone = '0912345678', String? bio = 'Plumber for 10 years', String? city = 'Damascus'}) =>
    {
      'id': 10,
      'is_provider': true,
      'profile': {
        'full_name': 'Ahmad Ali',
        'avatar_url': null,
        'city': city,
        'bio': bio,
        'phone_number': phone,
      },
    };

Map<String, dynamic> _service(int id, String title) => serviceListItemJson(id: id, price: '30')..['title'] = title;

Map<String, dynamic> _photo(int id) => {'id': id, 'image_url': '/uploads/p$id.jpg', 'caption': null, 'display_order': 0};

RoutedBackend _backend({
  Map<String, dynamic>? provider,
  List<Map<String, dynamic>>? services,
  List<Map<String, dynamic>> photos = const [],
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/10': Reply(provider ?? _provider()),
      'GET /services/provider/10': Reply(services ?? [_service(100, 'Fix pipes')]),
      'GET /services/100/portfolio': Reply(photos),
      ...extra,
    });

Future<List<Uri>> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  bool launchSucceeds = true,
  String? title,
}) async {
  useTallScreen(tester);
  final launched = <Uri>[];
  final api = apiFor(backend);
  await tester.pumpWidget(MaterialApp(
    home: ProviderProfileScreen(
      providerId: 10,
      title: title ?? 'ملف المزوّد',
      publicProfileService: PublicProfileService(apiClient: api),
      catalogService: CatalogService(apiClient: api),
      portfolioService: PortfolioService(apiClient: api),
      detailsBuilder: (id) => Scaffold(appBar: AppBar(), body: Text('DETAILS $id')),
      urlLauncher: (uri) async {
        launched.add(uri);
        return launchSucceeds;
      },
    ),
  ));
  await tester.pumpAndSettle();
  return launched;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the provider\'s public details', (tester) async {
    await _open(tester, _backend());

    expect(find.text('ملف المزوّد'), findsOneWidget);
    expect(find.text('Ahmad Ali'), findsOneWidget);
    expect(find.text('Damascus'), findsOneWidget);
    expect(find.text('Plumber for 10 years'), findsOneWidget);
  });

  testWidgets('placeholders for a missing bio and city', (tester) async {
    await _open(tester, _backend(provider: _provider(bio: null, city: null)));

    expect(find.text('لا توجد نبذة بعد.'), findsOneWidget);
    expect(find.byIcon(Icons.location_on), findsNothing);
  });

  testWidgets('shows the error when the profile cannot be loaded', (tester) async {
    await _open(
      tester,
      _backend(extra: {'GET /users/10': const Reply({'detail': 'User not found'}, status: 404)}),
    );
    expect(find.text('User not found'), findsOneWidget);
  });

  group('services', () {
    testWidgets('lists the provider\'s services with prices', (tester) async {
      await _open(tester, _backend(services: [_service(1, 'Fix pipes'), _service(2, 'Paint walls')]));

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('Paint walls'), findsOneWidget);
      expect(find.text('30.00 \$'), findsNWidgets(2));
    });

    testWidgets('empty services message', (tester) async {
      await _open(tester, _backend(services: []));
      expect(find.text('لم تُنشر أي خدمات بعد.'), findsOneWidget);
    });

    testWidgets('a failure loading services is shown', (tester) async {
      await _open(
        tester,
        _backend(extra: {'GET /services/provider/10': const Reply({'detail': 'services down'}, status: 500)}),
      );
      expect(find.text('services down'), findsOneWidget);
    });

    testWidgets('tapping a service opens its details', (tester) async {
      await _open(tester, _backend(services: [_service(77, 'Fix pipes')]));

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();

      expect(find.text('DETAILS 77'), findsOneWidget);
    });
  });

  group('previous work', () {
    testWidgets('empty message', (tester) async {
      await _open(tester, _backend());
      expect(find.text('لا توجد صور أعمال سابقة بعد.'), findsOneWidget);
    });

    testWidgets('combines the photos of every service in one grid', (tester) async {
      final backend = _backend(
        services: [_service(100, 'Fix pipes'), _service(101, 'Paint walls')],
        photos: [_photo(1), _photo(2)],
        extra: {'GET /services/101/portfolio': Reply([_photo(3)])},
      );
      await _open(tester, backend);

      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(Image), findsNWidgets(3));
    });

    testWidgets('a service whose gallery fails does not hide the others', (tester) async {
      final backend = _backend(
        services: [_service(100, 'Fix pipes'), _service(101, 'Paint walls')],
        photos: [_photo(1)],
        extra: {'GET /services/101/portfolio': const Reply({'detail': 'x'}, status: 500)},
      );
      await _open(tester, backend);

      expect(find.byType(Image), findsNWidgets(1));
    });
  });

  group('WhatsApp', () {
    testWidgets('is offered when the phone number is valid', (tester) async {
      await _open(tester, _backend());
      expect(find.text('راسله على واتساب'), findsOneWidget);
    });

    testWidgets('is hidden without a phone or with an unusable one', (tester) async {
      await _open(tester, _backend(provider: _provider(phone: null)));
      expect(find.text('راسله على واتساب'), findsNothing);
    });

    testWidgets('is hidden for numbers that cannot be normalised', (tester) async {
      await _open(tester, _backend(provider: _provider(phone: '12')));
      expect(find.text('راسله على واتساب'), findsNothing);
    });

    testWidgets('opens wa.me with the number in international format', (tester) async {
      final launched = await _open(tester, _backend());

      await tester.tap(find.text('راسله على واتساب'));
      await tester.pumpAndSettle();

      expect(launched, [Uri.parse('https://wa.me/963912345678')]);
    });

    testWidgets('reports when WhatsApp cannot be opened', (tester) async {
      await _open(tester, _backend(), launchSucceeds: false);

      await tester.tap(find.text('راسله على واتساب'));
      await pumpFrames(tester);

      expect(find.text("تعذّر فتح واتساب."), findsOneWidget);
    });
  });

  group('phone number', () {
    testWidgets('is shown as selectable text, above the WhatsApp button', (tester) async {
      await _open(tester, _backend());

      expect(find.byKey(const Key('provider-phone')), findsOneWidget);
      expect(find.text('0912345678'), findsOneWidget);
      final phoneY = tester.getTopLeft(find.byKey(const Key('provider-phone'))).dy;
      final buttonY = tester.getTopLeft(find.text('راسله على واتساب')).dy;
      expect(phoneY, lessThan(buttonY));
    });

    testWidgets('is shown even when WhatsApp cannot be offered for it', (tester) async {
      await _open(tester, _backend(provider: _provider(phone: '12')));

      expect(find.text('12'), findsOneWidget);
      expect(find.text('راسله على واتساب'), findsNothing);
    });

    testWidgets('is hidden when there is none', (tester) async {
      await _open(tester, _backend(provider: _provider(phone: null)));
      expect(find.byKey(const Key('provider-phone')), findsNothing);

      await _open(tester, _backend(provider: _provider(phone: '   ')));
      expect(find.byKey(const Key('provider-phone')), findsNothing);
    });

    testWidgets('the copy button puts it on the clipboard and confirms', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await _open(tester, _backend());

      await tester.tap(find.byTooltip('نسخ الرقم'));
      await pumpFrames(tester);

      expect(copied, ['0912345678']);
      expect(find.text('تم نسخ الرقم.'), findsOneWidget);
    });
  });

  testWidgets('the app-bar title can be changed (customer profiles)', (tester) async {
    await _open(tester, _backend(), title: 'ملف العميل');

    expect(find.text('ملف العميل'), findsOneWidget);
    expect(find.text('ملف المزوّد'), findsNothing);
  });
}
