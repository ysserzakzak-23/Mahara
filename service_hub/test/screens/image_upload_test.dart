// What the app asks the gallery for, and what it then uploads (audit C2).
//
// Every photo the user picks is capped at [maxUploadImageDimension] on its
// longest side. The picker itself does the resizing on the device: it keeps
// the aspect ratio, never enlarges a smaller photo, and copies the EXIF
// data, so these tests check the limits the screens ask for, and that the
// upload that follows is unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/upload_service.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/core/utils/image_sizing.dart';
import 'package:service_hub/features/auth/data/auth_models.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/data/city_service.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/features/profile/edit_profile_screen.dart';
import 'package:service_hub/features/service/add_service_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/service/data/portfolio_service.dart';
import 'package:service_hub/features/service/edit_service_screen.dart';
import 'package:service_hub/features/service/service_portfolio_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _me = {
  'id': 1,
  'email': 'p@example.com',
  'role': 'user',
  'is_provider': true,
  'is_active': true,
  'profile': {'full_name': 'Provider', 'phone_number': '0912345678', 'city': 'دمشق'},
};

Map<String, dynamic> _window() => {
      'id': 1,
      'day_of_week': 0,
      'start_time': '09:00:00',
      'end_time': '17:00:00',
      'is_active': true,
    };

Map<String, dynamic> _serviceDetail() => serviceListItemJson(id: 100)
  ..['description'] = 'I fix all kinds of pipes'
  ..['latitude'] = null
  ..['longitude'] = null
  ..['cover_image_url'] = null;

