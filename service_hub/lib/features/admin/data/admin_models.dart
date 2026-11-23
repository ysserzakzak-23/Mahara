import '../../../core/utils/category_names.dart';
// Mirrors backend/app/schemas/admin.py.

class PlatformStats {
  final int totalUsers;
  final int totalProviders;
  final int activeServices;
  final int totalAppointments;
  final int completedAppointments;
  final int totalReviews;
  final double averagePlatformRating;

  PlatformStats({
    required this.totalUsers,
    required this.totalProviders,
    required this.activeServices,
    required this.totalAppointments,
    required this.completedAppointments,
    required this.totalReviews,
    required this.averagePlatformRating,
  });

  factory PlatformStats.fromJson(Map<String, dynamic> json) => PlatformStats(
    totalUsers: json['total_users'] as int? ?? 0,
    totalProviders: json['total_providers'] as int? ?? 0,
    activeServices: json['active_services'] as int? ?? 0,
    totalAppointments: json['total_appointments'] as int? ?? 0,
    completedAppointments: json['completed_appointments'] as int? ?? 0,
    totalReviews: json['total_reviews'] as int? ?? 0,
    averagePlatformRating:
        (json['average_platform_rating'] as num?)?.toDouble() ?? 0.0,
  );
}

class AdminUser {
  final int id;
  final String email;
  final String role;
  final bool isProvider;
  final bool isActive;
  final String? fullName;

  AdminUser({
    required this.id,
    required this.email,
    required this.role,
    required this.isProvider,
    required this.isActive,
    this.fullName,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return AdminUser(
      id: json['id'] as int,
      email: json['email'] as String,
      role: json['role']?.toString() ?? 'user',
      isProvider: json['is_provider'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      fullName: profile?['full_name'] as String?,
    );
  }
}

class AdminServiceListing {
  final int id;
  /// The service's display name (its category).
  final String title;
  /// null = published without a price.
  final double? price;
  final String status;
  final int providerId;
  final int categoryId;

  AdminServiceListing({
    required this.id,
    required this.title,
    required this.price,
    required this.status,
    required this.providerId,
    required this.categoryId,
  });

  factory AdminServiceListing.fromJson(Map<String, dynamic> json) =>
      AdminServiceListing(
        id: json['id'] as int,
        title: arabicCategoryName(
          (json['display_title'] as String?) ?? (json['title'] as String?) ?? 'خدمة',
        ),
        price: json['price'] == null
            ? null
            : double.tryParse(json['price'].toString()),
        status: json['status']?.toString() ?? 'active',
        providerId: json['provider_id'] as int,
        categoryId: json['category_id'] as int,
      );
}
