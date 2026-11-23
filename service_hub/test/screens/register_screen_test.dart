import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/shared/widgets/city_picker_field.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/data/city_service.dart';
import 'package:service_hub/features/auth/register_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _cities = ['دمشق', 'حلب'];
const _user = {
  'id': 1,
  'email': 'a@b.com',
  'role': 'user',
  'is_provider': false,
  'is_active': true,
};
const _tokens = {'access_token': 'acc', 'refresh_token': 'ref'};

RoutedBackend _backend({Map<String, Reply> extra = const {}}) => RoutedBackend({
      'GET /cities': const Reply(_cities),
      'POST /auth/register': const Reply(_user, status: 201),
      'POST /auth/login': const Reply(_tokens),
      ...extra,
    });

Widget _app(RoutedBackend backend) {
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  return MaterialApp(
    home: RegisterScreen(
      authService: AuthService(apiClient: api, tokenStore: store),
      cityService: CityService(apiClient: api),
      homeBuilder: (_) => const Scaffold(body: Text('HOME SCREEN')),
    ),
  );
}

Future<void> _pumpScreen(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String name = 'Ahmad Ali',
  String email = 'a@b.com',
  String password = 'Secret123!',
  String? confirm,
  String phone = '0912345678',
}) async {
  // Field order on screen: name, email, phone, password, confirm password.
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), name);
  await tester.enterText(fields.at(1), email);
  await tester.enterText(fields.at(2), phone);
  await tester.enterText(fields.at(3), password);
  await tester.enterText(fields.at(4), confirm ?? password);
}

Future<void> _pickCity(WidgetTester tester, String city) async {
  await tester.tap(find.byType(CityPickerField));
  await tester.pumpAndSettle();
  await tester.tap(find.text(city).last);
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.text('إنشاء الحساب'));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('loads the city list from the backend', (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    expect(backend.callsTo('GET /cities'), 1);
    expect(find.byType(CityPickerField), findsOneWidget);

    await tester.tap(find.byType(CityPickerField));
    await tester.pumpAndSettle();
    expect(find.text('دمشق'), findsWidgets);
    expect(find.text('حلب'), findsWidgets);
  });

  testWidgets('shows a progress bar while cities are loading', (tester) async {
    useTallScreen(tester);
    await tester.pumpWidget(_app(_backend()));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('shows an error when the cities cannot be loaded', (tester) async {
    final backend = _backend(extra: {
      'GET /cities': const Reply({'detail': 'db down'}, status: 500),
    });
    await _pumpScreen(tester, backend);

    expect(find.text('تعذّر تحميل المدن: db down'), findsOneWidget);
    expect(find.byType(CityPickerField), findsNothing);
  });

  testWidgets('rejects a too short name or password without calling the API',
      (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, password: 'short');
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsWidgets);
    expect(backend.callsTo('POST /auth/register'), 0);
  });

  testWidgets('the rules are hidden until the field is tapped',
      (tester) async {
    await _pumpScreen(tester, _backend());
    final fields = find.byType(TextField);

    expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsNothing);
    expect(find.text('يجب أن يتكون رقم الجوال من 10 أرقام أو أكثر'), findsNothing);
    expect(find.text('تأكيد كلمة المرور'), findsOneWidget);

    await tester.tap(fields.at(3)); // password
    await tester.pump();
    expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsOneWidget);
    expect(find.text('يجب أن يتكون رقم الجوال من 10 أرقام أو أكثر'), findsNothing);

    await tester.tap(fields.at(2)); // phone
    await tester.pump();
    expect(find.text('يجب أن يتكون رقم الجوال من 10 أرقام أو أكثر'), findsOneWidget);
    expect(find.text('يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر'), findsNothing);
  });

  testWidgets('rejects a confirmation that does not match the password',
      (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, confirm: 'Different123');
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('كلمتا المرور غير متطابقتين'), findsWidgets);
    expect(backend.callsTo('POST /auth/register'), 0);
  });

  testWidgets('rejects a phone number with fewer than 10 digits',
      (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, phone: '091234567');
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('يجب أن يتكون رقم الجوال من 10 أرقام أو أكثر'), findsWidgets);
    expect(backend.callsTo('POST /auth/register'), 0);
  });

  testWidgets('requires a city', (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester);
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('يرجى اختيار مدينتك.'), findsOneWidget);
    expect(backend.callsTo('POST /auth/register'), 0);
  });

  testWidgets('registers, logs in automatically and opens home', (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, name: '  Ahmad Ali  ', email: ' a@b.com ');
    await _pickCity(tester, 'حلب');
    await _submit(tester);
    await tester.pumpAndSettle();

    expect(backend.lastBodyOf('POST /auth/register'), {
      'email': 'a@b.com',
      'password': 'Secret123!',
      'full_name': 'Ahmad Ali',
      'city': 'حلب',
      'phone_number': '0912345678',
    });
    expect(backend.callsTo('POST /auth/login'), 1);
    expect(await TokenStore().accessToken, 'acc');
    expect(find.text('HOME SCREEN'), findsOneWidget);
    expect(find.byType(RegisterScreen), findsNothing);
  });

  testWidgets('the phone number is required', (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, phone: '');
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('رقم الجوال مطلوب'), findsWidgets);
    expect(backend.callsTo('POST /auth/register'), 0);
  });

  testWidgets('Arabic-Indic digits in the phone are converted', (tester) async {
    final backend = _backend();
    await _pumpScreen(tester, backend);

    await _fill(tester, phone: '٠٩١٢٣٤٥٦٧٨');
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await tester.pumpAndSettle();

    expect(backend.lastBodyOf('POST /auth/register')['phone_number'], '0912345678');
  });

  testWidgets('a taken email shows the server message and does not log in',
      (tester) async {
    final backend = _backend(extra: {
      'POST /auth/register': const Reply(
        {'detail': 'يوجد حساب مسجّل بهذا البريد الإلكتروني مسبقاً'},
        status: 409,
      ),
    });
    await _pumpScreen(tester, backend);

    await _fill(tester);
    await _pickCity(tester, 'دمشق');
    await _submit(tester);
    await pumpFrames(tester);

    expect(find.text('يوجد حساب مسجّل بهذا البريد الإلكتروني مسبقاً'), findsOneWidget);
    expect(backend.callsTo('POST /auth/login'), 0);
    expect(find.byType(RegisterScreen), findsOneWidget);
    expect(await TokenStore().isLoggedIn, isFalse);
  });
}
