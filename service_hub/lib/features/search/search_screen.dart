import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/config/api_config.dart';
import '../../core/utils/price_format.dart';
import '../../shared/widgets/city_picker_field.dart';
import '../auth/data/city_service.dart';
import '../service/data/catalog_service.dart';
import '../service/data/service_models.dart';
import '../service/service_details_screen.dart';
import 'nearby_search_screen.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    this.catalogService,
    this.cityService,
    this.detailsBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject a fake backend.
  final CatalogService? catalogService;
  final CityService? cityService;
  final Widget Function(int serviceId)? detailsBuilder;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final CityService _cityService = widget.cityService ?? CityService();
  final _queryController = TextEditingController();

  List<ServiceCategory> _categories = [];
  List<ServiceListItem> _services = [];
  List<String> _cities = [];
  bool _loading = true;
  String? _error;
  int? _selectedCategoryId;
  String? _selectedCity;

  // The text of the last search that was sent, and a counter so a slow
  // answer to an old search can never overwrite a newer one.
  String _searchedQuery = '';
  int _requestId = 0;
  Timer? _debounce;

  static const _debounceDelay = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _load();
    _queryController.addListener(_onQueryChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  /// Waits until the user pauses typing, then searches.
  void _onQueryChanged() {
    _debounce?.cancel();
    final text = _queryController.text.trim();
    if (text == _searchedQuery) return;
    _debounce = Timer(_debounceDelay, _refreshServices);
  }

  /// With text: the smart search (understands what the person needs).
  /// Without text: the plain list, filtered by category / city.
  Future<List<ServiceListItem>> _fetchServices() {
    final text = _queryController.text.trim();
    _searchedQuery = text;
    if (text.isEmpty) {
      return _catalog.services(
        categoryId: _selectedCategoryId,
        city: _selectedCity,
      );
    }
    return _catalog.searchSmart(
      query: text,
      categoryId: _selectedCategoryId,
      city: _selectedCity,
    );
  }

  Future<void> _refreshServices() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final services = await _fetchServices();
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _services = services;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _catalog.categories(),
        _fetchServices(),
        _cityService.cities(),
      ]);
      if (!mounted) return;
      setState(() {
        final loadedCategories = results[0] as List<ServiceCategory>;
        _categories = [
          for (final c in loadedCategories)
            if (!c.isOther) c,
          for (final c in loadedCategories)
            if (c.isOther) c,
        ];
        _services = results[1] as List<ServiceListItem>;
        _cities = results[2] as List<String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loading = false;
      });
    }
  }

  Future<void> _selectCategory(int? id) {
    _debounce?.cancel();
    setState(() => _selectedCategoryId = id);
    return _refreshServices();
  }

  Future<void> _selectCity(String? city) {
    _debounce?.cancel();
    setState(() => _selectedCity = city);
    return _refreshServices();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("البحث عن خدمات"),
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
        titleSpacing: -2,
        actions: [
          IconButton(
            tooltip: "خدمات قريبة مني",
            icon: const Icon(Icons.near_me),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NearbySearchScreen()),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: "searchBar",
              child: Material(
                color: Colors.transparent,
                child: TextField(
                  controller: _queryController,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) {
                    _debounce?.cancel();
                    if (_queryController.text.trim() != _searchedQuery) {
                      _refreshServices();
                    }
                  },
                  decoration: const InputDecoration(
                    hintText: "ابحث بكلماتك..   ",
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "المدينة",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            CityPickerField(
              cities: _cities,
              selected: _selectedCity,
              hint: "كل المدن",
              allLabel: "كل المدن",
              onChanged: _selectCity,
            ),
            const SizedBox(height: 25),
            const Text(
              "التصنيفات",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _categoryChip("الكل", null),
                  for (final c in _categories) _categoryChip(c.name, c.id),
                ],
              ),
            ),
            const SizedBox(height: 25),
            const Text(
              "الخدمات",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 15),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text("إعادة المحاولة")),
          ],
        ),
      );
    }
    final services = _services;
    if (services.isEmpty) {
      return Center(
        child: Text(
          _queryController.text.trim().isEmpty
              ? "لم يتم العثور على خدمات."
              : "لم نجد خدمات مطابقة لطلبك، جرّب كلمات أخرى.",
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.separated(
      itemCount: services.length,
      separatorBuilder: (_, _) => const SizedBox(height: 15),
      itemBuilder: (_, i) => _serviceCard(services[i]),
    );
  }

  Widget _categoryChip(String label, int? id) {
    final selected = _selectedCategoryId == id;
    return GestureDetector(
      onTap: () => _selectCategory(id),
      child: Container(
        margin: const EdgeInsetsDirectional.only(end: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(color: selected ? Colors.white : null),
        ),
      ),
    );
  }

  Widget _serviceCard(ServiceListItem service) {
    return Card(
      child: ListTile(
        leading: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
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
        trailing: Text(formatPrice(service.price, decimals: 0)),
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
