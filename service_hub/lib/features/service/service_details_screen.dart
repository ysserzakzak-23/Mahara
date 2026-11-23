import 'package:flutter/material.dart';
import 'package:service_hub/features/booking/create_booking_screen.dart';

import '../../core/api/api_exception.dart';
import '../../core/config/api_config.dart';
import '../../core/utils/price_format.dart';
import '../../core/utils/status_labels.dart';
import '../profile/provider_profile_screen.dart';
import '../reviews/data/review_models.dart';
import '../reviews/data/review_service.dart';
import 'data/catalog_service.dart';
import 'data/service_models.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class ServiceDetailsScreen extends StatefulWidget {
  final int serviceId;

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final CatalogService? catalogService;
  final ReviewService? reviewService;
  final Widget Function(ServiceDetail service)? bookingBuilder;
  final Widget Function(int providerId)? providerBuilder;

  const ServiceDetailsScreen({
    super.key,
    required this.serviceId,
    this.catalogService,
    this.reviewService,
    this.bookingBuilder,
    this.providerBuilder,
  });

  @override
  State<ServiceDetailsScreen> createState() => _ServiceDetailsScreenState();
}

class _ServiceDetailsScreenState extends State<ServiceDetailsScreen> {
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final ReviewService _reviews = widget.reviewService ?? ReviewService();

  late Future<ServiceDetail> _serviceFuture;
  late Future<RatingSummary> _summaryFuture;
  late Future<List<Review>> _reviewsFuture;

  @override
  void initState() {
    super.initState();
    _serviceFuture = _catalog.service(widget.serviceId);
    _summaryFuture = _reviews.summary(widget.serviceId);
    _reviewsFuture = _reviews.listReviews(widget.serviceId);
    // These are only listened to once the service has loaded; if one fails
    // first, don't report it as unhandled (the FutureBuilders show the error).
    _summaryFuture.ignore();
    _reviewsFuture.ignore();
  }

