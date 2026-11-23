import '../../../core/api/api_client.dart';
import '../../../core/storage/token_store.dart';
import 'auth_models.dart';

/// High-level authentication API. Talks to the FastAPI `/api/v1/auth` and
/// `/api/v1/users` routes and keeps the JWT tokens persisted via [TokenStore].
class AuthService {
  AuthService({ApiClient? apiClient, TokenStore? tokenStore})
      : _api = apiClient ?? ApiClient.shared,
        _tokens = tokenStore ?? TokenStore();

  final ApiClient _api;
  final TokenStore _tokens;

  /// POST /auth/register — creates the account. Returns the new user.
  /// Does not log in (the backend's register endpoint returns the user, not
  /// tokens), so we follow up with [login] from the UI.
  Future<AppUser> register({
    required String email,
    required String password,
    required String fullName,
    required String city,
    String? phoneNumber,
  }) async {
    final json = await _api.post(
      '/auth/register',
      auth: false,
      body: {
        'email': email,
        'password': password,
        'full_name': fullName,
        'city': city,
        if (phoneNumber != null && phoneNumber.isNotEmpty)
          'phone_number': phoneNumber,
      },
    );
    return AppUser.fromJson(json as Map<String, dynamic>);
  }

  /// POST /auth/login — authenticates and persists the returned token pair.
  Future<AuthTokens> login({
    required String email,
    required String password,
  }) async {
    final json = await _api.post(
      '/auth/login',
      auth: false,
      body: {'email': email, 'password': password},
    );
    final tokens = AuthTokens.fromJson(json as Map<String, dynamic>);
    await _tokens.saveTokens(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
    return tokens;
  }

  /// POST /auth/forgot-password — asks the backend to email a 6-digit reset
  /// code. The backend answers the same way whether or not the email exists.
  /// Returns the server's confirmation message.
  Future<String> forgotPassword({required String email}) async {
    final json = await _api.post(
      '/auth/forgot-password',
      auth: false,
      body: {'email': email},
    );
    return (json as Map<String, dynamic>)['message'] as String? ?? '';
  }

  /// POST /auth/reset-password — sets a new password using the emailed code.
  Future<String> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    final json = await _api.post(
      '/auth/reset-password',
      auth: false,
      body: {'email': email, 'code': code, 'new_password': newPassword},
    );
    return (json as Map<String, dynamic>)['message'] as String? ?? '';
  }

  /// GET /users/me — the authenticated user's full profile.
  Future<AppUser> currentUser() async {
    final json = await _api.get('/users/me');
    return AppUser.fromJson(json as Map<String, dynamic>);
  }

  /// PATCH /users/me — partial update of the profile fields.
  /// PATCH /users/me — partial update of the profile fields.
  ///
  /// [avatarUrl] sets/replaces the photo; pass [clearAvatar]=true to remove
  /// it instead (sends `avatar_url: null` explicitly). These two are
  /// mutually exclusive — [clearAvatar] wins if both are somehow set.
  /// Omitting avatarUrl entirely (and leaving clearAvatar false) leaves the
  /// existing photo untouched, since the backend only updates fields that
  /// are actually present in the request body.
  Future<AppUser> updateProfile({
    String? fullName,
    String? phoneNumber,
    String? bio,
    String? avatarUrl,
    bool clearAvatar = false,
    String? city,
  }) async {
    final body = <String, dynamic>{};
    if (fullName != null && fullName.isNotEmpty) body['full_name'] = fullName;
    if (phoneNumber != null) body['phone_number'] = phoneNumber;
    if (bio != null) body['bio'] = bio;
    if (clearAvatar) {
      body['avatar_url'] = null;
    } else if (avatarUrl != null) {
      body['avatar_url'] = avatarUrl;
    }
    if (city != null && city.isNotEmpty) body['city'] = city;

    final json = await _api.patch('/users/me', body: body);
    return AppUser.fromJson(json as Map<String, dynamic>);
  }

  Future<bool> get isLoggedIn => _tokens.isLoggedIn;

  Future<void> logout() => _tokens.clear();
}
