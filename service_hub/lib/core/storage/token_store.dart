import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persists the JWT access/refresh tokens returned by the backend so the
/// session survives app restarts. Thin wrapper around SharedPreferences.
class TokenStore {
  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKey, accessToken);
    await prefs.setString(_refreshKey, refreshToken);
  }

  Future<String?> get accessToken async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessKey);
  }

  Future<String?> get refreshToken async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshKey);
  }

  Future<bool> get isLoggedIn async => (await accessToken) != null;

  /// The signed-in user's id, read out of the stored access token.
  ///
  /// Null when there is no token, or when it cannot be read as one — never
  /// a guess. See [userIdFromAccessToken] for what this is and is not for.
  Future<int?> get currentUserId async => userIdFromAccessToken(await accessToken);

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessKey);
    await prefs.remove(_refreshKey);
  }
}

/// The `sub` claim of a backend access token, as an int, or null.
///
/// The backend signs `{"sub": "<user id>", "type": "access", ...}`
/// (app/core/security.py), so the id the app is already carrying can be
/// read without asking /users/me for it.
///
/// **This is not authentication and must never be used as such.** The
/// signature is not checked here and could not be — the app has no secret
/// key — so a caller learns only what the stored token claims. It is used
/// for one thing: supplying `exclude_user_id` so the Browse list can leave
/// the viewer's own requests out, a display filter that only ever removes
/// rows. Every real decision stays with the backend, which verifies the
/// signature on every request.
///
/// Returns null for anything it cannot read with confidence: no token, a
/// token that is not three dot-separated segments, a payload that is not
/// base64url or not JSON, a payload that is not an object, a `type` that
/// is not `access` (so a refresh token is never mistaken for one), or a
/// `sub` that is not a whole number. Expiry is deliberately ignored: an
/// expired access token still names the same signed-in user, and the id is
/// wanted for a filter rather than for access — the request it travels on
/// is authorized, or refreshed, by the backend as usual.
int? userIdFromAccessToken(String? token) {
  if (token == null || token.isEmpty) return null;

  final segments = token.split('.');
  if (segments.length != 3) return null;

  final Object? payload;
  try {
    payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))));
  } catch (_) {
    // Not base64url, not UTF-8, or not JSON. Nothing to read.
    return null;
  }

  if (payload is! Map<String, dynamic>) return null;
  if (payload['type'] != 'access') return null;

  final subject = payload['sub'];
  if (subject is int) return subject;
  if (subject is String) return int.tryParse(subject);
  return null;
}
