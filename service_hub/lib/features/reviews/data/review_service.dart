import '../../../core/api/api_client.dart';
import 'review_models.dart';

/// Reviews are restricted server-side to customers who actually booked the
/// service — a provider cannot review their own listing, and someone who
/// never booked it cannot leave a "drive-by" rating (see
/// backend/app/services/review_service.py). This service just forwards
/// whatever 403 message the backend returns; the UI surfaces it as-is.
class ReviewService {
  ReviewService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<List<Review>> listReviews(int serviceId) async {
    final json = await _api.get('/services/$serviceId/reviews', auth: false);
    return (json as List)
        .map((e) => Review.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RatingSummary> summary(int serviceId) async {
    final json =
        await _api.get('/services/$serviceId/reviews/summary', auth: false);
    return RatingSummary.fromJson(json as Map<String, dynamic>);
  }

  /// Creates the current user's review, or updates it if they already left
  /// one for this service.
  Future<Review> submitReview(
    int serviceId, {
    required int rating,
    String? comment,
  }) async {
    final json = await _api.post(
      '/services/$serviceId/reviews',
      body: {
        'rating': rating,
        if (comment != null && comment.isNotEmpty) 'comment': comment,
      },
    );
    return Review.fromJson(json as Map<String, dynamic>);
  }
}
