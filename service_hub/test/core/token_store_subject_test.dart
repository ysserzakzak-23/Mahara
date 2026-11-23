// Reading the signed-in user's id out of the stored access token.
//
// The Browse tab needs its own user id to ask the backend to leave its own
// exchange requests out. The id is already on the device, inside the access
// token's `sub` claim (app/core/security.py signs it there), so it is read
// from there rather than bought with a /users/me round trip.
//
// What this is NOT: authentication. The signature cannot be checked here —
// the app has no secret key — so this only reports what the stored token
// claims. It feeds a display filter that removes rows and nothing else;
// the backend verifies every request as it always did. These tests are
// written around that boundary: anything that cannot be read with
// confidence must come back null, never a guess.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

/// A token whose payload is exactly [payload], however malformed.
String _tokenWithPayload(Object? payload) {
  final encoded =
      base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  return 'aGVhZGVy.$encoded.signature';
}

void main() {
  group('a valid access token gives up its subject', () {
    test('the sub claim, as an int', () {
      expect(userIdFromAccessToken(tokenFor(42)), 42);
    });

    test('the backend writes sub as a string, which is what arrives', () {
      // app/core/security.py: subject=str(user_id).
      expect(userIdFromAccessToken(tokenFor('7')), 7);
    });

    test('a numeric sub is accepted too, in case it is ever sent that way', () {
      expect(userIdFromAccessToken(_tokenWithPayload(
        {'sub': 7, 'type': 'access'},
      )), 7);
    });

    test('base64url padding is not required', () {
      // The helper strips '=' padding, as real encoders do; several
      // different ids exercise all three remainder lengths.
      for (final id in [1, 22, 333, 4444, 55555, 666666]) {
        expect(userIdFromAccessToken(tokenFor(id)), id, reason: '$id');
      }
    });

    test('a token whose payload carries extra claims still reads', () {
      expect(userIdFromAccessToken(_tokenWithPayload({
        'sub': '9',
        'type': 'access',
        'iat': 1,
        'exp': 2,
        'something_new': {'a': 1},
      })), 9);
    });

    test('an expired access token still names the same user', () {
      // Deliberate: the id is wanted for a filter, not for access. The
      // request it travels on is authorized (or refreshed) by the backend
      // as usual, and the person signed in has not changed.
      expect(userIdFromAccessToken(tokenFor(42, expired: true)), 42);
    });
  });

  group('anything unreadable is null, never a guess', () {
    final unusable = <String, String?>{
      'null': null,
      'empty': '',
      'not a token at all': 'acc',
      'one segment': 'onlyonesegment',
      'two segments': 'header.payload',
      'four segments': 'a.b.c.d',
      'an empty payload segment': 'header..signature',
      'a payload that is not base64url': 'header.!!!not-base64!!!.signature',
      'a payload that is not JSON': 'header.${base64Url.encode(utf8.encode('plain text')).replaceAll('=', '')}.signature',
      'only dots': '..',
    };

    unusable.forEach((description, token) {
      test('$description -> null', () {
        expect(userIdFromAccessToken(token), isNull);
      });
    });

    test('a payload that is a JSON array, not an object', () {
      expect(userIdFromAccessToken(_tokenWithPayload([1, 2, 3])), isNull);
    });

    test('a payload that is a bare JSON string', () {
      expect(userIdFromAccessToken(_tokenWithPayload('nope')), isNull);
    });

    test('no sub claim', () {
      expect(userIdFromAccessToken(_tokenWithPayload({'type': 'access'})), isNull);
    });

    test('a null sub', () {
      expect(userIdFromAccessToken(tokenFor(null)), isNull);
    });

    test('a sub that is not a number', () {
      expect(userIdFromAccessToken(tokenFor('alice')), isNull);
    });

    test('a sub that is a fraction', () {
      expect(userIdFromAccessToken(tokenFor('1.5')), isNull);
      expect(userIdFromAccessToken(_tokenWithPayload(
        {'sub': 1.5, 'type': 'access'},
      )), isNull);
    });

    test('a sub that is an object', () {
      expect(userIdFromAccessToken(_tokenWithPayload(
        {'sub': {'id': 1}, 'type': 'access'},
      )), isNull);
    });
  });

  group('a refresh token is not an access token', () {
    test('a refresh token is refused even though it has the same sub', () {
      // Both are signed with the same secret and carry the same subject;
      // `type` is what tells them apart (app/core/security.py), and reading
      // an id out of the wrong one would be reading the wrong thing.
      expect(userIdFromAccessToken(tokenFor(42, type: 'refresh')), isNull);
    });

    test('a missing type claim is refused', () {
      expect(userIdFromAccessToken(_tokenWithPayload({'sub': '42'})), isNull);
    });

    test('an unknown type is refused', () {
      expect(
        userIdFromAccessToken(_tokenWithPayload({'sub': '42', 'type': 'magic'})),
        isNull,
      );
    });
  });

  group('TokenStore.currentUserId', () {
    test('reads the id out of the stored access token', () async {
      SharedPreferences.setMockInitialValues({'access_token': tokenFor(99)});

      expect(await TokenStore().currentUserId, 99);
    });

    test('is null when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await TokenStore().currentUserId, isNull);
    });

    test('is null when the stored token is unusable', () async {
      SharedPreferences.setMockInitialValues({'access_token': 'acc'});

      expect(await TokenStore().currentUserId, isNull);
    });

    test('ignores the refresh token', () async {
      SharedPreferences.setMockInitialValues({
        'access_token': tokenFor(99),
        'refresh_token': tokenFor(1234, type: 'refresh'),
      });

      expect(await TokenStore().currentUserId, 99);
    });

    test('follows the tokens through a login', () async {
      SharedPreferences.setMockInitialValues({});
      final store = TokenStore();
      expect(await store.currentUserId, isNull);

      await store.saveTokens(
        accessToken: tokenFor(5),
        refreshToken: tokenFor(5, type: 'refresh'),
      );
      expect(await store.currentUserId, 5);

      // And a second account on the same device.
      await store.saveTokens(
        accessToken: tokenFor(6),
        refreshToken: tokenFor(6, type: 'refresh'),
      );
      expect(await store.currentUserId, 6);
    });

    test('is null again after logout', () async {
      SharedPreferences.setMockInitialValues({'access_token': tokenFor(5)});
      final store = TokenStore();
      expect(await store.currentUserId, 5);

      await store.clear();

      expect(await store.currentUserId, isNull);
      expect(await store.isLoggedIn, isFalse);
    });

    test('the rest of the store is untouched by all this', () async {
      SharedPreferences.setMockInitialValues({});
      final store = TokenStore();

      await store.saveTokens(accessToken: 'a-token', refreshToken: 'r-token');

      expect(await store.accessToken, 'a-token');
      expect(await store.refreshToken, 'r-token');
      expect(await store.isLoggedIn, isTrue);
      // 'a-token' is not a JWT, so there is no id to read - and that does
      // not stop the session from working.
      expect(await store.currentUserId, isNull);
    });
  });
}
