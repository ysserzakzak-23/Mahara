import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/forgot_password_screen.dart';
import 'package:service_hub/features/auth/reset_password_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _okMessage = {'message': 'تم'};

AuthService _auth(RoutedBackend backend) {
  final store = TokenStore();
  return AuthService(apiClient: apiFor(backend, tokenStore: store), tokenStore: store);
}

Widget _forgotApp(RoutedBackend backend, {String initialEmail = ''}) =>
    MaterialApp(
      home: ForgotPasswordScreen(
        authService: _auth(backend),
        initialEmail: initialEmail,
      ),
    );

Widget _resetApp(RoutedBackend backend) => MaterialApp(
      home: Scaffold(body: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ResetPasswordScreen(
                email: 'a@b.com',
                authService: _auth(backend),
              ),
            ),
          ),
          child: const Text('OPEN'),
        ),
      )),
    );

Future<void> _openReset(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_resetApp(backend));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

Future<void> _fillReset(
  WidgetTester tester, {
  String code = '123456',
  String password = 'NewSecret123',
  String? confirm,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), code);
  await tester.enterText(fields.at(1), password);
  await tester.enterText(fields.at(2), confirm ?? password);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ForgotPasswordScreen', () {
    testWidgets('prefills the email typed on the login screen', (tester) async {
      useTallScreen(tester);
      await tester.pumpWidget(
          _forgotApp(RoutedBackend({}), initialEmail: 'a@b.com'));

      expect(find.text('a@b.com'), findsOneWidget);
    });

    testWidgets('rejects an invalid email without calling the API',
        (tester) async {
      final backend = RoutedBackend({});
      useTallScreen(tester);
      await tester.pumpWidget(_forgotApp(backend));

      await tester.enterText(find.byType(TextField), 'not-an-email');
      await tester.tap(find.text('إرسال رمز التحقق'));
      await pumpFrames(tester);

      expect(find.text('أدخل بريداً إلكترونياً صحيحاً'), findsWidgets);
      expect(backend.requests, isEmpty);
    });

    testWidgets('sends the email and moves to the reset screen', (tester) async {
      final backend =
          RoutedBackend({'POST /auth/forgot-password': const Reply(_okMessage)});
      useTallScreen(tester);
      await tester.pumpWidget(_forgotApp(backend));

      await tester.enterText(find.byType(TextField), '  a@b.com ');
      await tester.tap(find.text('إرسال رمز التحقق'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('POST /auth/forgot-password'), {'email': 'a@b.com'});
      expect(find.text('تعيين كلمة مرور جديدة'), findsOneWidget);
    });
  });

  group('ResetPasswordScreen', () {
    testWidgets('shows the password rule only when the field is tapped',
        (tester) async {
      await _openReset(tester, RoutedBackend({}));

      expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsNothing);
      await tester.tap(find.byType(TextField).at(1));
      await tester.pump();
      expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsOneWidget);
      expect(find.text('تأكيد كلمة المرور الجديدة'), findsOneWidget);
    });

    testWidgets('rejects a short password', (tester) async {
      final backend = RoutedBackend({});
      await _openReset(tester, backend);

      await _fillReset(tester, password: 'short');
      await tester.tap(find.text('تغيير كلمة المرور'));
      await pumpFrames(tester);

      expect(backend.requests, isEmpty);
    });

    testWidgets('rejects mismatching passwords', (tester) async {
      final backend = RoutedBackend({});
      await _openReset(tester, backend);

      await _fillReset(tester, confirm: 'Different123');
      await tester.tap(find.text('تغيير كلمة المرور'));
      await pumpFrames(tester);

      expect(find.text('كلمتا المرور غير متطابقتين'), findsWidgets);
      expect(backend.requests, isEmpty);
    });

    testWidgets('rejects a code that is not 6 digits', (tester) async {
      final backend = RoutedBackend({});
      await _openReset(tester, backend);

      await _fillReset(tester, code: '123');
      await tester.tap(find.text('تغيير كلمة المرور'));
      await pumpFrames(tester);

      expect(find.text('أدخل رمز التحقق المكوّن من 6 أرقام'), findsWidgets);
      expect(backend.requests, isEmpty);
    });

    testWidgets('submits email, code and new password', (tester) async {
      final backend =
          RoutedBackend({'POST /auth/reset-password': const Reply(_okMessage)});
      await _openReset(tester, backend);

      await _fillReset(tester);
      await tester.tap(find.text('تغيير كلمة المرور'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('POST /auth/reset-password'), {
        'email': 'a@b.com',
        'code': '123456',
        'new_password': 'NewSecret123',
      });
      // Back on the first screen of the stack.
      expect(find.text('OPEN'), findsOneWidget);
    });

    testWidgets('shows the server message when the code is wrong',
        (tester) async {
      final backend = RoutedBackend({
        'POST /auth/reset-password': const Reply(
          {'detail': 'رمز التحقق غير صحيح أو منتهي الصلاحية'},
          status: 422,
        ),
      });
      await _openReset(tester, backend);

      await _fillReset(tester);
      await tester.tap(find.text('تغيير كلمة المرور'));
      await pumpFrames(tester);

      expect(find.text('رمز التحقق غير صحيح أو منتهي الصلاحية'), findsOneWidget);
      expect(find.text('تعيين كلمة مرور جديدة'), findsOneWidget);
    });

    testWidgets('resend is disabled during the cooldown', (tester) async {
      await _openReset(tester, RoutedBackend({}));

      expect(find.textContaining('إعادة إرسال الرمز بعد'), findsOneWidget);
      await tester.pump(const Duration(seconds: 61));
      expect(find.text('إعادة إرسال الرمز'), findsOneWidget);
    });
  });
}
