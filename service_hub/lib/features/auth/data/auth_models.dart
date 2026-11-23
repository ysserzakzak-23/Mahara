// Dart mirrors of the backend's auth schemas (app/schemas/user.py).

class AuthTokens {
  final String accessToken;
  final String refreshToken;

  AuthTokens({required this.accessToken, required this.refreshToken});

  factory AuthTokens.fromJson(Map<String, dynamic> json) => AuthTokens(
        accessToken: json['access_token'] as String,
        refreshToken: json['refresh_token'] as String,
      );
}

class UserProfile {
  final String fullName;
  final String? phoneNumber;
  final String? bio;
  final String? avatarUrl;
  final String? city;

  UserProfile({
    required this.fullName,
    this.phoneNumber,
    this.bio,
    this.avatarUrl,
    this.city,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        fullName: json['full_name'] as String? ?? '',
        phoneNumber: json['phone_number'] as String?,
        bio: json['bio'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        city: json['city'] as String?,
      );
}

class AppUser {
  final int id;
  final String email;
  final String role;
  final bool isProvider;
  final bool isActive;
  final UserProfile? profile;

  AppUser({
    required this.id,
    required this.email,
    required this.role,
    required this.isProvider,
    required this.isActive,
    this.profile,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as int,
        email: json['email'] as String,
        role: json['role']?.toString() ?? 'user',
        isProvider: json['is_provider'] as bool? ?? false,
        isActive: json['is_active'] as bool? ?? true,
        profile: json['profile'] == null
            ? null
            : UserProfile.fromJson(json['profile'] as Map<String, dynamic>),
      );
}
