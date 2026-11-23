// The simulated iPhone 13 frame is how the app is presented in the browser
// (Flutter Web in Chrome). On real Android/iOS devices the app is NOT wrapped:
// it uses the actual screen size and the device's own safe areas.
//
// Runs on the VM (`flutter test`), where kIsWeb is false like on a phone, and
// in a browser (`flutter test --platform chrome test/app_frame_test.dart`),
// where kIsWeb is true.

import 'package:device_frame/device_frame.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/theme/theme_controller.dart';
import 'package:service_hub/features/auth/login_screen.dart';
import 'package:service_hub/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone-like screen: 412x915 logical pixels with a 32 px status bar and a
/// 24 px gesture bar.
void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
  addTearDown(tester.view.reset);
}

/// The widget-test font draws every glyph as a full square, far wider than
/// real Arabic text, so the login screen's «ليس لديك حساب؟ إنشاء حساب» row
/// does not fit the 390 px iPhone 13 canvas in tests (it does with real fonts
/// in a browser). That one layout report is expected inside the frame; any
/// other error still fails the test.
void _allowTestFontOverflowInFrame(WidgetTester tester) {
  final error = tester.takeException();
  if (error != null) {
    expect(error.toString(), contains('A RenderFlex overflowed'));
  }
}

/// The MediaQuery the app's screens actually see.
MediaQueryData _appMediaQuery(WidgetTester tester) =>
    MediaQuery.of(tester.element(find.byType(LoginScreen)));

void main() {
  setUp(() {
    // No stored token: the app opens on the login screen, with no network.
    SharedPreferences.setMockInitialValues({});
    ThemeController.mode.value = ThemeMode.light;
  });

  group('default: decided by the platform', () {
    test('the frame is on exactly when running on the web', () {
      expect(const MyApp().showDeviceFrame, kIsWeb);
    });

    testWidgets('web shows the iPhone 13 frame; Android/iOS show none', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      if (kIsWeb) _allowTestFontOverflowInFrame(tester);

      expect(find.byType(DeviceFrame), kIsWeb ? findsOneWidget : findsNothing);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('in the browser (frame on)', () {
    testWidgets('the app is shown inside the same iPhone 13 frame as before', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp(showDeviceFrame: true));
      await tester.pumpAndSettle();
      _allowTestFontOverflowInFrame(tester);

      final frame = tester.widget<DeviceFrame>(find.byType(DeviceFrame));
      expect(frame.device, Devices.ios.iPhone13);
      expect(frame.isFrameVisible, isTrue);
      expect(frame.orientation, Orientation.portrait);
      // The whole app lives inside the frame...
      expect(
        find.descendant(of: find.byType(DeviceFrame), matching: find.byType(LoginScreen)),
        findsOneWidget,
      );
      // ...and sees the simulated iPhone 13 screen, not the real window.
      expect(_appMediaQuery(tester).size, Devices.ios.iPhone13.screenSize);
      expect(_appMediaQuery(tester).padding, Devices.ios.iPhone13.safeAreas);
    });

    testWidgets('the app still works inside the frame', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp(showDeviceFrame: true));
      await tester.pumpAndSettle();
      _allowTestFontOverflowInFrame(tester);

      await tester.tap(find.text('تسجيل الدخول'), warnIfMissed: false);
      await tester.pump();
      expect(find.text('يرجى إدخال البريد الإلكتروني وكلمة المرور.'), findsOneWidget);
    });
  });

  group('on a real phone (frame off)', () {
    testWidgets('no simulated frame: the real screen size and safe areas are used',
        (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp(showDeviceFrame: false));
      await tester.pumpAndSettle();

      expect(find.byType(DeviceFrame), findsNothing);
      final media = _appMediaQuery(tester);
      expect(media.size, const Size(412, 915));                 // the actual device
      expect(media.size, isNot(Devices.ios.iPhone13.screenSize));
      expect(media.padding.top, 32);                            // its real status bar
      expect(media.padding.bottom, 24);                         // and gesture bar
      // The login screen fills the whole window.
      expect(tester.getSize(find.byType(LoginScreen)), const Size(412, 915));
    });

    testWidgets('it stays Arabic and right-to-left', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp(showDeviceFrame: false));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(LoginScreen));
      expect(Directionality.of(context), TextDirection.rtl);
      expect(Localizations.localeOf(context), const Locale('ar'));
    });

    testWidgets('messages, navigation and the theme switch still work', (tester) async {
      _usePhone(tester);
      await tester.pumpWidget(const MyApp(showDeviceFrame: false));
      await tester.pumpAndSettle();

      // A snack bar (validation message).
      await tester.tap(find.text('تسجيل الدخول'));
      await tester.pump();
      expect(find.text('يرجى إدخال البريد الإلكتروني وكلمة المرور.'), findsOneWidget);

      // Navigation to another screen and back.
      await tester.tap(find.text('نسيت كلمة المرور؟'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);

      // Dark mode rebuilds the app without a frame too.
      ThemeController.mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(Theme.of(tester.element(find.byType(LoginScreen))).brightness, Brightness.dark);
      expect(find.byType(DeviceFrame), findsNothing);
    });
  });
}
