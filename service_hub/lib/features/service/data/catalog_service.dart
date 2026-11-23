import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../../core/api/api_client.dart';
import '../../../core/config/nearby_search_config.dart';
import 'service_models.dart';

/// Read/write access to categories and services on the FastAPI backend.
class CatalogService {
  CatalogService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  // ------------------------------------------------- the category list
  //
  // Five screens ask for the categories — the two search screens, adding
  // and editing a service, and opening an exchange request — and each
  // builds its own CatalogService, so the list used to be downloaded again
  // on every visit to any of them. It is the most static data the app
  // reads: the app itself has no way to change a category (there is no
  // mutation call anywhere in lib/), only an administrator can, through
  // the backend. So one fetch is shared by every instance, for a bounded
  // time.

  /// How long a fetched list stays good.
  ///
  /// Bounded on purpose: a category an administrator adds or deactivates
  /// still reaches a running app within this window, without a restart.
  static const categoriesCacheTtl = Duration(minutes: 5);

  /// The clock the TTL is measured against. A seam for tests, which need
  /// to reach expiry without waiting; production always reads the real one.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static List<ServiceCategory>? _cachedCategories;
  static DateTime? _cachedCategoriesAt;

  /// Bumped by every invalidation. A fetch that was already in flight when
  /// the cache was invalidated must not store its answer afterwards: it
  /// was read before whatever caused the invalidation, so caching it would
  /// serve pre-change data for a whole TTL. Its caller still receives it —
  /// that is the list it asked for — it simply is not kept.
  static int _categoriesGeneration = 0;

  /// The fetch in flight, shared by everything that asks while it runs, so
  /// several screens opening at once still make one request.
  static Future<List<ServiceCategory>>? _categoriesInFlight;

  /// Forgets the cached list, so the next [categories] call fetches again.
  ///
  /// Nothing in the app calls this today — there is no screen that creates
  /// or edits a category, so the TTL above is what keeps the list current.
  /// It is here for a future category-management screen to call after a
  /// successful mutation, and for tests to start from a clean slate.
  static void invalidateCategoriesCache() {
    _categoriesGeneration++;
    _cachedCategories = null;
    _cachedCategoriesAt = null;
    _categoriesInFlight = null;
  }

  /// GET /categories — public list of service categories.
  ///
  /// Served from the shared cache while it is fresh, otherwise fetched
  /// once and cached. A failed or unparseable answer is never cached, so
  /// the next call tries again; callers see the same exception they always
  /// did. The returned list is a copy, so a caller cannot change what
  /// everyone else reads.
  Future<List<ServiceCategory>> categories() async {
    final cached = _cachedCategories;
    final cachedAt = _cachedCategoriesAt;
    if (cached != null &&
        cachedAt != null &&
        clock().difference(cachedAt) < categoriesCacheTtl) {
      return List.of(cached);
    }

    // Someone is already fetching it: wait for that answer instead of
    // sending a second identical request.
    final inFlight = _categoriesInFlight;
    if (inFlight != null) return List.of(await inFlight);

    final request = _fetchCategories();
    _categoriesInFlight = request;
    try {
      return List.of(await request);
    } finally {
      // Only if the slot is still this request's. An invalidation while
      // this was pending releases the slot, and a newer fetch may already
      // have claimed it — clearing that one would send whoever asks next
      // on a second, identical request.
      if (identical(_categoriesInFlight, request)) {
        _categoriesInFlight = null;
      }
    }
  }

  Future<List<ServiceCategory>> _fetchCategories() async {
    final generation = _categoriesGeneration;
    final json = await _api.get('/categories', auth: false);
    final categories = (json as List)
        .map((e) => ServiceCategory.fromJson(e as Map<String, dynamic>))
        .toList();
    // Reached only by a complete, parsed answer: anything thrown above
    // leaves the cache exactly as it was. And only this answer's own
    // generation may store it — see _categoriesGeneration.
    if (generation == _categoriesGeneration) {
      _cachedCategories = categories;
      _cachedCategoriesAt = clock();
    }
    return categories;
  }

