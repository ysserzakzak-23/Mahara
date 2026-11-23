import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_exception.dart';
import '../../core/utils/price_format.dart';
import '../../core/api/upload_service.dart';
import '../../core/location/location_service.dart';
import '../../shared/widgets/category_picker_field.dart';
import '../../core/storage/token_store.dart';
import '../availability/data/availability_service.dart';
import '../availability/working_hours_gate.dart';
import 'data/catalog_service.dart';
import 'data/service_models.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class AddServiceScreen extends StatefulWidget {
  const AddServiceScreen({
    super.key,
    this.catalogService,
    this.uploadService,
    this.imagePicker,
    this.locationService,
    this.tokenStore,
    this.availabilityService,
    this.availabilityScreenBuilder,
  });

  /// Optional overrides, mainly so widget tests can inject fakes.
  final CatalogService? catalogService;
  final UploadService? uploadService;
  final ImagePicker? imagePicker;
  final LocationService? locationService;
  final TokenStore? tokenStore;
  final AvailabilityService? availabilityService;
  final Widget Function(int providerId)? availabilityScreenBuilder;

  @override
  State<AddServiceScreen> createState() => _AddServiceScreenState();
}

class _AddServiceScreenState extends State<AddServiceScreen> {
  late final CatalogService _catalog =
      widget.catalogService ?? CatalogService();
  late final UploadService _uploader =
      widget.uploadService ?? UploadService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();
  late final LocationService _locationService =
      widget.locationService ?? LocationService();

  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _customCategoryLabelController = TextEditingController();

  late Future<List<ServiceCategory>> _categoriesFuture;
  // Kept alongside _categoriesFuture (used only for the FutureBuilder's
  // loading/error UI) so _publish() can look up the selected category's
  // isOther flag synchronously for validation.
  List<ServiceCategory> _categories = [];
  int? _categoryId;
  bool _submitting = false;
  XFile? _coverImage;
  Uint8List? _coverImageBytes;
  bool _uploadingCover = false;
  bool _isRemote = false;
  String _selectedPriceUnit = 'fixed';

  double? _latitude;
  double? _longitude;
  bool _locatingDevice = false;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _categoriesFuture = _catalog.categories();
    _categoriesFuture.then(
      (cats) {
        if (mounted) setState(() => _categories = cats);
      },
      // The FutureBuilder below shows the error; this only avoids a second,
      // unhandled-exception report for the same failure.
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _priceController.dispose();
    _customCategoryLabelController.dispose();
    super.dispose();
  }

  /// The full ServiceCategory object for the currently selected
  /// _categoryId, once categories have loaded — null while still loading
  /// or if nothing is selected yet.
  ServiceCategory? get _selectedCategory {
    for (final category in _categories) {
      if (category.id == _categoryId) return category;
    }
    return null;
  }

