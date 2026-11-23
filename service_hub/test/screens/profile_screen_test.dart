import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/core/theme/app_theme.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/profile/profile_screen.dart';
import 'package:service_hub/features/service/data/catalog_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _user({
  String role = 'user',
  bool provider = false,
  bool withProfile = true,
}) =>
    {
      'id': 10,
      'email': 'ahmad@example.com',
      'role': role,
      'is_provider': provider,
      'is_active': true,
      'profile': withProfile
          ? {
              'full_name': 'Ahmad Ali',
              'phone_number': '0912345678',
              'city': 'Damascus',
              'bio': 'I fix things',
              'avatar_url': null,
            }
          : null,
    };

Map<String, dynamic> _service(int id, String title) => serviceListItemJson(id: id)..['title'] = title;

RoutedBackend _backend({
  Map<String, dynamic>? user,
  List<Map<String, dynamic>>? services,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/me': Reply(user ?? _user()),
      'GET /services/provider/10': Reply(services ?? [_service(100, 'Fix pipes')]),
      ...extra,
    });

Widget _screen(RoutedBackend backend, {ThemeMode? themeMode}) {
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  // A stub page that closes with `true` so the "reload on return" paths run.
  Widget stub(String text) => Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(text),
            ),
          ),
        ),
      );
  return MaterialApp(
    // With a mode, the app's real light/dark themes are used.
    theme: themeMode == null ? null : appTheme,
    darkTheme: themeMode == null ? null : darkAppTheme,
    themeMode: themeMode ?? ThemeMode.system,
    home: ProfileScreen(
      authService: AuthService(apiClient: api, tokenStore: store),
      catalogService: CatalogService(apiClient: api),
      addServiceBuilder: (_) => stub('ADD SERVICE'),
      availabilityBuilder: (id) => stub('AVAILABILITY $id'),
      adminBuilder: (_) => stub('ADMIN PAGE'),
      editProfileBuilder: (u) => stub('EDIT PROFILE ${u.email}'),
      editServiceBuilder: (id) => stub('EDIT SERVICE $id'),
      portfolioBuilder: (id, title) => stub('PORTFOLIO $id $title'),
    ),
  );
}

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_screen(backend));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('loading', () {
    testWidgets('shows the account details', (tester) async {
      await _open(tester, _backend());

      expect(find.text('Ahmad Ali'), findsOneWidget);
      expect(find.text('ahmad@example.com'), findsOneWidget);
      expect(find.text('0912345678'), findsOneWidget);
      expect(find.text('Damascus'), findsOneWidget);
      expect(find.text('I fix things'), findsOneWidget);
    });

    testWidgets('without a profile the email is the title and the placeholders show',
        (tester) async {
      await _open(tester, _backend(user: _user(withProfile: false)));

      expect(find.text('ahmad@example.com'), findsNWidgets(2));
      expect(find.text('لا توجد نبذة بعد.'), findsOneWidget);
      expect(find.byIcon(Icons.phone), findsNothing);
      expect(find.byIcon(Icons.location_on), findsNothing);
    });

    testWidgets('error with Retry', (tester) async {
      final backend = _backend(extra: {'GET /users/me': const Reply({'detail': 'expired'}, status: 401)});
      await _open(tester, backend);
      expect(find.text('expired'), findsOneWidget);

      backend.routes['GET /users/me'] = Reply(_user());
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();

      expect(find.text('Ahmad Ali'), findsOneWidget);
    });

    testWidgets('a failure loading services is ignored (profile still shows)', (tester) async {
      await _open(
        tester,
        _backend(extra: {'GET /services/provider/10': const Reply({'detail': 'x'}, status: 500)}),
      );

      expect(find.text('Ahmad Ali'), findsOneWidget);
      expect(find.text("لم تنشر أي خدمة بعد."), findsOneWidget);
    });
  });

  group('stats and services', () {
    testWidgets('shows the service count and provider flag', (tester) async {
      await _open(tester, _backend(user: _user(provider: true), services: [_service(1, 'A'), _service(2, 'B')]));

      expect(find.text('2'), findsOneWidget);
      expect(find.text('نعم'), findsOneWidget);
    });

    testWidgets('non-provider shows "لا"', (tester) async {
      await _open(tester, _backend());
      expect(find.text('لا'), findsOneWidget);
    });

    testWidgets('lists my services', (tester) async {
      await _open(tester, _backend(services: [_service(1, 'Fix pipes'), _service(2, 'Paint walls')]));
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('Paint walls'), findsOneWidget);
    });

    testWidgets('empty services message', (tester) async {
      await _open(tester, _backend(services: []));
      expect(find.text("لم تنشر أي خدمة بعد."), findsOneWidget);
    });
  });

  group('role based buttons', () {
    testWidgets('a regular user sees neither Booking Hours nor Admin', (tester) async {
      await _open(tester, _backend());

      expect(find.text('ساعات الحجز'), findsNothing);
      expect(find.text('الإدارة'), findsNothing);
    });

    for (final (name, user) in [
      ('regular user', _user()),
      ('provider', _user(provider: true)),
      ('admin', _user(role: 'admin')),
    ]) {
      testWidgets('Exchange is no longer on the profile ($name) — it is in the bottom bar',
          (tester) async {
        await _open(tester, _backend(user: user));
        expect(find.text('التبادل'), findsNothing);
        expect(find.text('المقايضة'), findsNothing);
        expect(find.byIcon(Icons.swap_horiz), findsNothing);
      });
    }

    testWidgets('a provider also sees Booking Hours', (tester) async {
      await _open(tester, _backend(user: _user(provider: true)));

      expect(find.text('ساعات الحجز'), findsOneWidget);
      expect(find.text('الإدارة'), findsNothing);
    });

    testWidgets('an admin sees the Admin button', (tester) async {
      await _open(tester, _backend(user: _user(role: 'admin')));

      expect(find.text('الإدارة'), findsOneWidget);
      expect(find.text('ساعات الحجز'), findsNothing);
    });
  });

  group('navigation', () {
    for (final (name, user) in [('regular user', _user()), ('provider', _user(provider: true))]) {
      testWidgets('Add Service is still on the profile and opens the add form ($name)',
          (tester) async {
        await _open(tester, _backend(user: user));
        // TextButton.icon builds a private TextButton subclass.
        final addButton = find.ancestor(
          of: find.text('إضافة'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        );
        expect(addButton, findsOneWidget);

        await tester.tap(addButton);
        await tester.pumpAndSettle();
        expect(find.text('ADD SERVICE'), findsOneWidget);
      });
    }

    testWidgets('Booking Hours opens availability for this provider', (tester) async {
      await _open(tester, _backend(user: _user(provider: true)));
      await tester.tap(find.text('ساعات الحجز'));
      await tester.pumpAndSettle();
      expect(find.text('AVAILABILITY 10'), findsOneWidget);
    });

    testWidgets('Admin opens the dashboard', (tester) async {
      await _open(tester, _backend(user: _user(role: 'admin')));
      await tester.tap(find.text('الإدارة'));
      await tester.pumpAndSettle();
      expect(find.text('ADMIN PAGE'), findsOneWidget);
    });

    testWidgets('Edit Profile gets the current user and reloads when it saves', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.text('تعديل الملف الشخصي'));
      await tester.pumpAndSettle();
      expect(find.text('EDIT PROFILE ahmad@example.com'), findsOneWidget);

      await tester.tap(find.text('EDIT PROFILE ahmad@example.com')); // stub pops with true
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /users/me'), 2);
    });

    testWidgets('Add reloads when a service was added', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.text('إضافة'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD SERVICE'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /users/me'), 2);
    });

    testWidgets('the edit icon opens the service editor and reloads on save', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byTooltip('تعديل الخدمة'));
      await tester.pumpAndSettle();
      expect(find.text('EDIT SERVICE 100'), findsOneWidget);

      await tester.tap(find.text('EDIT SERVICE 100'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('GET /users/me'), 2);
    });

    testWidgets('the photos icon opens the portfolio for that service', (tester) async {
      await _open(tester, _backend());
      await tester.tap(find.byTooltip('إدارة صور الأعمال السابقة'));
      await tester.pumpAndSettle();
      expect(find.text('PORTFOLIO 100 Fix pipes'), findsOneWidget);
    });
  });

  group('deleting a service', () {
    testWidgets('asks first; Cancel keeps it', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byTooltip('حذف الخدمة'));
      await tester.pumpAndSettle();
      expect(find.text('حذف الخدمة؟'), findsOneWidget);
      expect(find.text('سيتم حذف "Fix pipes" نهائياً.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('DELETE /services/100'), 0);
    });

    testWidgets('confirming deletes and reloads', (tester) async {
      final backend = _backend(extra: {'DELETE /services/100': const Reply(null, status: 204)});
      await _open(tester, backend);

      await tester.tap(find.byTooltip('حذف الخدمة'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'حذف'));
      await pumpFrames(tester);

      expect(backend.callsTo('DELETE /services/100'), 1);
      expect(find.text('تم حذف الخدمة.'), findsOneWidget);
      expect(backend.callsTo('GET /users/me'), 2);
    });

    testWidgets('a refusal is shown', (tester) async {
      final backend = _backend(extra: {
        'DELETE /services/100': const Reply({'detail': 'You do not own this service'}, status: 403),
      });
      await _open(tester, backend);

      await tester.tap(find.byTooltip('حذف الخدمة'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'حذف'));
      await pumpFrames(tester);

      expect(find.text('You do not own this service'), findsOneWidget);
    });
  });

  group('the three action buttons stay fixed while the profile scrolls', () {
    final scroll = find.byKey(const Key('profile-scroll'));
    final actions = find.byKey(const Key('profile-actions'));
    final hours = find.ancestor(
      of: find.text('ساعات الحجز'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    final admin = find.ancestor(
      of: find.text('الإدارة'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    final edit = find.widgetWithText(ElevatedButton, 'تعديل الملف الشخصي');

    List<Map<String, dynamic>> manyServices(int n) =>
        [for (var i = 1; i <= n; i++) _service(100 + i, 'Service $i')];

    /// A phone-sized screen (logical pixels), optionally with a bottom
    /// system inset (home indicator / gesture bar).
    Future<void> openOn(
      WidgetTester tester,
      RoutedBackend backend, {
      Size size = const Size(390, 760),
      double bottomInset = 0,
      ThemeMode? themeMode,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = FakeViewPadding(bottom: bottomInset);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_screen(backend, themeMode: themeMode));
      await tester.pumpAndSettle();
    }

    Map<String, Offset> positions(WidgetTester tester) => {
          'hours': tester.getTopLeft(hours),
          'admin': tester.getTopLeft(admin),
          'edit': tester.getTopLeft(edit),
        };

    final adminProvider = _user(role: 'admin', provider: true);

    testWidgets('the buttons are outside the scrollable area, in their original order',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider));

      for (final button in [hours, admin, edit]) {
        expect(find.descendant(of: scroll, matching: button), findsNothing);
        expect(find.descendant(of: actions, matching: button), findsOneWidget);
      }
      // Same arrangement as before: ساعات الحجز and الإدارة side by side
      // (RTL: ساعات الحجز first, on the right), تعديل الملف الشخصي under them.
      expect(tester.getTopLeft(hours).dy, tester.getTopLeft(admin).dy);
      expect(tester.getTopLeft(edit).dy, greaterThan(tester.getBottomLeft(hours).dy));
      // The scrollable content ends where the fixed buttons begin.
      expect(tester.getBottomLeft(scroll).dy, lessThanOrEqualTo(tester.getTopLeft(actions).dy));
    });

    testWidgets('the buttons keep their look (colours, borders, padding, label style)',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider));

      ButtonStyle styleOf(Finder f) => tester.widget<ButtonStyleButton>(f).style!;
      final hoursStyle = styleOf(hours);
      final adminStyle = styleOf(admin);
      expect(hoursStyle.foregroundColor!.resolve({}), Colors.blue);
      expect(hoursStyle.side!.resolve({}), const BorderSide(color: Colors.blue));
      expect(adminStyle.foregroundColor!.resolve({}), Colors.red);
      expect(adminStyle.side!.resolve({}), const BorderSide(color: Colors.red));
      for (final style in [hoursStyle, adminStyle]) {
        expect(style.padding!.resolve({}), const EdgeInsets.symmetric(horizontal: 4, vertical: 11));
        expect(style.textStyle!.resolve({})!.fontSize, 12);
        expect(style.textStyle!.resolve({})!.fontWeight, FontWeight.w600);
      }
      // The two side-by-side buttons share the row equally; the 20 px screen
      // padding is unchanged on both sides.
      expect(tester.getSize(hours).width, closeTo(tester.getSize(admin).width, 0.5));
      final row = tester.getSize(hours).width + tester.getSize(admin).width + 8;
      expect(row, closeTo(390 - 40, 0.5));
    });

    testWidgets('with one service everything fits and the buttons sit under it', (tester) async {
      await openOn(tester, _backend(user: adminProvider));

      expect(find.text('Fix pipes'), findsOneWidget);
      expect(tester.getBottomLeft(find.text('Fix pipes')).dy,
          lessThan(tester.getTopLeft(actions).dy));
      expect(tester.takeException(), isNull);
    });

    testWidgets('with many services only the content scrolls; the buttons do not move',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider, services: manyServices(15)));
      final before = positions(tester);
      final headerBefore = tester.getTopLeft(find.text('Ahmad Ali')).dy;

      expect(find.text('Service 15').hitTestable(), findsNothing); // below the fold
      await tester.dragUntilVisible(find.text('Service 15'), scroll, const Offset(0, -300));
      await tester.pumpAndSettle();

      expect(find.text('Service 15').hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(find.text('Ahmad Ali')).dy, lessThan(headerBefore)); // content moved
      expect(positions(tester), before); // buttons did not
      // The last service is above the buttons, never hidden behind them.
      expect(tester.getBottomLeft(find.text('Service 15')).dy,
          lessThanOrEqualTo(tester.getTopLeft(actions).dy));
    });

    for (final (label, page) in [
      ('ساعات الحجز', 'AVAILABILITY 10'),
      ('الإدارة', 'ADMIN PAGE'),
      ('تعديل الملف الشخصي', 'EDIT PROFILE ahmad@example.com'),
    ]) {
      testWidgets('«$label» stays clickable after scrolling to the end', (tester) async {
        await openOn(tester, _backend(user: adminProvider, services: manyServices(15)));
        await tester.drag(scroll, const Offset(0, -3000));
        await tester.pumpAndSettle();

        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(page), findsOneWidget);
      });
    }

    testWidgets('editing a service still works from the scrolled list', (tester) async {
      await openOn(tester, _backend(user: adminProvider, services: manyServices(15)));
      await tester.dragUntilVisible(find.text('Service 15'), scroll, const Offset(0, -300));
      await tester.pumpAndSettle();

      final lastCard = find.ancestor(of: find.text('Service 15'), matching: find.byType(Card));
      await tester.tap(find.descendant(of: lastCard, matching: find.byTooltip('تعديل الخدمة')));
      await tester.pumpAndSettle();
      expect(find.text('EDIT SERVICE 115'), findsOneWidget);
    });

    testWidgets('pull-to-refresh still reloads the profile', (tester) async {
      final backend = _backend(user: adminProvider);
      await openOn(tester, backend);

      await tester.fling(scroll, const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /users/me'), 2);
    });

    testWidgets('the buttons stay above the bottom system inset', (tester) async {
      await openOn(tester, _backend(user: adminProvider, services: manyServices(10)),
          size: const Size(390, 844), bottomInset: 34);

      expect(tester.getBottomLeft(edit).dy, lessThanOrEqualTo(844 - 34));
      expect(edit.hitTestable(), findsOneWidget);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('${mode.name} mode: fixed buttons and scrolling work', (tester) async {
        await openOn(tester, _backend(user: adminProvider, services: manyServices(12)),
            themeMode: mode);
        final before = positions(tester);

        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pumpAndSettle();

        expect(positions(tester), before);
        for (final button in [hours, admin, edit]) {
          expect(button.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in const [Size(320, 480), Size(360, 640), Size(414, 896), Size(800, 1400)]) {
      testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await openOn(tester, _backend(user: adminProvider, services: manyServices(8)), size: size);

        expect(tester.takeException(), isNull); // a RenderFlex overflow would be reported here
        for (final button in [hours, admin, edit]) {
          expect(button.hitTestable(), findsOneWidget);
        }
        await tester.drag(scroll, const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(find.text('Service 8').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a regular user (no hours/admin buttons) still gets the fixed edit button',
        (tester) async {
      await openOn(tester, _backend(services: manyServices(15)));
      final before = tester.getTopLeft(edit);

      await tester.drag(scroll, const Offset(0, -3000));
      await tester.pumpAndSettle();

      expect(find.text('ساعات الحجز'), findsNothing);
      expect(find.text('الإدارة'), findsNothing);
      expect(tester.getTopLeft(edit), before);
    });
  });

  group('adaptive layout: no empty gap above the buttons', () {
    final scroll = find.byKey(const Key('profile-scroll'));
    final actions = find.byKey(const Key('profile-actions'));
    final edit = find.widgetWithText(ElevatedButton, 'تعديل الملف الشخصي');
    // The first row of buttons (ساعات الحجز / الإدارة) for a provider-admin.
    final hours = find.ancestor(
      of: find.text('ساعات الحجز'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    final admin = find.ancestor(
      of: find.text('الإدارة'),
      matching: find.byWidgetPredicate((w) => w is OutlinedButton),
    );
    final adminProvider = _user(role: 'admin', provider: true);

    List<Map<String, dynamic>> services(int n) =>
        [for (var i = 1; i <= n; i++) _service(100 + i, 'Service $i')];

    Future<void> openOn(
      WidgetTester tester,
      RoutedBackend backend, {
      Size size = const Size(390, 844),
      double bottomInset = 0,
      ThemeMode? themeMode,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = FakeViewPadding(bottom: bottomInset);
      tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_screen(backend, themeMode: themeMode));
      await tester.pumpAndSettle();
    }

    /// Bottom edge of the LAST service card (its margin included — the card
    /// is the last thing in the content, exactly as in the original design).
    double lastServiceBottom(WidgetTester tester) =>
        tester.getBottomLeft(find.byType(Card).last).dy;

    /// Top edge of the first row of buttons.
    double firstButtonTop(WidgetTester tester, {bool provider = true}) =>
        tester.getTopLeft(provider ? hours : edit).dy;

    double maxScroll(WidgetTester tester) => tester
        .state<ScrollableState>(find.descendant(of: scroll, matching: find.byType(Scrollable)))
        .position
        .maxScrollExtent;

    // (count, screen height): four services still fit on a taller screen.
    for (final (count, height) in [(1, 844.0), (2, 844.0), (4, 1100.0)]) {
      testWidgets('$count service(s): the buttons sit exactly 15 px under the last service',
          (tester) async {
        await openOn(tester, _backend(user: adminProvider, services: services(count)),
            size: Size(390, height));

        expect(find.byType(Card), findsNWidgets(count));
        expect(firstButtonTop(tester) - lastServiceBottom(tester), closeTo(15, 0.01));
        // The content fits: nothing to scroll, and the scroll view is no
        // taller than its content (no stretched empty area).
        expect(maxScroll(tester), 0);
        // The free space is BELOW the buttons now, not between them and the list.
        expect(tester.getBottomLeft(actions).dy, lessThan(height));
      });
    }

    testWidgets('a user without services: the buttons follow the empty-list message',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider, services: []));

      final message = tester.getBottomLeft(find.text('لم تنشر أي خدمة بعد.')).dy;
      expect(firstButtonTop(tester) - message, closeTo(15, 0.01));
    });

    testWidgets('a regular user: the buttons area starts 15 px under the last service',
        (tester) async {
      await openOn(tester, _backend(services: services(2)));

      // 15 px gap, then the (empty, for a regular user) first row and the
      // 10 px that always separated it from «تعديل الملف الشخصي» in the
      // original design: 25 px in total, no extra gap.
      expect(tester.getTopLeft(actions).dy, closeTo(lastServiceBottom(tester), 0.01));
      expect(firstButtonTop(tester, provider: false) - lastServiceBottom(tester),
          closeTo(15 + 10, 0.01));
      expect(maxScroll(tester), 0);
    });

    testWidgets('15 services: the content scrolls and the buttons are fixed at the bottom',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider, services: services(15)));

      expect(maxScroll(tester), greaterThan(0));
      // The scroll view fills the space above the buttons (no gap), and the
      // buttons end at the bottom of the screen (20 px screen padding).
      expect(tester.getBottomLeft(scroll).dy, closeTo(tester.getTopLeft(actions).dy, 0.01));
      expect(tester.getBottomLeft(edit).dy, closeTo(844 - 20, 0.01));

      final before = tester.getTopLeft(edit);
      await tester.dragUntilVisible(find.text('Service 15'), scroll, const Offset(0, -300));
      await tester.drag(scroll, const Offset(0, -3000)); // all the way down
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(edit), before);
      // At the end of the list the last service is fully visible, again
      // exactly 15 px above the buttons — never behind them.
      expect(find.text('Service 15').hitTestable(), findsOneWidget);
      expect(firstButtonTop(tester) - lastServiceBottom(tester), closeTo(15, 0.01));
    });

    testWidgets('few services: all three buttons are clickable', (tester) async {
      await openOn(tester, _backend(user: adminProvider));
      for (final (button, page) in [
        (hours, 'AVAILABILITY 10'),
        (admin, 'ADMIN PAGE'),
        (edit, 'EDIT PROFILE ahmad@example.com'),
      ]) {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text(page), findsOneWidget);
        await tester.tap(find.text(page)); // the stub closes itself
        await tester.pumpAndSettle();
      }
    });

    testWidgets('pull-to-refresh works on short content too', (tester) async {
      final backend = _backend(user: adminProvider);
      await openOn(tester, backend);

      await tester.fling(scroll, const Offset(0, 400), 1000);
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /users/me'), 2);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('${mode.name} mode: no gap with one service, fixed with fifteen',
          (tester) async {
        await openOn(tester, _backend(user: adminProvider), themeMode: mode);
        expect(firstButtonTop(tester) - lastServiceBottom(tester), closeTo(15, 0.01));

        await tester.pumpWidget(const SizedBox()); // start again from scratch
        await openOn(tester, _backend(user: adminProvider, services: services(15)),
            themeMode: mode);
        expect(maxScroll(tester), greaterThan(0));
        expect(tester.getBottomLeft(edit).dy, closeTo(844 - 20, 0.01));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('with a bottom system inset: no gap when short, above the inset when long',
        (tester) async {
      await openOn(tester, _backend(user: adminProvider), bottomInset: 34);
      expect(firstButtonTop(tester) - lastServiceBottom(tester), closeTo(15, 0.01));

      await tester.pumpWidget(const SizedBox());
      await openOn(tester, _backend(user: adminProvider, services: services(15)), bottomInset: 34);
      expect(tester.getBottomLeft(edit).dy, closeTo(844 - 34 - 20, 0.01));
    });

    testWidgets('320x480: one service works without overflow', (tester) async {
      await openOn(tester, _backend(user: adminProvider), size: const Size(320, 480));

      expect(tester.takeException(), isNull);
      for (final button in [hours, admin, edit]) {
        expect(button.hitTestable(), findsOneWidget);
      }
      // On so small a screen the header alone fills it: the content scrolls
      // and the single service is reachable, 15 px above the buttons.
      await tester.drag(scroll, const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(find.text('Fix pipes').hitTestable(), findsOneWidget);
      expect(firstButtonTop(tester) - lastServiceBottom(tester), closeTo(15, 0.01));
    });
  });
}
