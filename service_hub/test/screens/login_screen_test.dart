import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _tokens = {
  'access_token': 'acc',
  'refresh_token': 'ref',
  'token_type': 'bearer',
};

/// How many times the login screen asked to set up push notifications.
/// Firebase is not initialized in widget tests, so a counter stands in for
/// the real PushNotificationService.
int _pushSetupCalls = 0;

Widget _app(RoutedBackend backend) {
  final store = TokenStore();
  return MaterialApp(
    home: LoginScreen(
      authService: AuthService(
        apiClient: apiFor(backend, tokenStore: store),
        tokenStore: store,
      ),
      homeBuilder: (_) => const Scaffold(body: Text('HOME SCREEN')),
      pushSetup: () async => _pushSetupCalls++,
    ),
  );
}

Future<void> _fillAndSubmit(WidgetTester tester,
    {String email = 'a@b.com', String password = 'Secret123!'}) async {
  await tester.enterText(find.byType(TextField).at(0), email);
  await tester.enterText(find.byType(TextField).at(1), password);
  await tester.tap(find.text('تسجيل الدخول'));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _pushSetupCalls = 0;
  });

  testWidgets('shows the form', (tester) async {
    await tester.pumpWidget(_app(RoutedBackend({})));

    expect(find.text('مَهارة'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('إنشاء حساب'), findsOneWidget);
  });

  testWidgets('the tagline calls MAHARA an app, not a platform', (tester) async {
    await tester.pumpWidget(_app(RoutedBackend({})));

    expect(find.text('تطبيقك لتبادل الخدمات والمهارات'), findsOneWidget);
    expect(find.textContaining('منصّتك'), findsNothing);
    expect(find.textContaining('منصتك'), findsNothing);
  });

  testWidgets('has a forgot-password link that opens the recovery screen',
      (tester) async {
    await tester.pumpWidget(_app(RoutedBackend({})));

    await tester.tap(find.text('نسيت كلمة المرور؟'));
    await tester.pumpAndSettle();

    expect(find.text('إرسال رمز التحقق'), findsOneWidget);
  });

  testWidgets('password field is obscured and email is not', (tester) async {
    await tester.pumpWidget(_app(RoutedBackend({})));

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields[0].obscureText, isFalse);
    expect(fields[1].obscureText, isTrue);
  });

  testWidgets('empty fields show a hint and send no request', (tester) async {
    final backend = RoutedBackend({});
    await tester.pumpWidget(_app(backend));

    await tester.tap(find.text('تسجيل الدخول'));
    await pumpFrames(tester);

    expect(find.text('يرجى إدخال البريد الإلكتروني وكلمة المرور.'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testWidgets('a missing password is also rejected locally', (tester) async {
    final backend = RoutedBackend({});
    await tester.pumpWidget(_app(backend));

    await tester.enterText(find.byType(TextField).at(0), 'a@b.com');
    await tester.tap(find.text('تسجيل الدخول'));
    await pumpFrames(tester);

    expect(find.text('يرجى إدخال البريد الإلكتروني وكلمة المرور.'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testWidgets('successful login sends the trimmed email, saves tokens, opens home',
      (tester) async {
    final backend = RoutedBackend({'POST /auth/login': const Reply(_tokens)});
    await tester.pumpWidget(_app(backend));

    await _fillAndSubmit(tester, email: '  a@b.com  ');
    await tester.pumpAndSettle();

    expect(backend.lastBodyOf('POST /auth/login'),
        {'email': 'a@b.com', 'password': 'Secret123!'});
    expect(await TokenStore().accessToken, 'acc');
    expect(await TokenStore().refreshToken, 'ref');
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    expect(_pushSetupCalls, 1);
  });

  testWidgets('wrong credentials show the server message and stay on screen',
      (tester) async {
    final backend = RoutedBackend({
      'POST /auth/login':
          const Reply({'detail': 'البريد الإلكتروني أو كلمة المرور غير صحيحة'}, status: 401),
    });
    await tester.pumpWidget(_app(backend));

    await _fillAndSubmit(tester, password: 'wrong');
    await pumpFrames(tester);

    expect(find.text('البريد الإلكتروني أو كلمة المرور غير صحيحة'), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('HOME SCREEN'), findsNothing);
    expect(await TokenStore().isLoggedIn, isFalse);
    expect(_pushSetupCalls, 0);
  });

  testWidgets('shows a spinner and disables the button while logging in',
      (tester) async {
    final backend = RoutedBackend({'POST /auth/login': const Reply(_tokens)})
      ..gate = Completer<void>();
    await tester.pumpWidget(_app(backend));

    await _fillAndSubmit(tester);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    backend.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('HOME SCREEN'), findsOneWidget);
  });

  testWidgets('the button works again after a failed attempt', (tester) async {
    final backend = RoutedBackend({
      'POST /auth/login': const Reply({'detail': 'nope'}, status: 401),
    });
    await tester.pumpWidget(_app(backend));

    await _fillAndSubmit(tester);
    await pumpFrames(tester);

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNotNull,
    );
  });
}
