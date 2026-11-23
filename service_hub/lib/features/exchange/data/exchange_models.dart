// Dart mirrors of backend/app/schemas/exchange.py
// (ExchangeRequest / ExchangeProposal — the "اطلب/اقترح/وافق" flow).

import '../../service/data/service_models.dart';

class ExchangeRequestModel {
  final int id;
  final String status; // open | matched | closed
  final ServiceProvider user;
  final ServiceListItem offeredService;
  final ServiceCategory offeredCategory;
  final ServiceCategory wantedCategory;
  final String? wantedCustomCategoryLabel;

  /// Average rating of the OFFERED SERVICE (not the owner's profile).
  /// Only filled by [ExchangeRequestModel.fromRankedJson] («اهتماماتي» and
  /// the exchange search); null = no reviews yet.
  final double? offeredServiceRating;
  final int offeredServiceReviewCount;

  /// 0-1 smart-search relevance; null when the list wasn't a search.
  final double? relevanceScore;

  ExchangeRequestModel({
    required this.id,
    required this.status,
    required this.user,
    required this.offeredService,
    required this.offeredCategory,
    required this.wantedCategory,
    this.wantedCustomCategoryLabel,
    this.offeredServiceRating,
    this.offeredServiceReviewCount = 0,
    this.relevanceScore,
  });

  bool get isOpen => status == 'open';

  String get wantedCategoryLabel =>
      (wantedCategory.isOther &&
              (wantedCustomCategoryLabel?.trim().isNotEmpty ?? false))
          ? wantedCustomCategoryLabel!.trim()
          : wantedCategory.name;

  factory ExchangeRequestModel.fromJson(Map<String, dynamic> json) =>
      ExchangeRequestModel(
        id: json['id'] as int,
        status: json['status']?.toString() ?? 'open',
        user: ServiceProvider.fromJson(json['user'] as Map<String, dynamic>),
        offeredService: ServiceListItem.fromJson(
            json['offered_service'] as Map<String, dynamic>),
        offeredCategory: ServiceCategory.fromJson(
            json['offered_category'] as Map<String, dynamic>),
        wantedCategory: ServiceCategory.fromJson(
            json['wanted_category'] as Map<String, dynamic>),
        wantedCustomCategoryLabel:
            json['wanted_custom_category_label'] as String?,
      );

  /// For «اهتماماتي» and the exchange search
  /// (backend ExchangeRequestRankedResponse): the regular request fields
  /// plus the offered service's rating and the search relevance. Kept apart
  /// from [ExchangeRequestModel.fromJson] so the other endpoints, which don't
  /// send these fields, are never read for them.
  factory ExchangeRequestModel.fromRankedJson(Map<String, dynamic> json) {
    final base = ExchangeRequestModel.fromJson(json);
    return ExchangeRequestModel(
      id: base.id,
      status: base.status,
      user: base.user,
      offeredService: base.offeredService,
      offeredCategory: base.offeredCategory,
      wantedCategory: base.wantedCategory,
      wantedCustomCategoryLabel: base.wantedCustomCategoryLabel,
      offeredServiceRating:
          (json['offered_service_rating'] as num?)?.toDouble(),
      offeredServiceReviewCount:
          (json['offered_service_review_count'] as num?)?.toInt() ?? 0,
      relevanceScore: (json['relevance_score'] as num?)?.toDouble(),
    );
  }
}

/// One detected direct match returned by GET /exchange-requests/{id}/matches.
class DirectMatch {
  final String matchType;
  final ExchangeRequestModel otherRequest;

  DirectMatch({required this.matchType, required this.otherRequest});

  factory DirectMatch.fromJson(Map<String, dynamic> json) => DirectMatch(
        matchType: json['match_type']?.toString() ?? 'direct',
        otherRequest: ExchangeRequestModel.fromJson(
            json['other_request'] as Map<String, dynamic>),
      );
}

class ExchangeProposalModel {
  final int id;
  final String status; // pending | accepted | rejected | withdrawn
  final String? message;
  final ServiceProvider proposer;
  final ServiceListItem proposedService;
  final ExchangeRequestModel request;

  ExchangeProposalModel({
    required this.id,
    required this.status,
    this.message,
    required this.proposer,
    required this.proposedService,
    required this.request,
  });

  bool get isPending => status == 'pending';

  factory ExchangeProposalModel.fromJson(Map<String, dynamic> json) =>
      ExchangeProposalModel(
        id: json['id'] as int,
        status: json['status']?.toString() ?? 'pending',
        message: json['message'] as String?,
        proposer:
            ServiceProvider.fromJson(json['proposer'] as Map<String, dynamic>),
        proposedService: ServiceListItem.fromJson(
            json['proposed_service'] as Map<String, dynamic>),
        request: ExchangeRequestModel.fromJson(
            json['request'] as Map<String, dynamic>),
      );
}
