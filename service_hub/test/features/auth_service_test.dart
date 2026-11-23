import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

AuthService serviceFor(FakeBackend backend, TokenStore store) => AuthService(
      apiClient: ApiClient(httpClient: backend.client, tokenStore: store),
      tokenStore: store,
    );

const userJson = {
  'id': 1,
  'email': 'a@b.com',
  'role': 'user',
  'is_provider': false,
  'is_active': true,
  'profile': {'full_name': 'Ahmad'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TokenStore store;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = TokenStore();
  });

  group('password recovery', () {
    test('forgotPassword posts the email without auth', () async {
      final backend = FakeBackend({'message': 'تم'});
      final message = await serviceFor(backend, store)
          .forgotPassword(email: 'a@b.com');

      expect(backend.last.url.path, endsWith('/auth/forgot-password'));
      expect(backend.last.headers.containsKey('Authorization'), isFalse);
      expect(backend.lastJsonBody, {'email': 'a@b.com'});
      expect(message, 'تم');
    });

    test('resetPassword posts email, code and new password', () async {
      final backend = FakeBackend({'message': 'تم'});
      await serviceFor(backend, store).resetPassword(
        email: 'a@b.com',
        code: '123456',
        newPassword: 'NewSecret123',
      );

      expect(backend.last.url.path, endsWith('/auth/reset-password'));
      expect(backend.lastJsonBody, {
        'email': 'a@b.com',
        'code': '123456',
        'new_password': 'NewSecret123',
      });
    });

    test('a wrong code surfaces the server message', () async {
      final backend = FakeBackend(
        {'detail': 'رمز التحقق غير صحيح أو منتهي الصلاحية'},
        status: 422,
      );
      await expectLater(
        serviceFor(backend, store).resetPassword(
          email: 'a@b.com', code: '000000', newPassword: 'NewSecret123',
        ),
        throwsA(isA<ApiException>().having(
            (e) => e.message, 'message', 'رمز التحقق غير صحيح أو منتهي الصلاحية')),
      );
    });
  });

  group('register', () {
    test('posts to /auth/register without auth and returns the user', () async {
      final backend = FakeBackend(userJson, status: 201);
      final user = await serviceFor(backend, store).register(
        email: 'a@b.com',
        password: 'Secret123!',
        fullName: 'Ahmad',
        city: 'Damascus',
        phoneNumber: '0912345678',
      );

      expect(backend.last.url.path, endsWith('/auth/register'));
      expect(backend.last.headers.containsKey('Authorization'), isFalse);
      expect(backend.lastJsonBody, {
        'email': 'a@b.com',
        'password': 'Secret123!',
        'full_name': 'Ahmad',
        'city': 'Damascus',
        'phone_number': '0912345678',
      });
      expect(user.id, 1);
    });

    test('omits phone_number when empty or null', () async {
      for (final phone in [null, '']) {
        final backend = FakeBackend(userJson, status: 201);
        await serviceFor(backend, store).register(
          email: 'a@b.com', password: 'p', fullName: 'A', city: 'C', phoneNumber: phone,
        );
        expect(backend.lastJsonBody.containsKey('phone_number'), isFalse);
      }
    });

    test('duplicate email surfaces as ApiException(409)', () async {
      final backend = FakeBackend({'detail': 'An account with this email already exists'}, status: 409);
      await expectLater(
        serviceFor(backend, store).register(
          email: 'a@b.com', password: 'p', fullName: 'A', city: 'C',
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
      );
    });
  });

  group('login / logout', () {
    final tokens = {'access_token': 'acc', 'refresh_token': 'ref', 'token_type': 'bearer'};

    test('login saves the token pair', () async {
      final backend = FakeBackend(tokens);
      final result = await serviceFor(backend, store).login(email: 'a@b.com', password: 'p');

      expect(result.accessToken, 'acc');
      expect(await store.accessToken, 'acc');
      expect(await store.refreshToken, 'ref');
      expect(backend.lastJsonBody, {'email': 'a@b.com', 'password': 'p'});
    });

    test('failed login stores nothing', () async {
      final backend = FakeBackend({'detail': 'Invalid email or password'}, status: 401);
      await expectLater(
        serviceFor(backend, store).login(email: 'a@b.com', password: 'bad'),
        throwsA(isA<ApiException>()),
      );
      expect(await store.isLoggedIn, isFalse);
    });

    test('isLoggedIn and logout', () async {
      final service = serviceFor(FakeBackend(tokens), store);
      expect(await service.isLoggedIn, isFalse);

      await service.login(email: 'a@b.com', password: 'p');
      expect(await service.isLoggedIn, isTrue);

      await service.logout();
      expect(await service.isLoggedIn, isFalse);
    });
  });

  test('currentUser calls GET /users/me with the stored token', () async {
    await store.saveTokens(accessToken: 'acc', refreshToken: 'ref');
    final backend = FakeBackend(userJson);

    final user = await serviceFor(backend, store).currentUser();

    expect(backend.last.url.path, endsWith('/users/me'));
    expect(backend.last.headers['Authorization'], 'Bearer acc');
    expect(user.email, 'a@b.com');
  });

  group('updateProfile', () {
    test('sends only the fields that were provided', () async {
      final backend = FakeBackend(userJson);
      await serviceFor(backend, store).updateProfile(bio: 'new bio');

      expect(backend.last.method, 'PATCH');
      expect(backend.lastJsonBody, {'bio': 'new bio'});
    });

    test('empty name and city are ignored', () async {
      final backend = FakeBackend(userJson);
      await serviceFor(backend, store).updateProfile(fullName: '', city: '');
      expect(backend.lastJsonBody, isEmpty);
    });

    test('avatarUrl sets the photo', () async {
      final backend = FakeBackend(userJson);
      await serviceFor(backend, store).updateProfile(avatarUrl: '/uploads/a.jpg');
      expect(backend.lastJsonBody['avatar_url'], '/uploads/a.jpg');
    });

    test('clearAvatar sends an explicit null and wins over avatarUrl', () async {
      final backend = FakeBackend(userJson);
      await serviceFor(backend, store)
          .updateProfile(avatarUrl: '/uploads/a.jpg', clearAvatar: true);

      expect(backend.lastJsonBody, containsPair('avatar_url', null));
    });

    test('an empty phone number is sent so it can be cleared', () async {
      final backend = FakeBackend(userJson);
      await serviceFor(backend, store).updateProfile(phoneNumber: '');
      expect(backend.lastJsonBody, containsPair('phone_number', ''));
    });
  });
}