  Future<void> _pickCoverImage() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      // Caps the longest edge; keeps the aspect ratio and never enlarges.
      maxWidth: maxUploadImageDimension.toDouble(),
      maxHeight: maxUploadImageDimension.toDouble(),
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    setState(() {
      _coverImage = picked;
      _coverImageBytes = bytes;
    });
  }

  /// Grabs the provider's current GPS position so this service shows up
  /// in "nearby services" search (GET /search/services) — without a
  /// latitude/longitude, a service can never be found by that search,
  /// only by category/keyword browsing.
  Future<void> _useCurrentLocation() async {
    setState(() {
      _locatingDevice = true;
      _locationError = null;
    });
    try {
      final position = await _locationService.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locatingDevice = false;
      });
    } on LocationServiceException catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = e.message;
        _locatingDevice = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = errorText(e);
        _locatingDevice = false;
      });
    }
  }

  Future<void> _publish() async {
    final description = _descriptionController.text.trim();
    // Optional: an empty field means "no price" (null, never 0).
    final price = PriceInput.parse(_priceController.text);

    if (_categoryId == null) {
      _showMessage('يرجى اختيار التصنيف.');
      return;
    }
    final selectedCategory = _selectedCategory;
    final customCategoryLabel = _customCategoryLabelController.text.trim();
    if (selectedCategory?.isOther == true && customCategoryLabel.isEmpty) {
      _showMessage('يرجى كتابة نوع خدمتك بالتحديد.');
      return;
    }
    if (description.length < 10) {
      _showMessage('الوصف يجب أن يتكون من 10 أحرف على الأقل.');
      return;
    }
    if (!price.isValid) {
      _showMessage('يرجى إدخال سعر صحيح، أو اترك حقل السعر فارغاً.');
      return;
    }

    // A service that is not remote is booked on a day and hour, so the
    // provider's working hours must exist first (asked only once).
    if (!_isRemote) {
      final ready = await ensureWorkingHours(
        context,
        tokenStore: widget.tokenStore,
        availabilityService: widget.availabilityService,
        availabilityScreenBuilder: widget.availabilityScreenBuilder,
      );
      if (!ready || !mounted) return;
    }

    setState(() => _submitting = true);

    try {
      String? coverImageUrl;
      if (_coverImage != null) {
        setState(() => _uploadingCover = true);
        coverImageUrl = await _uploader.uploadImage(_coverImage!);
        if (mounted) setState(() => _uploadingCover = false);
      }
      await _catalog.createService(
        categoryId: _categoryId!,
        description: description,
        price: price.value,
        coverImageUrl: coverImageUrl,
        isRemote: _isRemote,
        latitude: _latitude,
        longitude: _longitude,
        customCategoryLabel: selectedCategory?.isOther == true
            ? customCategoryLabel
            : null,
        priceUnit: _selectedPriceUnit,
      );
      if (!mounted) return;
      _showMessage('تم نشر الخدمة!');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("إضافة خدمة"),
        titleSpacing: -3,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The category IS the service's identity (there is no separate
            // name), so it comes first, then the description, then the
            // optional price.
            FutureBuilder<List<ServiceCategory>>(
              future: _categoriesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError) {
                  return Text('تعذّر تحميل التصنيفات: ${errorText(snapshot.error)}');
                }
                final loaded = snapshot.data ?? [];
                final categories = [
                  for (final c in loaded)
                    if (!c.isOther) c,
                  for (final c in loaded)
                    if (c.isOther) c,
                ];
                return _boxed(
                  CategoryPickerField(
                    categories: categories,
                    selectedId: _categoryId,
                    onChanged: (id) => setState(() => _categoryId = id),
                  ),
                );
              },
            ),
            // Only category.isOther selections need this — everything else
            // is fully described by the curated category name itself.
            if (_selectedCategory?.isOther == true) ...[
              const SizedBox(height: 15),
              _boxed(
                TextField(
                  controller: _customCategoryLabelController,
                  decoration: const InputDecoration(
                    hintText: "ما نوع خدمتك؟ (مثل: سباك)",
                  ),
                ),
              ),
            ],
            const SizedBox(height: 15),
            _boxed(
              TextField(
                controller: _descriptionController,
                maxLines: 4,
                decoration: const InputDecoration(hintText: "الوصف"),
              ),
            ),
            const SizedBox(height: 15),
            // Price and its unit side by side, half each, same box and shadow.
            Row(
              key: const Key('price-row'),
              children: [
                Expanded(
                  child: _boxed(
                    TextField(
                      controller: _priceController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        hintText: "السعر (اختياري) (\$)",
                        hintMaxLines: 1,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _boxed(
                    DropdownButtonFormField<String>(
                      key: const Key('price-unit'),
                      initialValue: _selectedPriceUnit,
                      isExpanded: true,
                      borderRadius: BorderRadius.circular(14),
                      items: const [
                        DropdownMenuItem(value: 'fixed', child: Text('سعر ثابت')),
                        DropdownMenuItem(value: 'per_hour', child: Text('بالساعة')),
                        DropdownMenuItem(value: 'per_visit', child: Text('بالزيارة')),
                        DropdownMenuItem(value: 'per_day', child: Text('باليوم')),
                      ],
                      onChanged: (val) => setState(() => _selectedPriceUnit = val!),
                      decoration: const InputDecoration(hintText: 'وحدة السعر'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _pickCoverImage,
              child: Container(
                height: 140,
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(14),
                  image: _coverImageBytes != null
                      ? DecorationImage(
                          image: MemoryImage(_coverImageBytes!),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: _coverImageBytes == null
                    ? const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add_a_photo, size: 35),
                            SizedBox(height: 6),
                            Text("أضف صورة غلاف"),
                          ],
                        ),
                      )
                    : null,
              ),
            ),
            if (_uploadingCover) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: 20),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text("تُقدَّم عن بُعد / أونلاين"),
              subtitle: const Text(
                "فعّل هذا الخيار إذا لم يكن العملاء بحاجة للقائك شخصياً",
              ),
              value: _isRemote,
              onChanged: (value) => setState(() => _isRemote = value),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    _latitude != null ? Icons.location_on : Icons.location_off,
                    color: _latitude != null ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _latitude != null
                          ? "تم تحديد الموقع — ستظهر هذه الخدمة في "
                                "البحث عن الخدمات القريبة."
                          : "لم يتم تحديد الموقع — لن يجد العملاء الذين يستخدمون "
                                "البحث عن «الخدمات القريبة» هذه الخدمة.",
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _locatingDevice ? null : _useCurrentLocation,
                    child: _locatingDevice
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _latitude != null ? "تحديث" : "استخدم موقعي",
                          ),
                  ),
                ],
              ),
            ),
            if (_locationError != null) ...[
              const SizedBox(height: 6),
              Text(
                _locationError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _submitting ? null : _publish,
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      "نشر الخدمة",
                      style: TextStyle(color: Colors.white),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _boxed(Widget child) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 4,
            offset: Offset(10, 0),
          ),
        ],
      ),
      child: child,
    );
  }
}