  /// GET /services — all active services, optionally filtered by category
  /// and/or the provider's city.
  Future<List<ServiceListItem>> services({int? categoryId, String? city}) async {
    final params = <String, String>{
      if (categoryId != null) 'category_id': '$categoryId',
      if (city != null && city.isNotEmpty) 'city': city,
    };
    final query = params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&');
    final path = query.isEmpty ? '/services' : '/services?$query';
    final json = await _api.get(path, auth: false);
    return (json as List)
        .map((e) => ServiceListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /services/{id} — full detail for one service.
  Future<ServiceDetail> service(int id) async {
    final json = await _api.get('/services/$id', auth: false);
    return ServiceDetail.fromJson(json as Map<String, dynamic>);
  }

  /// GET /services/provider/{id} — services offered by one provider.
  Future<List<ServiceListItem>> servicesByProvider(int providerId) async {
    final json = await _api.get('/services/provider/$providerId', auth: false);
    return (json as List)
        .map((e) => ServiceListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /search/services — geo search around a point, nearest first.
  Future<List<ServiceListItem>> searchNearby({
    required double latitude,
    required double longitude,
    double radiusKm = NearbySearchConfig.defaultRadiusKm,
    int? categoryId,
  }) async {
    final params = <String, String>{
      'latitude': '$latitude',
      'longitude': '$longitude',
      'radius_km': '$radiusKm',
      if (categoryId != null) 'category_id': '$categoryId',
    };
    final query =
        params.entries.map((e) => '${e.key}=${e.value}').join('&');
    // auth: true (not false) — the endpoint itself stays public either way,
    // but sending the token when the caller is logged in lets the backend
    // recognize them and leave their own listings out of "services near
    // me". Logged-out callers still get results as before; no token just
    // means no header gets attached.
    final json = await _api.get('/search/services?$query', auth: true);
    return (json as List)
        .map((e) => ServiceListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /search/semantic — AI free-text search, ranked by embedding
  /// similarity (works across Arabic/English wording). Backend returns 503
  /// if semantic search isn't enabled on the server — see
  /// backend/SEMANTIC_SEARCH_SETUP.md.
  Future<List<ServiceListItem>> searchSemantic({
    required String query,
    int? categoryId,
    double threshold = 0.35,
    int limit = 20,
  }) async {
    final params = <String, String>{
      'q': Uri.encodeQueryComponent(query),
      'threshold': '$threshold',
      'limit': '$limit',
      if (categoryId != null) 'category_id': '$categoryId',
    };
    final query0 =
        params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final json = await _api.get('/search/semantic?$query0', auth: false);
    return (json as List)
        .map((e) => ServiceListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /search/smart — the app's main search. Free Arabic text in the
  /// user's own words ("بدي أصلح حنفية"); the backend understands the trade
  /// behind it and ranks the best matches first. Never needs the AI model.
  Future<List<ServiceListItem>> searchSmart({
    required String query,
    int? categoryId,
    String? city,
    int limit = 30,
  }) async {
    final params = <String, String>{
      'q': Uri.encodeQueryComponent(query),
      'limit': '$limit',
      if (categoryId != null) 'category_id': '$categoryId',
      if (city != null) 'city': Uri.encodeQueryComponent(city),
    };
    final queryString =
        params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final json = await _api.get('/search/smart?$queryString', auth: false);
    return (json as List)
        .map((e) => ServiceListItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /services — create a new service (requires auth + provider role).
  /// A service is identified by its category, so no name is sent; [price]
  /// is optional and simply left out when null (stored as "no price").
  Future<ServiceDetail> createService({
    required int categoryId,
    required String description,
    double? price,
    String priceUnit = 'fixed',
    String? coverImageUrl,
    bool isRemote = false,
    double? latitude,
    double? longitude,
    // Required by the backend when categoryId points at the "Others"
    // category — the actual trade, e.g. "سباك".
    String? customCategoryLabel,
  }) async {
    final json = await _api.post('/services', body: {
      'category_id': categoryId,
      'description': description,
      if (price != null) 'price': price,
      'price_unit': priceUnit,
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      'is_remote': isRemote,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (customCategoryLabel != null)
        'custom_category_label': customCategoryLabel,
    });
    return ServiceDetail.fromJson(json as Map<String, dynamic>);
  }

  /// PATCH /services/{id} — used by the owning provider to edit a listing's
  /// fields (title, description, price, category, location, etc.), or to
  /// deactivate/reactivate it via `status`. All params optional — only
  /// fields you pass are sent, matching the backend's partial-update
  /// schema (ServiceUpdateRequest).
  Future<ServiceDetail> updateService(
    int serviceId, {
    int? categoryId,
    String? title,
    String? description,
    double? price,
    // True to REMOVE the price (sends an explicit null). Ignored when
    // [price] is given.
    bool removePrice = false,
    String? priceUnit,
    String? status,
    double? latitude,
    double? longitude,
    String? coverImageUrl,
    bool? isRemote,
    String? customCategoryLabel,
  }) async {
    final json = await _api.patch('/services/$serviceId', body: {
      if (categoryId != null) 'category_id': categoryId,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (price != null)
        'price': price
      else if (removePrice)
        'price': null,
      if (priceUnit != null) 'price_unit': priceUnit,
      if (status != null) 'status': status,
      if (latitude != null) 'latitude': latitude,
      if (longitude != null) 'longitude': longitude,
      if (coverImageUrl != null) 'cover_image_url': coverImageUrl,
      if (isRemote != null) 'is_remote': isRemote,
      if (customCategoryLabel != null)
        'custom_category_label': customCategoryLabel,
    });
    return ServiceDetail.fromJson(json as Map<String, dynamic>);
  }

  /// DELETE /services/{id} — lets a user remove their own service listing
  /// (item: "صفحة المستخدم (حذف خدمة)"). The backend also allows an admin
  /// to delete any service.
  Future<void> deleteService(int serviceId) {
    return _api.delete('/services/$serviceId');
  }
}
