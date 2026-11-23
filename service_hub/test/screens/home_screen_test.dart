import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/home/home_screen.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _user({String? name = 'Ahmad'}) => {
      'id': 1,
      'email': 'a@b.com',
      'role': 'user',
      'is_provider': false,
      'is_active': true,
      'profile': name == null ? null : {'full_name': name},
    };

Map<String, dynamic> _service(int id, String title) =>
    serviceListItemJson(id: id, price: '25.5')..['title'] = title;

RoutedBackend _backend({
  List<Map<String, dynamic>>? services,
  int unread = 0,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/me': Reply(_user()),
      'GET /services': Reply(services ?? [_service(100, 'Fix pipes')]),
      'GET /notifications/unread-count': Reply({'unread_count': unread}),
      ...extra,
    });

Widget _screen(RoutedBackend backend, TokenStore store, {bool rtl = false}) {
  final api = apiFor(backend, tokenStore: store);
  Widget stub(String text) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(text)),
      );
  return MaterialApp(
    builder: rtl
        ? (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!)
        : null,
    home: HomeScreen(
      authService: AuthService(apiClient: api, tokenStore: store),
      catalogService: CatalogService(apiClient: api),
      notificationService: NotificationService(apiClient: api),
      notificationsBuilder: (_) => stub('NOTIFICATIONS'),
      exchangeBuilder: (_) => stub('EXCHANGE HUB'),
      bookingBuilder: (_) => stub('BOOKING'),
      profileBuilder: (_) => stub('PROFILE'),
      searchBuilder: (_) => stub('SEARCH'),
      detailsBuilder: (id) => stub('DETAILS $id'),
    ),
  );
}

