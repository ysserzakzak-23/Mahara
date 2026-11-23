import 'package:flutter/material.dart';
import '../../core/config/api_config.dart';
import '../../core/config/nearby_search_config.dart';
import '../../core/location/location_service.dart';
import '../../core/utils/distance_format.dart';
import '../../core/utils/price_format.dart';
import '../../shared/widgets/category_picker_field.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import '../service/service_details_screen.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

enum _SearchState { idle, locating, loading, loaded, locationError, searchError }

/// «خدمات قريبة مني» — services of ONE chosen category around the device's
/// current position.
///
/// The user picks the category (same picker and category list as the
/// service forms) and the radius, then presses «ابحث». Each search:
///   1. reads the device's CURRENT position (fresh fix, never a default);
///   2. asks GET /search/services for that category id within the radius —
///      the backend filters by real Haversine distance and sorts nearest
///      first;
///   3. shows each result with its distance ("500 متر", "1.2 كم").
class NearbySearchScreen extends StatefulWidget {
  const NearbySearchScreen({
    super.key,
    this.catalogService,
    this.locationService,
    this.detailsBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject fakes.
  final CatalogService? catalogService;
  final LocationService? locationService;
  final Widget Function(int serviceId)? detailsBuilder;

  @override
  State<NearbySearchScreen> createState() => _NearbySearchScreenState();
}

class _NearbySearchScreenState extends State<NearbySearchScreen> {
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final LocationService _location =
      widget.locationService ?? LocationService();

  // Categories (for the picker).
  late Future<List<ServiceCategory>> _categoriesFuture;
  List<ServiceCategory> _categories = [];

  // Search inputs.
  int? _categoryId;
  double _radiusKm = NearbySearchConfig.defaultRadiusKm;

  // Search outcome.
  _SearchState _state = _SearchState.idle;
  String? _errorMessage;
  LocationFailure? _locationFailure;
  List<ServiceListItem> _results = [];
  // What the shown results were searched for (the inputs may change after).
  String _searchedCategory = '';
  double _searchedRadiusKm = NearbySearchConfig.defaultRadiusKm;
  int _searchId = 0;

  @override
  void initState() {
    super.initState();
    _categoriesFuture = _loadCategories();
  }

  Future<List<ServiceCategory>> _loadCategories() async {
    final loaded = await _catalog.categories();
    _categories = [
      for (final c in loaded)
        if (!c.isOther) c,
      for (final c in loaded)
        if (c.isOther) c,
    ];
    return _categories;
  }

  void _retryCategories() {
    setState(() {
      _categoriesFuture = _loadCategories();
    });
  }

  ServiceCategory? get _selectedCategory {
    for (final c in _categories) {
      if (c.id == _categoryId) return c;
    }
    return null;
  }

  bool get _busy =>
      _state == _SearchState.locating || _state == _SearchState.loading;

  /// A changed filter makes the shown results stale: go back to the prompt.
  void _filtersChanged(VoidCallback change) {
    setState(() {
      change();
      if (!_busy) {
        _state = _SearchState.idle;
        _results = [];
      }
    });
  }

  Future<void> _search() async {
    final category = _selectedCategory;
    if (category == null || _busy) return;
    final searchId = ++_searchId;
    final radiusKm = _radiusKm;

    setState(() {
      _state = _SearchState.locating;
      _errorMessage = null;
      _locationFailure = null;
    });

    // 1. The device's current position, read fresh for every search.
    final double latitude;
    final double longitude;
    try {
      final position = await _location.getCurrentPosition();
      latitude = position.latitude;
      longitude = position.longitude;
    } on LocationServiceException catch (e) {
      if (!mounted || searchId != _searchId) return;
      setState(() {
        _state = _SearchState.locationError;
        _errorMessage = e.message;
        _locationFailure = e.reason;
      });
      return;
    } catch (_) {
      if (!mounted || searchId != _searchId) return;
      setState(() {
        _state = _SearchState.locationError;
        _errorMessage = 'تعذّر تحديد موقعك الحالي. حاول مرة ثانية.';
        _locationFailure = LocationFailure.unavailable;
      });
      return;
    }
    if (!mounted || searchId != _searchId) return;

    // 2. Services of that category within the radius, nearest first.
    setState(() => _state = _SearchState.loading);
    try {
      final found = await _catalog.searchNearby(
        latitude: latitude,
        longitude: longitude,
        radiusKm: radiusKm,
        categoryId: category.id,
      );
      if (!mounted || searchId != _searchId) return;
      setState(() {
        _results = _onlyMatching(found, category.id, radiusKm);
        _searchedCategory = category.name;
        _searchedRadiusKm = radiusKm;
        _state = _SearchState.loaded;
      });
    } catch (e) {
      if (!mounted || searchId != _searchId) return;
      setState(() {
        _state = _SearchState.searchError;
        _errorMessage = errorText(e);
      });
    }
  }

  /// The backend already filters and sorts; this keeps the list honest even
  /// if a response doesn't match the request (e.g. an outdated server):
  /// only the chosen category, only within the radius, nearest first.
  static List<ServiceListItem> _onlyMatching(
    List<ServiceListItem> found,
    int categoryId,
    double radiusKm,
  ) {
    final kept = [
      for (final s in found)
        if (s.category.id == categoryId &&
            s.distanceKm != null &&
            s.distanceKm! <= radiusKm)
          s,
    ];
    kept.sort((a, b) => a.distanceKm!.compareTo(b.distanceKm!));
    return kept;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("خدمات قريبة مني"),
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: FutureBuilder<List<ServiceCategory>>(
        future: _categoriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _message(
              icon: Icons.error_outline,
              text: 'تعذّر تحميل التصنيفات: ${errorText(snapshot.error)}',
              actions: [
                OutlinedButton(
                  onPressed: _retryCategories,
                  child: const Text("حاول مرة أخرى"),
                ),
              ],
            );
          }
          return Column(
            children: [
              _buildFilters(snapshot.data ?? []),
              Expanded(child: _buildResults()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilters(List<ServiceCategory> categories) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "التصنيف",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          CategoryPickerField(
            categories: categories,
            selectedId: _categoryId,
            hint: 'اختر التصنيف الذي تبحث عنه',
            onChanged: (id) => _filtersChanged(() => _categoryId = id),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Icon(Icons.social_distance, size: 18, color: Colors.grey),
              const SizedBox(width: 6),
              Text("نطاق البحث: ${_radiusKm.round()} كم"),
            ],
          ),
          Slider(
            value: _radiusKm,
            min: NearbySearchConfig.minRadiusKm,
            max: NearbySearchConfig.maxRadiusKm,
            divisions: (NearbySearchConfig.maxRadiusKm -
                    NearbySearchConfig.minRadiusKm)
                .round(),
            label: "${_radiusKm.round()} كم",
            onChanged: (v) => _filtersChanged(() => _radiusKm = v),
          ),
          ElevatedButton.icon(
            onPressed: _categoryId == null || _busy ? null : _search,
            icon: const Icon(Icons.near_me, color: Colors.white),
            label: const Text(
              "ابحث عن خدمات قريبة",
              style: TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildResults() {
    switch (_state) {
      case _SearchState.idle:
        return _message(
          icon: Icons.travel_explore,
          text: _categoryId == null
              ? 'اختر التصنيف الذي تبحث عنه، ثم اضغط «ابحث عن خدمات قريبة».'
              : 'اضغط «ابحث عن خدمات قريبة» لعرض الخدمات الأقرب إليك.',
        );
      case _SearchState.locating:
        return _message(
          progress: true,
          text: 'جارٍ تحديد موقعك...',
        );
      case _SearchState.loading:
        return _message(
          progress: true,
          text: 'جارٍ البحث عن الخدمات القريبة...',
        );
      case _SearchState.locationError:
        return _message(
          icon: Icons.location_off,
          text: _errorMessage ?? 'تعذّر تحديد موقعك الحالي.',
          actions: [
            if (_locationFailure == LocationFailure.serviceDisabled)
              OutlinedButton.icon(
                onPressed: _location.openLocationSettings,
                icon: const Icon(Icons.settings),
                label: const Text("فتح إعدادات الموقع"),
              ),
            if (_locationFailure == LocationFailure.permissionDeniedForever)
              OutlinedButton.icon(
                onPressed: _location.openAppSettings,
                icon: const Icon(Icons.settings),
                label: const Text("فتح إعدادات التطبيق"),
              ),
            OutlinedButton(
              onPressed: _search,
              child: const Text("حاول مرة أخرى"),
            ),
          ],
        );
      case _SearchState.searchError:
        return _message(
          icon: Icons.error_outline,
          text: _errorMessage ?? 'حدث خطأ أثناء البحث.',
          actions: [
            OutlinedButton(
              onPressed: _search,
              child: const Text("حاول مرة أخرى"),
            ),
          ],
        );
      case _SearchState.loaded:
        if (_results.isEmpty) {
          return _message(
            icon: Icons.search_off,
            text: 'لا توجد خدمات من تصنيف «$_searchedCategory» '
                'ضمن ${_searchedRadiusKm.round()} كم من موقعك.\n'
                'جرّب توسيع نطاق البحث.',
          );
        }
        return RefreshIndicator(
          onRefresh: _search,
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            itemCount: _results.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => _resultCard(_results[i]),
          ),
        );
    }
  }

  Widget _message({
    IconData? icon,
    bool progress = false,
    required String text,
    List<Widget> actions = const [],
  }) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (progress)
              const CircularProgressIndicator()
            else if (icon != null)
              Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text(text, textAlign: TextAlign.center),
            for (final action in actions) ...[
              const SizedBox(height: 12),
              action,
            ],
          ],
        ),
      ),
    );
  }

  Widget _resultCard(ServiceListItem service) {
    return Card(
      child: ListTile(
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(8),
            image: service.coverImageUrl != null
                ? DecorationImage(
                    image: sizedNetworkImage(
                      context,
                      ApiConfig.resolveUrl(service.coverImageUrl!),
                      longestSide: 50,
                    ),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
        ),
        title: Text(service.title),
        subtitle: Text("بواسطة ${service.provider.displayName}"),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(formatPrice(service.price, decimals: 0)),
            if (service.distanceKm != null)
              Text(
                formatDistance(service.distanceKm!),
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  widget.detailsBuilder?.call(service.id) ??
                  ServiceDetailsScreen(serviceId: service.id),
            ),
          );
        },
      ),
    );
  }
}
