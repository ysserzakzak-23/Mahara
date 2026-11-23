import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('starts logged out', () async {
    final store = TokenStore();
    expect(await store.isLoggedIn, isFalse);
    expect(await store.accessToken, isNull);
    expect(await store.refreshToken, isNull);
  });

  test('saveTokens persists both tokens and marks the user logged in', () async {
    final store = TokenStore();
    await store.saveTokens(accessToken: 'acc', refreshToken: 'ref');

    expect(await store.accessToken, 'acc');
    expect(await store.refreshToken, 'ref');
    expect(await store.isLoggedIn, isTrue);
  });

  test('tokens survive a new TokenStore instance (app restart)', () async {
    await TokenStore().saveTokens(accessToken: 'acc', refreshToken: 'ref');
    expect(await TokenStore().accessToken, 'acc');
  });

  test('clear removes both tokens', () async {
    final store = TokenStore();
    await store.saveTokens(accessToken: 'acc', refreshToken: 'ref');
    await store.clear();

    expect(await store.isLoggedIn, isFalse);
    expect(await store.refreshToken, isNull);
  });
}