Future<TokenStore> _open(WidgetTester tester, RoutedBackend backend, {bool tall = true}) async {
  if (tall) useTallScreen(tester);
  final store = TokenStore();
  await tester.pumpWidget(_screen(backend, store));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc', 'refresh_token': 'ref'}));

  group('greeting', () {
    testWidgets('greets the user by name once loaded', (tester) async {
      await _open(tester, _backend());
      expect(find.text('مرحباً، Ahmad 👋'), findsOneWidget);
    });

    testWidgets('falls back to a plain greeting when the user cannot be loaded', (tester) async {
      await _open(
        tester,
        _backend(extra: {'GET /users/me': const Reply({'detail': 'expired'}, status: 401)}),
      );
      expect(find.text('مرحباً 👋'), findsOneWidget);
    });
  });

  group('services list', () {
    testWidgets('shows service cards', (tester) async {
      await _open(tester, _backend(services: [_service(1, 'Fix pipes'), _service(2, 'Paint walls')]));

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('Paint walls'), findsOneWidget);
      expect(find.text('بواسطة Ahmad Ali'), findsNWidgets(2));
      expect(find.text('25.50 \$'), findsNWidgets(2));
    });

    testWidgets('a card is named by its category, shown once (no duplicate category line)',
        (tester) async {
      await _open(tester, _backend(services: [
        _service(1, 'Old name')..['display_title'] = 'سباكة',
        _service(2, 'Other old name')..['display_title'] = 'كهرباء',
      ]));

      expect(find.text('سباكة'), findsOneWidget);
      expect(find.text('كهرباء'), findsOneWidget);
      expect(find.text('Old name'), findsNothing);
    });

    testWidgets('a service without a price says «السعر غير محدد», never 0 or null',
        (tester) async {
      await _open(tester, _backend(services: [_service(1, 'Fix pipes')..['price'] = null]));

      expect(find.text('السعر غير محدد'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
      expect(find.textContaining('0.00'), findsNothing);
    });

    testWidgets('empty state', (tester) async {
      await _open(tester, _backend(services: []));
      expect(find.text('لا توجد خدمات حالياً.'), findsOneWidget);
    });

    testWidgets('error with Retry', (tester) async {
      final backend = _backend(extra: {'GET /services': const Reply({'detail': 'boom'}, status: 500)});
      await _open(tester, backend);

      expect(find.text('boom'), findsOneWidget);

      backend.routes['GET /services'] = Reply([_service(100, 'Fix pipes')]);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Fix pipes'), findsOneWidget);
    });

    testWidgets('tapping a card opens its details', (tester) async {
      await _open(tester, _backend(services: [_service(77, 'Fix pipes')]));

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();

      expect(find.text('DETAILS 77'), findsOneWidget);
    });
  });

  group('notifications badge', () {
    testWidgets('shows the unread count', (tester) async {
      await _open(tester, _backend(unread: 3));
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('hides the badge when there is nothing unread', (tester) async {
      await _open(tester, _backend(unread: 0));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('opening notifications refreshes the count on return', (tester) async {
      final backend = _backend(unread: 3);
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.notifications_outlined));
      await tester.pumpAndSettle();
      expect(find.text('NOTIFICATIONS'), findsOneWidget);

      backend.routes['GET /notifications/unread-count'] = const Reply({'unread_count': 0});
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /notifications/unread-count'), 2);
      expect(find.text('3'), findsNothing);
    });

    testWidgets('a failing unread request does not break the screen', (tester) async {
      await _open(
        tester,
        _backend(extra: {'GET /notifications/unread-count': const Reply({'detail': 'x'}, status: 500)}),
      );
      expect(find.text('Fix pipes'), findsOneWidget);
    });
  });

  group('navigation', () {
    testWidgets('bottom bar: Search', (tester) async {
      await _open(tester, _backend());
      await tester.tap(find.text('بحث').last);
      await tester.pumpAndSettle();
      expect(find.text('SEARCH'), findsOneWidget);
    });

    testWidgets('bottom bar: Booking', (tester) async {
      await _open(tester, _backend());
      await tester.tap(find.text('الحجوزات'));
      await tester.pumpAndSettle();
      expect(find.text('BOOKING'), findsOneWidget);
    });

    testWidgets('bottom bar: Profile', (tester) async {
      await _open(tester, _backend());
      await tester.tap(find.text('حسابي'));
      await tester.pumpAndSettle();
      expect(find.text('PROFILE'), findsOneWidget);
    });

    testWidgets('bottom bar has exactly الرئيسية، بحث، المقايضة، الحجوزات، حسابي',
        (tester) async {
      await _open(tester, _backend());

      final labels = tester
          .widgetList<NavigationDestination>(find.byType(NavigationDestination))
          .map((d) => d.label)
          .toList();
      expect(labels, ['الرئيسية', 'بحث', 'المقايضة', 'الحجوزات', 'حسابي']);
      expect(
        find.descendant(of: find.byType(NavigationBar), matching: find.text('إضافة')),
        findsNothing,
      );
      final exchange = tester.widget<NavigationDestination>(
        find.widgetWithText(NavigationDestination, 'المقايضة'),
      );
      expect((exchange.icon as Icon).icon, Icons.swap_horiz);
    });

    testWidgets('bottom bar: المقايضة opens the exchange hub and becomes the active item',
        (tester) async {
      await _open(tester, _backend());
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 0);

      await tester.tap(find.text('المقايضة'));
      await tester.pumpAndSettle();
      expect(find.text('EXCHANGE HUB'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);
    });

    testWidgets('coming back from the profile (where services are added) refreshes the list',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.text('حسابي'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /services'), 2);
    });

    testWidgets('the search bar opens search', (tester) async {
      await _open(tester, _backend());

      await tester.tap(find.text('ابحث عن خدمة'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.text('SEARCH'), findsOneWidget);
    });
  });

  // The ⋮ menu (theme + logout) moved to the ⚙️ on «حسابي»
  // (test/screens/profile_settings_test.dart); only the bell is left here.
  group('header', () {
    testWidgets('no ⋮ menu any more: no popup button, no more_vert icon',
        (tester) async {
      await _open(tester, _backend());

      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.text('تسجيل الخروج'), findsNothing);
      expect(find.text('الوضع الداكن'), findsNothing);
    });

    testWidgets('the bell sits in the corner the menu used, with no gap',
        (tester) async {
      await _open(tester, _backend());
      final bell = find.byKey(const Key('home-notifications'));
      expect(bell, findsOneWidget);

      final positioned = tester.widget<PositionedDirectional>(
        find.ancestor(of: bell, matching: find.byType(PositionedDirectional)),
      );
      expect(positioned.top, 10);
      expect(positioned.end, 15); // was 50, next to the ⋮ at 15
    });

    testWidgets('in RTL the bell is at the top-left corner and opens notifications',
        (tester) async {
      useTallScreen(tester);
      await tester.pumpWidget(_screen(_backend(unread: 2), TokenStore(), rtl: true));
      await tester.pumpAndSettle();

      final bell = find.byKey(const Key('home-notifications'));
      final rect = tester.getRect(bell);
      expect(rect.left, lessThan(80)); // 15 px from the left edge (+ SafeArea)
      expect(rect.top, lessThan(80));
      expect(find.text('2'), findsOneWidget); // badge kept

      await tester.tap(bell);
      await tester.pumpAndSettle();
      expect(find.text('NOTIFICATIONS'), findsOneWidget);
    });
  });

  testWidgets('a scroll-to-top button appears after scrolling and returns to the top',
      (tester) async {
    final many = [for (var i = 1; i <= 6; i++) _service(i, 'Service $i')];
    await _open(tester, _backend(services: many), tall: false);

    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);

    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    expect(find.text('مرحباً، Ahmad 👋'), findsOneWidget);
  });
}
