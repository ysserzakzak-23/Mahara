// Mirrors backend/app/schemas/review.py.

import '../../service/data/service_models.dart';

class Review {
  final int id;
  final int rating;
  final String? comment;
  final ServiceProvider reviewer;

  Review({
    required this.id,
    required this.rating,
    this.comment,
    required this.reviewer,
  });

  factory Review.fromJson(Map<String, dynamic> json) => Review(
        id: json['id'] as int,
        rating: json['rating'] as int,
        comment: json['comment'] as String?,
        reviewer:
            ServiceProvider.fromJson(json['reviewer'] as Map<String, dynamic>),
      );
}

class RatingSummary {
  final double averageRating;
  final int reviewCount;

  RatingSummary({required this.averageRating, required this.reviewCount});

  factory RatingSummary.fromJson(Map<String, dynamic> json) => RatingSummary(
        averageRating: (json['average_rating'] as num?)?.toDouble() ?? 0.0,
        reviewCount: json['review_count'] as int? ?? 0,
      );
}
