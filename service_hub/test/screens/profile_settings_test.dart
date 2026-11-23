// The top-left controls of «حسابي»: the day/night switch (live, saved across
// restarts) and the ⚙️ whose menu holds «تسجيل الخروج» (only after
// confirmation).
//
// These run through the real MyApp, so the real wiring is exercised: Arabic
// locale / RTL, appTheme + darkAppTheme, and ThemeController driving
// MaterialApp.themeMode.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/core/theme/app_colors.dart';
import 'package:service_hub/core/theme/theme_controller.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/profile/profile_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:service_hub/main.dart';
import 'package:service_hub/shared/widgets/day_night_switch.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _tokens = {'access_token': 'acc', 'refresh_token': 'ref'};

RoutedBackend _backend() => RoutedBackend({
      'GET /users/me': const Reply({
        'id': 10,
        'email': 'ahmad@example.com',
        'role': 'user',
        'is_provider': false,
        'is_active': true,
        'profile': {'full_name': 'Ahmad Ali'},
      }),
      'GET /services/provider/10': const Reply([]),
    });

final _switch = find.byKey(const Key('dark-mode-switch'));
final _gear = find.byKey(const Key('profile-settings'));
final _logoutItem = find.byKey(const Key('settings-logout'));

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(_gear);
  await tester.pumpAndSettle();
}

/// ⚙️ → «تسجيل الخروج»: opens the confirmation dialog.
Future<void> _openLogoutDialog(WidgetTester tester) async {
  await _openMenu(tester);
  await tester.tap(_logoutItem);
  await tester.pumpAndSettle();
}

/// The icon drawn inside the switch's thumb (the idle one is smaller).
Finder _thumbIcon(IconData icon) => find.descendant(
      of: _switch,
      matching: find.byWidgetPredicate(
          (w) => w is Icon && w.icon == icon && w.size == DayNightSwitch.thumbIconSize),
    );

Future<TokenStore> _openApp(WidgetTester tester, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final store = TokenStore();
  final api = apiFor(_backend(), tokenStore: store);
  final auth = AuthService(apiClient: api, tokenStore: store);
  await tester.pumpWidget(MyApp(
    showDeviceFrame: false,
    apiClient: api,
    authService: auth,
    pushSetup: () async {},
    homeBuilder: (_) => ProfileScreen(
      authService: auth,
      catalogService: CatalogService(apiClient: api),
      loginBuilder: (_) => const Scaffold(body: Center(child: Text('LOGIN'))),
    ),
  ));
  await tester.pumpAndSettle();
  return store;
}

ThemeData _themeOnScreen(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(ProfileScreen)));

Future<String?> _savedTheme() async =>
    (await SharedPreferences.getInstance()).getString('theme_mode');

