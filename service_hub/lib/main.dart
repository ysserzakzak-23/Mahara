import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/push/push_notification_service.dart'; 
import 'core/api/api_client.dart';
import 'core/api/api_exception.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/auth_service.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'firebase_options.dart';
import 'package:device_frame/device_frame.dart';
import 'core/theme/theme_controller.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Push notifications simply won't work on this run (e.g. platform not
    // configured yet, or no Google Play Services on the device/emulator)
    // — everything else in the app is unaffected.
    debugPrint('Firebase initialization failed: $e');
  }
  await ThemeController.load();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({
    super.key,
    this.showDeviceFrame = kIsWeb,
    this.apiClient,
    this.authService,
    this.pushSetup,
    this.homeBuilder,
  });

  /// Whether the app is presented inside the simulated iPhone 13 frame.
  ///
  /// The frame is how the app is shown in the browser (Flutter Web in
  /// Chrome), so it defaults to [kIsWeb]. On a real Android or iOS device
  /// it is off: the app fills the actual screen and uses the device's own
  /// size and safe areas. (A parameter only so tests can check both.)
  final bool showDeviceFrame;

  /// Optional overrides, mainly so widget tests can inject a fake backend
  /// and stand-in destinations. In the real app all are null.
  final ApiClient? apiClient;
  final AuthService? authService;
  final Future<void> Function()? pushSetup;
  final WidgetBuilder? homeBuilder;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late final ApiClient _api = widget.apiClient ?? ApiClient.shared;
  late final AuthService _authService =
      widget.authService ?? AuthService(apiClient: _api);

  /// Changed to send the app back to the login screen: once when the
  /// backend refuses the stored refresh token (the session is really over),
  /// so the user is not left on a screen whose every request fails.
  final _sessionKey = GlobalKey<NavigatorState>();
  int _session = 0;

  @override
  void initState() {
    super.initState();
    _api.onSessionExpired = _onSessionExpired;
  }

  @override
  void dispose() {
    // Only this listener is given up; the shared client stays open for the
    // rest of the app (and is never closed by a screen or a service).
    if (_api.onSessionExpired == _onSessionExpired) _api.onSessionExpired = null;
    super.dispose();
  }

  void _onSessionExpired() {
    if (!mounted) return;
    // Rebuilds _Bootstrap from scratch: no stored token is left, so it
    // shows the login screen.
    setState(() => _session++);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) => MaterialApp(
        title: 'MAHARA',
        debugShowCheckedModeBanner: false,
        // The whole app is Arabic and right-to-left.
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: appTheme,
        darkTheme: darkAppTheme,
        themeMode: mode,
        navigatorKey: _sessionKey,
        // Browser only (see [showDeviceFrame]); null leaves the app unwrapped.
        builder: widget.showDeviceFrame
            ? (context, child) {
                return DeviceFrame(
                  device: Devices.ios.iPhone13,
                  isFrameVisible: true,
                  orientation: Orientation.portrait,
                  screen: child!,
                );
              }
            : null,
        home: _Bootstrap(
          // A new key on a refused session discards the old screen stack.
          key: ValueKey(_session),
          authService: _authService,
          pushSetup: widget.pushSetup,
          homeBuilder: widget.homeBuilder,
        ),
      ),
    );
  }
}

/// Decides the first screen: Home when the stored session still works,
/// Login otherwise.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({
    super.key,
    required this.authService,
    this.pushSetup,
    this.homeBuilder,
  });

  final AuthService authService;
  final Future<void> Function()? pushSetup;
  final WidgetBuilder? homeBuilder;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late final AuthService _authService = widget.authService;
  late Future<bool> _sessionCheck;

  @override
  void initState() {
    super.initState();
    _sessionCheck = _hasValidSession();
  }

  /// True when the app should open on Home.
  ///
  /// The stored access token lasts 30 minutes, so after any real break it
  /// is expired on launch. That alone is NOT the end of the session: the
  /// ApiClient refreshes it with the 7-day refresh token and the call below
  /// simply succeeds (one refresh, shared by anything else starting up).
  /// The user is sent back to Login only when the server refuses the
  /// session itself — never because the server could not be reached.
  Future<bool> _hasValidSession() async {
    if (!await _authService.isLoggedIn) return false;
    try {
      await _authService.currentUser();
      // Fire-and-forget: don't block showing Home on push registration.
      unawaited((widget.pushSetup ?? PushNotificationService().initialize)());
      return true;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        // The refresh token was refused too (ApiClient has already cleared
        // the tokens; this covers a session refused without a refresh).
        await _authService.logout();
        return false;
      }
      // Server down, no network, a 500: the session is untouched, so keep
      // the user signed in rather than logging them out over a bad moment.
      return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _sessionCheck,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return snapshot.data == true
            ? (widget.homeBuilder?.call(context) ?? const HomeScreen())
            : const LoginScreen();
      },
    );
  }
}
