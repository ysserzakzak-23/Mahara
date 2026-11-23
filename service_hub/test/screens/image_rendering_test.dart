// The screens that show uploaded photos decode them at the size they are
// drawn (audit C2), and still look and behave as they did.
//
// A decoded image costs width x height x 4 bytes whatever size it is drawn
// at, so these assertions are about memory, not layout.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/data/city_service.dart';
import 'package:service_hub/features/home/home_screen.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/profile/data/public_profile_service.dart';
import 'package:service_hub/features/profile/provider_profile_screen.dart';
import 'package:service_hub/core/utils/image_sizing.dart';
import 'package:service_hub/features/search/search_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/features/reviews/data/review_service.dart';
import 'package:service_hub/features/service/data/portfolio_service.dart';
import 'package:service_hub/features/service/service_details_screen.dart';
import 'package:service_hub/shared/widgets/full_screen_image_viewer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

/// A 1x1 transparent PNG: lets network images in these tests load instead
/// of erroring, without reaching any server.
final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Serves [_pixel] for every image request made by the widgets under test.
class _PixelHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FakeHttpClient();
}

class _FakeHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeHttpRequest(url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _FakeHttpRequest(url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpRequest implements HttpClientRequest {
  _FakeHttpRequest(this.uri);

  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeHttpResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpResponse implements HttpClientResponse {
  @override
  int statusCode = 200;
  @override
  int get contentLength => _pixel.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      Stream<List<int>>.value(_pixel)
          .listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// --------------------------------------------------------------- fixtures
Map<String, dynamic> _user({String? avatar = '/uploads/me.jpg'}) => {
      'id': 10,
      'email': 'ahmad@example.com',
      'role': 'user',
      'is_provider': true,
      'is_active': true,
      'profile': {'full_name': 'Ahmad Ali', 'avatar_url': avatar},
    };

Map<String, dynamic> _service({String? cover = '/uploads/cover.jpg', int id = 100}) =>
    serviceListItemJson(id: id)..['cover_image_url'] = cover;

Map<String, dynamic> _serviceDetail() => serviceListItemJson(id: 100)
  ..['description'] = 'I fix all kinds of pipes'
  ..['cover_image_url'] = '/uploads/cover.jpg'
  ..['latitude'] = null
  ..['longitude'] = null;

/// The ResizeImage behind a [CircleAvatar] / [DecorationImage] provider.
ResizeImage resized(ImageProvider? provider) => provider! as ResizeImage;

/// The decode width of an [Image] widget (what `cacheWidth` becomes).
int? decodeWidthOf(WidgetTester tester, Finder image) =>
    (tester.widget<Image>(image).image as ResizeImage).width;

void main() {
  late HttpOverrides? previous;

  setUp(() {
    // The category list is cached across CatalogService instances, so each
    // test starts from an empty cache rather than another test's list.
    CatalogService.invalidateCategoriesCache();
    previous = HttpOverrides.current;
    HttpOverrides.global = _PixelHttpOverrides();
    SharedPreferences.setMockInitialValues({'access_token': 'acc'});
  });
  tearDown(() => HttpOverrides.global = previous);

  /// A 390x844 phone at 3x — a common mid-range Android screen.
  void usePhone(WidgetTester tester, {double dpr = 3}) {
    tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  /// The service-details screen has an Arabic Row that overflows a 390 px
  /// screen under the test font (every glyph is a full square there, far
  /// wider than the real font). These tests are about decode sizes, so they
  /// run on a roomier screen; the expected size is computed from it.
  void useRoomyScreen(WidgetTester tester, {double dpr = 2}) {
    tester.view.physicalSize = Size(800 * dpr, 1400 * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
  }

  group('service cover photos', () {
    Future<void> openHome(WidgetTester tester, RoutedBackend backend) async {
      final store = TokenStore();
      final api = apiFor(backend, tokenStore: store);
      await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
          authService: AuthService(apiClient: api, tokenStore: store),
          catalogService: CatalogService(apiClient: api),
          notificationService: NotificationService(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a home card decodes at the card width, not the photo size',
        (tester) async {
      usePhone(tester);
      await openHome(tester, RoutedBackend({
        'GET /users/me': Reply(_user()),
        'GET /services': Reply([_service()]),
        'GET /notifications/unread-count': const Reply({'unread_count': 0}),
      }));

      final decoration = tester.widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.image != null);

      expect(resized(decoration.image!.image).width, 390 * 3);   // screen width
      expect(resized(decoration.image!.image).allowUpscaling, isFalse);
      expect(decoration.image!.fit, BoxFit.cover);               // unchanged
    });

    testWidgets('a search result thumbnail decodes at 50 logical px', (tester) async {
      usePhone(tester);
      final backend = RoutedBackend({
        'GET /categories': Reply([categoryJson()]),
        'GET /services': Reply([_service()]),
        'GET /cities': const Reply(['دمشق']),
      });
      await tester.pumpWidget(MaterialApp(
        home: SearchScreen(
          catalogService: CatalogService(apiClient: apiFor(backend)),
          cityService: CityService(apiClient: apiFor(backend)),
        ),
      ));
      await tester.pumpAndSettle();

      final thumbnail = tester.widgetList<Container>(find.byType(Container))
          .map((c) => c.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((d) => d.image != null);

      expect(resized(thumbnail.image!.image).width, 150);        // 50 x 3
      expect(thumbnail.image!.fit, BoxFit.cover);
    });

    testWidgets('the details cover decodes at screen width and keeps its error icon',
        (tester) async {
      useRoomyScreen(tester);
      final backend = RoutedBackend({
        'GET /services/100': Reply(_serviceDetail()),
        'GET /services/100/reviews': const Reply([]),
        'GET /services/100/reviews/summary':
            const Reply({'service_id': 100, 'average_rating': 0.0, 'review_count': 0}),
      });
      await tester.pumpWidget(MaterialApp(
        home: ServiceDetailsScreen(
          serviceId: 100,
          catalogService: CatalogService(apiClient: apiFor(backend)),
          reviewService: ReviewService(apiClient: apiFor(backend)),
        ),
      ));
      await tester.pumpAndSettle();

      final cover = find.byWidgetPredicate(
        (w) => w is Image && w.fit == BoxFit.cover && w.errorBuilder != null,
      );
      expect(decodeWidthOf(tester, cover.first), 800 * 2);
      expect(tester.widget<Image>(cover.first).errorBuilder, isNotNull);
    });
  });

  group('avatars', () {
    testWidgets('a provider avatar decodes at its circle size, not the photo size',
        (tester) async {
      usePhone(tester);
      final backend = RoutedBackend({
        'GET /users/10': Reply(providerJson()..['profile'] = {
          'full_name': 'Ahmad Ali',
          'avatar_url': '/uploads/me.jpg',
        }),
        'GET /services/provider/10': Reply([_service(cover: null)]),
        'GET /services/100/portfolio': const Reply([]),
      });
      final api = apiFor(backend);
      await tester.pumpWidget(MaterialApp(
        home: ProviderProfileScreen(
          providerId: 10,
          publicProfileService: PublicProfileService(apiClient: api),
          catalogService: CatalogService(apiClient: api),
          portfolioService: PortfolioService(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      final avatar = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .firstWhere((a) => a.backgroundImage != null);

      expect(resized(avatar.backgroundImage).width, 100 * 3);    // radius 50
      expect(resized(avatar.backgroundImage).height, isNull);    // aspect kept
      expect(avatar.radius, 50);                                 // layout unchanged
    });

    testWidgets('different screens decode at their own avatar size', (tester) async {
      // The same photo in a smaller circle must not cost the same memory.
      useRoomyScreen(tester);
      final backend = RoutedBackend({
        'GET /services/100': Reply(_serviceDetail()..['provider'] =
            (providerJson()..['profile'] = {
              'full_name': 'Ahmad Ali',
              'avatar_url': '/uploads/me.jpg',
            })),
        'GET /services/100/reviews': const Reply([]),
        'GET /services/100/reviews/summary':
            const Reply({'service_id': 100, 'average_rating': 0.0, 'review_count': 0}),
      });
      await tester.pumpWidget(MaterialApp(
        home: ServiceDetailsScreen(
          serviceId: 100,
          catalogService: CatalogService(apiClient: apiFor(backend)),
          reviewService: ReviewService(apiClient: apiFor(backend)),
        ),
      ));
      await tester.pumpAndSettle();

      final avatar = tester.widgetList<CircleAvatar>(find.byType(CircleAvatar))
          .firstWhere((a) => a.backgroundImage != null);

      expect(resized(avatar.backgroundImage).width, 36 * 2);     // radius 18
    });
  });

  group('portfolio grids', () {
    testWidgets('tiles decode at tile size and keep their rounded corners',
        (tester) async {
      usePhone(tester);
      final backend = RoutedBackend({
        'GET /users/10': Reply(providerJson()..['profile'] = {'full_name': 'Ahmad Ali'}),
        'GET /services/provider/10': Reply([_service(cover: null)]),
        'GET /services/100/portfolio': Reply([
          {'id': 1, 'service_id': 100, 'image_url': '/uploads/p1.jpg',
            'caption': null, 'display_order': 0},
        ]),
      });
      final api = apiFor(backend);
      await tester.pumpWidget(MaterialApp(
        home: ProviderProfileScreen(
          providerId: 10,
          publicProfileService: PublicProfileService(apiClient: api),
          catalogService: CatalogService(apiClient: api),
          portfolioService: PortfolioService(apiClient: api),
        ),
      ));
      await tester.pumpAndSettle();

      final tile = find.byWidgetPredicate(
        (w) => w is Image && w.fit == BoxFit.cover && w.errorBuilder != null,
      );
      expect(tile, findsOneWidget);
      expect(decodeWidthOf(tester, tile), (390 / 3 * 3).round());   // a 3-column tile
      // The tile is still clipped and still has its broken-image fallback.
      expect(find.ancestor(of: tile, matching: find.byType(ClipRRect)), findsOneWidget);
    });
  });

  group('what is deliberately not resized', () {
    // The avatar and portfolio upload limits exist to serve this viewer, so
    // these two tests pin why the stored photo may not be shrunk further.
    testWidgets('the full-screen viewer decodes the whole photo and zooms to 4x',
        (tester) async {
      usePhone(tester);
      await tester.pumpWidget(const MaterialApp(
        home: FullScreenImageViewer(imageUrl: 'http://x/a.jpg'),
      ));
      await tester.pumpAndSettle();

      // No decode cap: every stored pixel is available to zoom into.
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<NetworkImage>());
      expect(image.image, isNot(isA<ResizeImage>()));
      expect(image.fit, BoxFit.contain);

      final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(viewer.maxScale, 4);
    });

    testWidgets('an avatar and a portfolio photo both open in that viewer',
        (tester) async {
      // Both are small on screen but are opened full screen, which is why
      // neither upload limit is set to its on-screen size.
      usePhone(tester);
      for (final url in ['http://x/avatar.jpg', 'http://x/work.jpg']) {
        await tester.pumpWidget(MaterialApp(home: FullScreenImageViewer(imageUrl: url)));
        await tester.pumpAndSettle();
        expect((tester.widget<Image>(find.byType(Image)).image as NetworkImage).url, url);
      }
    });
  });

  group('decoding does not follow the stored photo size', () {
    testWidgets('a thumbnail decodes the same whatever the stored photo is',
        (tester) async {
      // Raising an upload limit must never make a list thumbnail more
      // expensive: the decode size comes from the box and the screen only.
      usePhone(tester);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        }),
      ));

      final small =
          sizedNetworkImage(context, 'http://x/small.jpg', longestSide: 50) as ResizeImage;
      final large =
          sizedNetworkImage(context, 'http://x/huge.jpg', longestSide: 50) as ResizeImage;

      expect(small.width, 150);
      expect(large.width, small.width);
      // ...and a photo smaller than the box is still left at its own size.
      expect(small.allowUpscaling, isFalse);
    });
  });

  group('decode sizes follow the device', () {
    for (final dpr in [1.0, 2.0, 3.0]) {
      testWidgets('a 50 px thumbnail on a ${dpr}x screen decodes ${50 * dpr} px wide',
          (tester) async {
        usePhone(tester, dpr: dpr);
        final backend = RoutedBackend({
          'GET /categories': Reply([categoryJson()]),
          'GET /services': Reply([_service()]),
          'GET /cities': const Reply(['دمشق']),
        });
        await tester.pumpWidget(MaterialApp(
          home: SearchScreen(
            catalogService: CatalogService(apiClient: apiFor(backend)),
            cityService: CityService(apiClient: apiFor(backend)),
          ),
        ));
        await tester.pumpAndSettle();

        final thumbnail = tester.widgetList<Container>(find.byType(Container))
            .map((c) => c.decoration)
            .whereType<BoxDecoration>()
            .firstWhere((d) => d.image != null);

        expect(resized(thumbnail.image!.image).width, (50 * dpr).round());
      });
    }
  });
}