RoutedBackend _backend({Map<String, Reply> extra = const {}}) => RoutedBackend({
      'GET /users/me': const Reply(_me),
      'GET /cities': const Reply(['دمشق']),
      'GET /providers/1/availability': Reply([_window()]),
      'GET /categories': Reply([categoryJson(id: 1, name: 'سباكة')]),
      'GET /services/100': Reply(_serviceDetail()),
      'GET /services/100/portfolio': const Reply([]),
      'POST /uploads/image': const Reply({'url': '/uploads/new.png'}),
      'POST /services/100/portfolio': Reply({
        'id': 9, 'service_id': 100, 'image_url': '/uploads/new.png',
        'caption': null, 'display_order': 0,
      }, status: 201),
      ...extra,
    });

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

  /// Every screen that lets the user pick a photo, with the quality it has
  /// always asked for, and how the photo is chosen on that screen.
  final screens = <({
    String name,
    int quality,
    Widget Function(RoutedBackend backend, FakeImagePicker picker) build,
    Future<void> Function(WidgetTester tester) pick,
  })>[
    (
      name: 'service cover (add)',
      quality: 85,
      build: (backend, picker) {
        final store = TokenStore();
        final api = apiFor(backend, tokenStore: store);
        return AddServiceScreen(
          tokenStore: store,
          availabilityService: AvailabilityService(apiClient: api),
          catalogService: CatalogService(apiClient: api),
          uploadService: UploadService(apiClient: api),
          imagePicker: picker,
          locationService: FakeLocationService(),
        );
      },
      pick: (tester) async {
        await tester.tap(find.text('أضف صورة غلاف'));
        await tester.pumpAndSettle();
      },
    ),
    (
      name: 'service cover (edit)',
      quality: 85,
      build: (backend, picker) {
        final store = TokenStore();
        final api = apiFor(backend, tokenStore: store);
        return EditServiceScreen(
          serviceId: 100,
          tokenStore: store,
          availabilityService: AvailabilityService(apiClient: api),
          catalogService: CatalogService(apiClient: api),
          uploadService: UploadService(apiClient: api),
          imagePicker: picker,
          locationService: FakeLocationService(),
        );
      },
      pick: (tester) async {
        await tester.tap(find.text('أضف صورة غلاف'));
        await tester.pumpAndSettle();
      },
    ),
    (
      name: 'profile avatar',
      quality: 80,
      build: (backend, picker) {
        final store = TokenStore();
        final api = apiFor(backend, tokenStore: store);
        return EditProfileScreen(
          user: AppUser.fromJson(_me),
          authService: AuthService(apiClient: api, tokenStore: store),
          uploadService: UploadService(apiClient: api),
          cityService: CityService(apiClient: api),
          imagePicker: picker,
        );
      },
      pick: (tester) async {
        await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
        await tester.pumpAndSettle();
      },
    ),
    (
      name: 'portfolio photo',
      quality: 85,
      build: (backend, picker) {
        final api = apiFor(backend);
        return ServicePortfolioScreen(
          serviceId: 100,
          serviceTitle: 'Fix pipes',
          portfolioService: PortfolioService(apiClient: api),
          uploadService: UploadService(apiClient: api),
          imagePicker: picker,
        );
      },
      pick: (tester) async {
        await tester.tap(find.byIcon(Icons.add_a_photo));
        await tester.pumpAndSettle();
      },
    ),
  ];

  for (final screen in screens) {
    group(screen.name, () {
      testWidgets('asks the gallery for a photo capped at 1600 px', (tester) async {
        final picker = FakeImagePicker(fakeImageFile());
        useTallScreen(tester);
        await tester.pumpWidget(MaterialApp(home: screen.build(_backend(), picker)));
        await tester.pumpAndSettle();

        await screen.pick(tester);

        expect(picker.calls, 1);
        expect(picker.maxWidth, maxUploadImageDimension.toDouble());
        expect(picker.maxHeight, maxUploadImageDimension.toDouble());
        // Both sides carry the same cap, so the picker scales by whichever
        // side needs it and the aspect ratio is kept.
        expect(picker.maxWidth, picker.maxHeight);
      });

      testWidgets('still asks for the same quality as before', (tester) async {
        final picker = FakeImagePicker(fakeImageFile());
        useTallScreen(tester);
        await tester.pumpWidget(MaterialApp(home: screen.build(_backend(), picker)));
        await tester.pumpAndSettle();

        await screen.pick(tester);

        expect(picker.imageQuality, screen.quality);
      });

      testWidgets('cancelling the picker uploads nothing', (tester) async {
        final backend = _backend();
        final picker = FakeImagePicker(null);        // the user backed out
        useTallScreen(tester);
        await tester.pumpWidget(MaterialApp(home: screen.build(backend, picker)));
        await tester.pumpAndSettle();

        await screen.pick(tester);

        expect(picker.calls, 1);
        expect(backend.callsTo('POST /uploads/image'), 0);
      });
    });
  }

  group('the upload itself is unchanged', () {
    testWidgets('a picked photo is uploaded with its bytes, name and token',
        (tester) async {
      final backend = _backend();
      final picker = FakeImagePicker(fakeImageFile());
      useTallScreen(tester);
      await tester.pumpWidget(MaterialApp(
        home: screens.last.build(backend, picker),      // the portfolio screen
      ));
      await tester.pumpAndSettle();

      await screens.last.pick(tester);
      await pumpFrames(tester);

      expect(backend.callsTo('POST /uploads/image'), 1);
      final request = backend.requests.firstWhere(
        (r) => r.url.path.endsWith('/uploads/image'),
      );
      expect(request.headers['content-type'], startsWith('multipart/form-data'));
      // Phase 2 intact: still the stored access token, verbatim. (The
      // stored value is now a real-shaped JWT because the working-hours
      // gate reads the provider id out of it.)
      expect(request.headers['Authorization'], 'Bearer ${tokenFor(1)}');
      final body = String.fromCharCodes(request.bodyBytes);
      expect(body, contains('name="file"'));
      // The part carries the photo's own type, which is what the backend
      // checks (a resized PNG is still a PNG).
      expect(body, contains('content-type: image/png'));
      expect(request.bodyBytes.length, greaterThan(kPngBytes.length));
    });

    testWidgets('an upload failure is reported and nothing is saved', (tester) async {
      final backend = _backend(extra: {
        'POST /uploads/image': const Reply({'detail': 'File too large'}, status: 413),
      });
      final picker = FakeImagePicker(fakeImageFile());
      useTallScreen(tester);
      await tester.pumpWidget(MaterialApp(home: screens.last.build(backend, picker)));
      await tester.pumpAndSettle();

      await screens.last.pick(tester);
      await pumpFrames(tester);

      expect(find.text('File too large'), findsOneWidget);
      expect(backend.callsTo('POST /services/100/portfolio'), 0);
    });
  });
}