  void _reloadReviews() {
    setState(() {
      _summaryFuture = _reviews.summary(widget.serviceId);
      _reviewsFuture = _reviews.listReviews(widget.serviceId);
    });
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Only the customer whose appointment for this service has been marked
  /// COMPLETED by the provider may review it — enforced server-side (see
  /// review_service.py). We don't try to guess eligibility client-side; we
  /// just let the backend's 403 message explain why, if that's what
  /// happens.
  Future<void> _openReviewDialog() async {
    // The dialog owns its text controller (and disposes it when it closes);
    // it returns the review to send, or null when cancelled / dismissed.
    final review = await showDialog<_ReviewDraft>(
      context: context,
      builder: (_) => const _ReviewDialog(),
    );

    if (review == null) return;

    try {
      await _reviews.submitReview(
        widget.serviceId,
        rating: review.rating,
        comment: review.comment,
      );
      if (!mounted) return;
      _showMessage('شكراً على تقييمك!');
      _reloadReviews();
    } on ApiException catch (e) {
      // Surfaces the backend's message directly, e.g. "You can only review
      // this service after the provider has marked your appointment as
      // completed" or "You cannot review your own service".
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تفاصيل الخدمة"),
        titleSpacing: -2,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: FutureBuilder<ServiceDetail>(
        future: _serviceFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(errorText(snapshot.error), textAlign: TextAlign.center),
              ),
            );
          }
          return _buildContent(context, snapshot.data!);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, ServiceDetail service) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 220,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: service.coverImageUrl != null
                ? Image.network(
                    ApiConfig.resolveUrl(service.coverImageUrl!),
                    fit: BoxFit.cover,
                    cacheWidth: decodePixels(
                      context,
                      MediaQuery.sizeOf(context).width,
                    ),
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.image, size: 60, color: Colors.grey),
                  )
                : const Icon(Icons.image, size: 60, color: Colors.grey),
          ),
          const SizedBox(height: 20),
          Text(
            service.title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      widget.providerBuilder?.call(service.provider.id) ??
                      ProviderProfileScreen(providerId: service.provider.id),
                ),
              );
            },
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: Colors.grey.shade300,
                  backgroundImage: service.provider.avatarUrl != null
                      ? sizedNetworkImage(
                          context,
                          ApiConfig.resolveUrl(service.provider.avatarUrl!),
                          longestSide: 36,     // radius 18
                        )
                      : null,
                  child: service.provider.avatarUrl == null
                      ? const Icon(Icons.person)
                      : null,
                ),
                const SizedBox(width: 10),
                Text(
                  "بواسطة ${service.provider.displayName}",
                  style: const TextStyle(
                    fontSize: 16,
                    decoration: TextDecoration.underline,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
              ],
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              const Icon(Icons.category, color: Colors.grey, size: 20),
              const SizedBox(width: 5),
              Text(service.displayCategoryLabel),
              if (service.provider.city != null) ...[
                const SizedBox(width: 15),
                const Icon(Icons.location_on, color: Colors.grey, size: 20),
                const SizedBox(width: 5),
                Text(service.provider.city!),
              ],
              if (service.isRemote) ...[
                const SizedBox(width: 15),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi, size: 14, color: Colors.teal.shade700),
                      const SizedBox(width: 4),
                      Text(
                        "عن بُعد",
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.teal.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 25),
          const Text(
            "الوصف",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(service.description),
          const SizedBox(height: 25),
          const Text(
            "السعر",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            service.price == null
                ? noPriceLabel
                : priceUnitLabel(service.priceUnit) == null
                    ? formatPrice(service.price)
                    : "${formatPrice(service.price)} (${priceUnitLabel(service.priceUnit)})",
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 35),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      widget.bookingBuilder?.call(service) ??
                      CreateBookingScreen(
                        serviceId: service.id,
                        serviceTitle: service.title,
                        providerId: service.provider.id,
                        isRemote: service.isRemote,
                      ),
                ),
              );
            },
            child: const Text(
              "احجز موعداً",
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 30),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "التقييمات",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              TextButton.icon(
                onPressed: _openReviewDialog,
                icon: const Icon(Icons.rate_review_outlined),
                label: const Text("أضف تقييماً"),
              ),
            ],
          ),
          FutureBuilder<RatingSummary>(
            future: _summaryFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done ||
                  !snapshot.hasData) {
                return const SizedBox.shrink();
              }
              final s = snapshot.data!;
              if (s.reviewCount == 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    const Icon(Icons.star, color: Colors.amber, size: 20),
                    const SizedBox(width: 5),
                    Text(
                      '${s.averageRating.toStringAsFixed(1)} (${s.reviewCount} تقييم)',
                    ),
                  ],
                ),
              );
            },
          ),
          FutureBuilder<List<Review>>(
            future: _reviewsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Text(errorText(snapshot.error));
              }
              final reviews = snapshot.data ?? [];
              if (reviews.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Text("لا توجد تقييمات بعد."),
                );
              }
              return Column(
                children: [
                  for (final r in reviews)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Row(
                          children: [
                            for (var i = 0; i < 5; i++)
                              Icon(
                                i < r.rating ? Icons.star : Icons.star_border,
                                size: 16,
                                color: Colors.amber,
                              ),
                          ],
                        ),
                        subtitle: r.comment != null && r.comment!.isNotEmpty
                            ? Text(r.comment!)
                            : null,
                        trailing: Text(r.reviewer.displayName),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// What the user entered in the review dialog.
class _ReviewDraft {
  const _ReviewDraft({required this.rating, required this.comment});

  final int rating;
  final String comment;
}

/// The "أضف تقييماً" dialog: a 1-5 star picker and an optional comment.
///
/// A widget of its own so the comment's [TextEditingController] lives exactly
/// as long as the dialog does: created with it, and disposed with it once the
/// dialog has really left the screen (after its closing animation).
class _ReviewDialog extends StatefulWidget {
  const _ReviewDialog();

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _commentController = TextEditingController();
  int _rating = 5;

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('أضف تقييماً'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  icon: Icon(
                    i <= _rating ? Icons.star : Icons.star_border,
                    color: Colors.amber,
                  ),
                  onPressed: () => setState(() => _rating = i),
                ),
            ],
          ),
          TextField(
            controller: _commentController,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'تعليق (اختياري)'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            context,
            _ReviewDraft(
              rating: _rating,
              comment: _commentController.text.trim(),
            ),
          ),
          child: const Text('إرسال', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}
