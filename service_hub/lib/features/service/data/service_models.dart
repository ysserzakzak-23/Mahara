// Dart mirrors of the backend Service/Category/Search schemas
// (backend/app/schemas/service.py, category.py, search.py).

import '../../../core/utils/category_names.dart';

/// A service is named by its category: the backend sends that as
/// `display_title` (the raw `title` is a legacy free-text name, often null).
String _serviceTitle(Map<String, dynamic> json) {
  final display = (json['display_title'] as String?)?.trim();
  // display_title is the category name (or the «أخرى» label); an older
  // database may still hold an English category name, so translate it the
  // same way the category itself is translated.
  if (display != null && display.isNotEmpty) return arabicCategoryName(display);
  final legacy = (json['title'] as String?)?.trim();
  return (legacy == null || legacy.isEmpty) ? 'خدمة' : legacy;
}

double? _asDoubleOrNull(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

class ServiceCategory {
  final int id;
  final String name;
  final String? description;
  final String? iconName;
  final bool isActive;
  // True for (at most) one category — the catch-all "Others" bucket for
  // trades that don't fit any curated category yet. A service filed
  // under it carries a ServiceListItem/ServiceDetail.customCategoryLabel
  // describing what it actually is.
  final bool isOther;

  ServiceCategory({
    required this.id,
    required this.name,
    this.description,
    this.iconName,
    this.isActive = true,
    this.isOther = false,
  });

  factory ServiceCategory.fromJson(Map<String, dynamic> json) =>
      ServiceCategory(
        id: json['id'] as int,
        name: arabicCategoryName(json['name'] as String),
        description: json['description'] as String?,
        iconName: json['icon_name'] as String?,
        isActive: json['is_active'] as bool? ?? true,
        isOther: json['is_other'] as bool? ?? false,
      );
}

/// Mirrors UserPublicResponse — the slim provider view on services/search.
class ServiceProvider {
  final int id;
  final bool isProvider;
  final String? fullName;
  final String? avatarUrl;
  final String? city;
  final String? bio;
  final String? phoneNumber;

  ServiceProvider({
    required this.id,
    this.isProvider = false,
    this.fullName,
    this.avatarUrl,
    this.city,
    this.bio,
    this.phoneNumber,
  });

  factory ServiceProvider.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return ServiceProvider(
      id: json['id'] as int,
      isProvider: json['is_provider'] as bool? ?? false,
      fullName: profile?['full_name'] as String?,
      avatarUrl: profile?['avatar_url'] as String?,
      city: profile?['city'] as String?,
      bio: profile?['bio'] as String?,
      phoneNumber: profile?['phone_number'] as String?,
    );
  }

  String get displayName => fullName ?? 'مزوّد #$id';
}

/// Slim row used by list/search endpoints (ServiceListItemResponse).
class ServiceListItem {
  final int id;
  /// How the service is named: its category (backend display_title).
  final String title;
  /// null = the provider published it without a price (see formatPrice).
  final double? price;
  final String priceUnit;
  final String status;
  final ServiceCategory category;
  final ServiceProvider provider;
  final double? distanceKm; // only set on geo (nearby) search results
  final double? similarityScore; // only set on semantic (AI) search results
  final double? averageRating; // only set on semantic (AI) search results
  final int? totalReviews; // only set on semantic (AI) search results
  final String? coverImageUrl;
  final bool isRemote;
  // Only meaningful when category.isOther is true — the actual trade the
  // provider does (e.g. "سباك"), since "category.name" is just "Others"
  // in that case. Use [displayCategoryLabel] to show the right thing.
  final String? customCategoryLabel;

  ServiceListItem({
    required this.id,
    required this.title,
    required this.price,
    required this.priceUnit,
    required this.status,
    required this.category,
    required this.provider,
    this.distanceKm,
    this.similarityScore,
    this.averageRating,
    this.totalReviews,
    this.coverImageUrl,
    this.isRemote = false,
    this.customCategoryLabel,
  });

  /// What to actually show as this service's category: the curated
  /// category name normally, or the provider's own free-text label when
  /// it's filed under the "Others" bucket.
  String get displayCategoryLabel =>
      (category.isOther && (customCategoryLabel?.trim().isNotEmpty ?? false))
          ? customCategoryLabel!.trim()
          : category.name;

  factory ServiceListItem.fromJson(Map<String, dynamic> json) => ServiceListItem(
        id: json['id'] as int,
        title: _serviceTitle(json),
        price: _asDoubleOrNull(json['price']),
        priceUnit: json['price_unit'] as String? ?? 'fixed',
        status: json['status']?.toString() ?? 'active',
        category:
            ServiceCategory.fromJson(json['category'] as Map<String, dynamic>),
        provider:
            ServiceProvider.fromJson(json['provider'] as Map<String, dynamic>),
        distanceKm: _asDoubleOrNull(json['distance_km']),
        similarityScore: _asDoubleOrNull(json['similarity_score']),
        averageRating: _asDoubleOrNull(json['average_rating']),
        totalReviews: json['total_reviews'] as int?,
        coverImageUrl: json['cover_image_url'] as String?,
        isRemote: json['is_remote'] as bool? ?? false,
        customCategoryLabel: json['custom_category_label'] as String?,
      );
}

/// Full detail (ServiceResponse).
class ServiceDetail {
  final int id;
  /// How the service is named: its category (backend display_title).
  final String title;
  final String description;
  /// null = the provider published it without a price (see formatPrice).
  final double? price;
  final String priceUnit;
  final String status;
  final double? latitude;
  final double? longitude;
  final ServiceCategory category;
  final ServiceProvider provider;
  final String? coverImageUrl;
  final bool isRemote;
  final String? customCategoryLabel;

  ServiceDetail({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.priceUnit,
    required this.status,
    this.latitude,
    this.longitude,
    required this.category,
    required this.provider,
    this.coverImageUrl,
    this.isRemote = false,
    this.customCategoryLabel,
  });

  /// See ServiceListItem.displayCategoryLabel.
  String get displayCategoryLabel =>
      (category.isOther && (customCategoryLabel?.trim().isNotEmpty ?? false))
          ? customCategoryLabel!.trim()
          : category.name;

  factory ServiceDetail.fromJson(Map<String, dynamic> json) => ServiceDetail(
        id: json['id'] as int,
        title: _serviceTitle(json),
        description: json['description'] as String? ?? '',
        price: _asDoubleOrNull(json['price']),
        priceUnit: json['price_unit'] as String? ?? 'fixed',
        status: json['status']?.toString() ?? 'active',
        latitude: _asDoubleOrNull(json['latitude']),
        longitude: _asDoubleOrNull(json['longitude']),
        category:
            ServiceCategory.fromJson(json['category'] as Map<String, dynamic>),
        provider:
            ServiceProvider.fromJson(json['provider'] as Map<String, dynamic>),
        coverImageUrl: json['cover_image_url'] as String?,
        isRemote: json['is_remote'] as bool? ?? false,
        customCategoryLabel: json['custom_category_label'] as String?,
      );
}

/// Mirrors PortfolioItemResponse — a single "previous work" gallery photo
/// attached to a service.
class PortfolioItem {
  final int id;
  final String imageUrl;
  final String? caption;
  final int displayOrder;

  PortfolioItem({
    required this.id,
    required this.imageUrl,
    this.caption,
    this.displayOrder = 0,
  });

  factory PortfolioItem.fromJson(Map<String, dynamic> json) => PortfolioItem(
        id: json['id'] as int,
        imageUrl: json['image_url'] as String,
        caption: json['caption'] as String?,
        displayOrder: json['display_order'] as int? ?? 0,
      );
}
