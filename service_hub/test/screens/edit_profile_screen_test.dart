import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/shared/widgets/city_picker_field.dart';
import 'package:service_hub/core/api/upload_service.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_models.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/auth/data/city_service.dart';
import 'package:service_hub/features/profile/edit_profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';
import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _userJson = {
  'id': 1,
  'email': 'ahmad@example.com',
  'role': 'user',
  'is_provider': false,
  'is_active': true,
  'profile': {
    'full_name': 'Ahmad Ali',
    'phone_number': '0912345678',
    'bio': 'I fix things',
    'city': 'دمشق',
    'avatar_url': null,
  },
};

RoutedBackend _backend({Map<String, Reply> extra = const {}}) => RoutedBackend({
      'GET /cities': const Reply(['دمشق', 'حلب', 'حمص']),
      'PATCH /users/me': const Reply(_userJson),
      'POST /uploads/image': const Reply({'url': '/uploads/avatar.png'}),
      ...extra,
    });

Future<void> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  FakeImagePicker? picker,
  Map<String, dynamic> user = _userJson,
}) async {
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  await openFromLauncher(
    tester,
    (_) => EditProfileScreen(
      user: AppUser.fromJson(user),
      authService: AuthService(apiClient: api, tokenStore: store),
      uploadService: UploadService(apiClient: api),
      cityService: CityService(apiClient: api),
      imagePicker: picker ?? FakeImagePicker(),
    ),
  );
}

String _textOf(WidgetTester tester, int i) =>
    tester.widget<TextField>(find.byType(TextField).at(i)).controller!.text;

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.text('حفظ التغييرات'));
  await pumpFrames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  testWidgets('pre-fills the form from the current profile', (tester) async {
    await _open(tester, _backend());

    expect(find.text('تعديل الملف الشخصي'), findsOneWidget);
    expect(_textOf(tester, 0), 'Ahmad Ali');
    expect(_textOf(tester, 1), '0912345678');
    expect(_textOf(tester, 2), 'I fix things');
    expect(find.text('دمشق'), findsOneWidget); // selected city
  });

  testWidgets('a cities failure is shown instead of the dropdown', (tester) async {
    await _open(tester, _backend(extra: {'GET /cities': const Reply({'detail': 'boom'}, status: 500)}));
    expect(find.text('تعذّر تحميل المدن: boom'), findsOneWidget);
  });

  group('saving', () {
    testWidgets('an untouched form sends the current values and closes', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await _save(tester);

      final body = backend.lastBodyOf('PATCH /users/me');
      expect(body, {
        'full_name': 'Ahmad Ali',
        'phone_number': '0912345678',
        'bio': 'I fix things',
        'city': 'دمشق',
      });
      expect(find.text('تم تحديث الملف الشخصي.'), findsOneWidget);
      expect(find.byType(EditProfileScreen), findsNothing);
    });

    testWidgets('edited fields are trimmed and sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(find.byType(TextField).at(0), '  Ahmad A.  ');
      await tester.enterText(find.byType(TextField).at(2), '  new bio  ');
      await _save(tester);

      final body = backend.lastBodyOf('PATCH /users/me');
      expect(body['full_name'], 'Ahmad A.');
      expect(body['bio'], 'new bio');
    });

    testWidgets('the city can be changed', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byType(CityPickerField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('حلب').last);
      await tester.pumpAndSettle();
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /users/me')['city'], 'حلب');
    });

    testWidgets('an empty phone number is sent as empty so it can be cleared', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(find.byType(TextField).at(1), '');
      await _save(tester);

      expect(backend.lastBodyOf('PATCH /users/me'), containsPair('phone_number', ''));
    });

    testWidgets('a too short name is rejected locally', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.enterText(find.byType(TextField).at(0), 'A');
      await _save(tester);

      expect(find.text('الاسم يجب أن يتكون من حرفين على الأقل.'), findsOneWidget);
      expect(backend.callsTo('PATCH /users/me'), 0);
    });

    testWidgets('a backend error is shown and the screen stays', (tester) async {
      final backend = _backend(extra: {
        'PATCH /users/me': const Reply({'detail': 'Unknown city'}, status: 422),
      });
      await _open(tester, backend);

      await _save(tester);

      expect(find.text('Unknown city'), findsOneWidget);
      expect(find.byType(EditProfileScreen), findsOneWidget);
    });
  });

  group('profile photo', () {
    testWidgets('a picked photo is uploaded immediately and saved with the profile', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /uploads/image'), 1);

      await _save(tester);
      expect(backend.lastBodyOf('PATCH /users/me'), containsPair('avatar_url', '/uploads/avatar.png'));
    });

    testWidgets('cancelling the gallery does nothing', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(null));

      await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /uploads/image'), 0);
      expect(find.byIcon(Icons.person), findsOneWidget);
    });

    testWidgets('an upload failure is reported with its reason', (tester) async {
      final backend = _backend(extra: {
        'POST /uploads/image': const Reply({'detail': 'File too large'}, status: 413),
      });
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));

      await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
      await pumpFrames(tester);

      expect(find.text('تعذّر رفع الصورة: File too large'), findsOneWidget);
    });

    testWidgets('removing the photo is saved as an explicit null', (tester) async {
      final backend = _backend();
      await _open(tester, backend, picker: FakeImagePicker(fakeImageFile()));
      await tester.tap(find.byIcon(Icons.add_a_photo_outlined));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.byIcon(Icons.person), findsOneWidget); // back to the placeholder

      await _save(tester);
      expect(backend.lastBodyOf('PATCH /users/me'), containsPair('avatar_url', null));
    });
  });
}