Future<void> _toggle(WidgetTester tester) async {
  await tester.tap(_switch);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(_tokens);
    ThemeController.mode.value = ThemeMode.light; // as on a fresh launch
  });
  tearDown(() => ThemeController.mode.value = ThemeMode.light);

  group('the app bar of «حسابي»', () {
    testWidgets('⚙️ in the top-left corner, the switch right next to it', (tester) async {
      await _openApp(tester);
      final appBar = find.byType(AppBar);

      expect(find.descendant(of: appBar, matching: _gear), findsOneWidget);
      expect(find.descendant(of: appBar, matching: _switch), findsOneWidget);
      expect(find.text('حسابي'), findsOneWidget);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      // Logout is inside the menu, not in the app bar.
      expect(find.byIcon(Icons.logout_rounded), findsNothing);
      expect(find.byKey(const Key('profile-logout')), findsNothing);

      final gear = tester.getRect(_gear);
      final toggle = tester.getRect(_switch);
      expect(gear.left, lessThan(30)); // the corner
      expect(gear.top, lessThan(80));
      // Side by side: the switch is just to the right of the ⚙️, centred on
      // the same line.
      expect(toggle.left, greaterThanOrEqualTo(gear.right));
      expect(toggle.left - gear.right, lessThan(12));
      expect(toggle.center.dy, closeTo(gear.center.dy, 1));
      // The title stays on the right (start side in RTL), clear of both.
      expect(tester.getRect(find.text('حسابي')).left, greaterThan(toggle.right));
      expect(tester.widget<IconButton>(_gear).tooltip, 'الإعدادات');
    });

    testWidgets('the ⚙️ opens a small menu with just «تسجيل الخروج», not a new page',
        (tester) async {
      await _openApp(tester);
      await _openMenu(tester);

      expect(_logoutItem, findsOneWidget);
      expect(find.byType(MenuItemButton), findsOneWidget); // nothing else in it
      expect(find.text('تسجيل الخروج'), findsOneWidget);
      // Red text with the (unmirrored) logout icon, like the design.
      final label = tester.widget<Text>(find.text('تسجيل الخروج'));
      expect(label.style!.color, Colors.red.shade400);
      final icon = tester.widget<Icon>(
          find.descendant(of: _logoutItem, matching: find.byIcon(Icons.logout_rounded)));
      expect(icon.color, Colors.red.shade400);
      expect(find.ancestor(of: find.byIcon(Icons.logout_rounded), matching: find.byType(Transform)),
          findsNothing);
      // RTL: icon on the right of the text.
      expect(tester.getCenter(find.byIcon(Icons.logout_rounded)).dx,
          greaterThan(tester.getCenter(find.text('تسجيل الخروج')).dx));

      // Same page underneath: nothing was pushed.
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);

      // Compact, below the ⚙️, and not glued to the screen edge.
      final menu = tester.getRect(_logoutItem);
      expect(menu.width, lessThan(260));
      expect(menu.left, greaterThanOrEqualTo(8));
      expect(menu.right, lessThanOrEqualTo(390));
      expect(menu.top, greaterThan(tester.getRect(_gear).top));

      await tester.tap(_gear); // closes again
      await tester.pumpAndSettle();
      expect(_logoutItem, findsNothing);
    });

    for (final size in const [Size(320, 568), Size(414, 896), Size(800, 1280)]) {
      testWidgets('fits at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _openApp(tester, size: size);
        expect(tester.takeException(), isNull);
        expect(_switch.hitTestable(), findsOneWidget);
        expect(_gear.hitTestable(), findsOneWidget);
        expect(find.text('حسابي').hitTestable(), findsOneWidget);

        await _openMenu(tester);
        final menu = tester.getRect(_logoutItem);
        expect(menu.left, greaterThanOrEqualTo(0));
        expect(menu.right, lessThanOrEqualTo(size.width));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('the day/night switch', () {
    testWidgets('looks like the design: sun on the left when off, moon on the right when on',
        (tester) async {
      await _openApp(tester);
      final size = tester.getSize(_switch);
      expect(size, const Size(DayNightSwitch.width, DayNightSwitch.height));
      final centre = tester.getCenter(_switch).dx;

      expect(_thumbIcon(Icons.wb_sunny_rounded), findsOneWidget);
      expect(tester.getCenter(_thumbIcon(Icons.wb_sunny_rounded)).dx, lessThan(centre));
      expect(tester.widget<Icon>(_thumbIcon(Icons.wb_sunny_rounded)).color,
          DayNightSwitch.sunColor);

      await _toggle(tester);

      expect(_thumbIcon(Icons.nightlight_round), findsOneWidget);
      expect(tester.getCenter(_thumbIcon(Icons.nightlight_round)).dx, greaterThan(centre));
      expect(tester.widget<Icon>(_thumbIcon(Icons.nightlight_round)).color,
          DayNightSwitch.moonColor);
      expect(tester.getSemantics(_switch), matchesSemantics(
        label: 'الوضع الداكن',
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ));
    });

    testWidgets('turning it on switches the WHOLE app at once and saves it', (tester) async {
      await _openApp(tester);
      expect(_themeOnScreen(tester).brightness, Brightness.light);

      await tester.tap(_switch);
      await tester.pump(); // one frame

      expect(ThemeController.isDark, isTrue);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.dark);

      await tester.pumpAndSettle();
      final theme = _themeOnScreen(tester);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, AppColors.darkBackground);
      expect(theme.inputDecorationTheme.fillColor, AppColors.darkField);
      expect(theme.dialogTheme.backgroundColor, AppColors.darkCard);
      final scaffold = tester.widget<Material>(find
          .descendant(of: find.byType(Scaffold).first, matching: find.byType(Material))
          .first);
      expect(scaffold.color, AppColors.darkBackground);

      expect(await _savedTheme(), 'dark');
    });

    testWidgets('dialogs opened afterwards are dark too, with a readable «إلغاء»',
        (tester) async {
      await _openApp(tester);
      await _toggle(tester);

      await _openMenu(tester);
      // The menu follows the dark theme too.
      expect(Theme.of(tester.element(_logoutItem)).brightness, Brightness.dark);
      expect(tester.widget<Text>(find.text('تسجيل الخروج')).style!.color, Colors.red.shade300);
      await tester.tap(_logoutItem);
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(AlertDialog))).brightness, Brightness.dark);

      final cancelText = tester.widget<RichText>(find.descendant(
        of: find.widgetWithText(TextButton, 'إلغاء'),
        matching: find.byType(RichText),
      ));
      expect(cancelText.text.style!.color, AppColors.darkText);
    });

    testWidgets('turning it off goes back to light and saves it', (tester) async {
      await _openApp(tester);
      await _toggle(tester);
      expect(_themeOnScreen(tester).brightness, Brightness.dark);

      await _toggle(tester);

      expect(ThemeController.isDark, isFalse);
      expect(_themeOnScreen(tester).brightness, Brightness.light);
      expect(_themeOnScreen(tester).scaffoldBackgroundColor, AppColors.background);
      expect(await _savedTheme(), 'light');
    });

    testWidgets('the choice survives closing and reopening the app', (tester) async {
      await _openApp(tester);
      await _toggle(tester);

      // "Close the app": keep only what is on disk (SharedPreferences) and
      // start from a fresh process state.
      final prefs = await SharedPreferences.getInstance();
      final onDisk = <String, Object>{
        for (final k in prefs.getKeys()) k: prefs.get(k)!,
      };
      expect(onDisk['theme_mode'], 'dark');
      await tester.pumpWidget(const SizedBox());
      ThemeController.mode.value = ThemeMode.light;
      SharedPreferences.setMockInitialValues(onDisk);

      // "Reopen it": main() loads the saved mode before runApp.
      await ThemeController.load();
      await _openApp(tester);

      expect(_themeOnScreen(tester).brightness, Brightness.dark);
      expect(_thumbIcon(Icons.nightlight_round), findsOneWidget); // switch shows "on"
    });

    testWidgets('with nothing saved the app opens in light mode', (tester) async {
      await ThemeController.load();
      await _openApp(tester);
      expect(ThemeController.isDark, isFalse);
      expect(_themeOnScreen(tester).brightness, Brightness.light);
      expect(_thumbIcon(Icons.wb_sunny_rounded), findsOneWidget);
    });
  });

  group('logout', () {
    const openLogoutDialog = _openLogoutDialog;

    testWidgets('asks first, in Arabic and RTL, with «إلغاء» and «تسجيل الخروج»',
        (tester) async {
      final store = await _openApp(tester);
      await openLogoutDialog(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('هل أنت متأكد أنك تريد تسجيل الخروج؟'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'إلغاء'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'تسجيل الخروج'), findsOneWidget);
      expect(Directionality.of(tester.element(find.byType(AlertDialog))), TextDirection.rtl);
      expect(await store.isLoggedIn, isTrue); // nothing cleared yet
    });

    testWidgets('«إلغاء» keeps the session and the page', (tester) async {
      final store = await _openApp(tester);
      await openLogoutDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(await store.isLoggedIn, isTrue);
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('LOGIN'), findsNothing);
    });

    testWidgets('tapping outside the dialog does not log out', (tester) async {
      final store = await _openApp(tester);
      await openLogoutDialog(tester);

      await tester.tapAt(const Offset(10, 820));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(await store.isLoggedIn, isTrue);
      expect(find.byType(ProfileScreen), findsOneWidget);
    });

    testWidgets('confirming clears the tokens and replaces everything with Login',
        (tester) async {
      final store = await _openApp(tester);
      expect(await store.accessToken, 'acc');
      await openLogoutDialog(tester);

      await tester.tap(find.widgetWithText(TextButton, 'تسجيل الخروج'));
      await tester.pumpAndSettle();

      expect(await store.isLoggedIn, isFalse);
      expect(await store.accessToken, isNull);
      expect(await store.refreshToken, isNull);
      expect(find.text('LOGIN'), findsOneWidget);
      expect(find.byType(ProfileScreen), findsNothing);
      // No way "back" into the signed-in pages.
      expect(tester.state<NavigatorState>(find.byType(Navigator).first).canPop(), isFalse);
    });

    testWidgets('logging out keeps the chosen theme', (tester) async {
      await _openApp(tester);
      await _toggle(tester);

      await openLogoutDialog(tester);
      await tester.tap(find.widgetWithText(TextButton, 'تسجيل الخروج'));
      await tester.pumpAndSettle();

      expect(Theme.of(tester.element(find.text('LOGIN'))).brightness, Brightness.dark);
      expect(await _savedTheme(), 'dark');
    });
  });
}
