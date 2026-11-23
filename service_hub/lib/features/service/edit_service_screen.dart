import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_exception.dart';
import '../../core/utils/price_format.dart';
import '../../core/api/upload_service.dart';
import '../../core/config/api_config.dart';
import '../../core/location/location_service.dart';
import '../../shared/widgets/category_picker_field.dart';
import '../../core/storage/token_store.dart';
import '../availability/data/availability_service.dart';
import '../availability/working_hours_gate.dart';
import 'data/catalog_service.dart';
import 'data/service_models.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

/// Lets a provider edit one of their own existing service listings —
/// title, description, price, category, remote flag, location, and
/// whether it's active/inactive. Backed by PATCH /services/{id}
/// (ServiceUpdateRequest), which was already wired up server-side before
/// this screen existed.
class EditServiceScreen extends StatefulWidget {
  final int serviceId;

  /// Optional overrides, mainly so widget tests can inject fakes.
  final CatalogService? catalogService;
  final UploadService? uploadService;
  final ImagePicker? imagePicker;
  final LocationService? locationService;
  final TokenStore? tokenStore;
  final AvailabilityService? availabilityService;
  final Widget Function(int providerId)? availabilityScreenBuilder;

  const EditServiceScreen({
    super.key,
    required this.serviceId,
    this.catalogService,
    this.uploadService,
    this.imagePicker,
    this.locationService,
    this.tokenStore,
    this.availabilityService,
    this.availabilityScreenBuilder,
  });

  @override
  State<EditServiceScreen> createState() => _EditServiceScreenState();
}

class _EditServiceScreenState extends State<EditServiceScreen> {
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

  late Future<_EditFormData> _formDataFuture;
  // Populated by _load() alongside the controllers above, so _save() can
  // look up the selected category's isOther flag synchronously.
  List<ServiceCategory> _categories = [];

  int? _categoryId;
  bool _isRemote = false;
  bool _wasRemote = false; // as loaded: switching remote -> on-site needs working hours
  bool _isActive = true;
  double? _latitude;
  double? _longitude;
  String? _existingCoverImageUrl;
  String _selectedPriceUnit = 'fixed';

  XFile? _newCoverImage;
  Uint8List? _newCoverImageBytes;
  bool _uploadingCover = false;
  bool _locatingDevice = false;
  String? _locationError;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _formDataFuture = _load();
  }

  Future<_EditFormData> _load() async {
    final results = await Future.wait([
      _catalog.service(widget.serviceId),
      _catalog.categories(),
    ]);
    final service = results[0] as ServiceDetail;
    final categories = results[1] as List<ServiceCategory>;

    _descriptionController.text = service.description;
    // A service without a price shows an empty (optional) field.
    _priceController.text = service.price?.toStringAsFixed(2) ?? '';
    _categoryId = service.category.id;
    _customCategoryLabelController.text = service.customCategoryLabel ?? '';
    _isRemote = service.isRemote;
    _wasRemote = service.isRemote;
    _isActive = service.status == 'active';
    _latitude = service.latitude;
    _longitude = service.longitude;
    _existingCoverImageUrl = service.coverImageUrl;
    // Never null: the model already falls back to 'fixed'.
    _selectedPriceUnit = service.priceUnit;
    _categories = categories;

    return _EditFormData(categories: categories);
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _priceController.dispose();
    _customCategoryLabelController.dispose();
    super.dispose();
  }

  /// See AddServiceScreen._selectedCategory.
  ServiceCategory? get _selectedCategory {
    for (final category in _categories) {
      if (category.id == _categoryId) return category;
    }
    return null;
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
      _newCoverImage = picked;
      _newCoverImageBytes = bytes;
    });
  }

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

  Future<void> _save() async {
    final description = _descriptionController.text.trim();
    // Optional: emptying the field removes the price (null, never 0).
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

    // Turning a remote service into an on-site one needs working hours too.
    if (!_isRemote && _wasRemote) {
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
      String? newCoverImageUrl;
      if (_newCoverImage != null) {
        setState(() => _uploadingCover = true);
        newCoverImageUrl = await _uploader.uploadImage(_newCoverImage!);
        if (mounted) setState(() => _uploadingCover = false);
      }

      await _catalog.updateService(
        widget.serviceId,
        categoryId: _categoryId,
        description: description,
        price: price.value,
        removePrice: price.value == null,
        isRemote: _isRemote,
        status: _isActive ? 'active' : 'inactive',
        latitude: _latitude,
        longitude: _longitude,
        coverImageUrl: newCoverImageUrl,
        customCategoryLabel: selectedCategory?.isOther == true
            ? customCategoryLabel
            : null,
        priceUnit: _selectedPriceUnit,
      );
      if (!mounted) return;
      _showMessage('تم تحديث الخدمة!');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تعديل الخدمة"),
        titleSpacing: -3,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: FutureBuilder<_EditFormData>(
        future: _formDataFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(errorText(snapshot.error)));
          }
          final loadedCategories = snapshot.data!.categories;
          final categories = [
            for (final c in loadedCategories)
              if (!c.isOther) c,
            for (final c in loadedCategories)
              if (c.isOther) c,
          ];

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Same order as when publishing: category (the service's
                // identity), description, then the optional price.
                _boxed(
                  CategoryPickerField(
                    categories: categories,
                    selectedId: _categoryId,
                    onChanged: (id) => setState(() => _categoryId = id),
                  ),
                ),
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
                // Price and its unit side by side, half each, same box and
                // shadow.
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
                      image: _newCoverImageBytes != null
                          ? DecorationImage(
                              image: MemoryImage(_newCoverImageBytes!),
                              fit: BoxFit.cover,
                            )
                          : (_existingCoverImageUrl != null
                                ? DecorationImage(
                                    image: sizedNetworkImage(
                                      context,
                                      ApiConfig.resolveUrl(
                                        _existingCoverImageUrl!,
                                      ),
                                      longestSide:
                                          MediaQuery.sizeOf(context).width,
                                    ),
                                    fit: BoxFit.cover,
                                  )
                                : null),
                    ),
                    child:
                        (_existingCoverImageUrl == null &&
                            _newCoverImageBytes == null)
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("نشطة"),
                  subtitle: const Text(
                    "أوقف هذا الخيار لإخفاء الخدمة من البحث دون حذفها",
                  ),
                  value: _isActive,
                  onChanged: (value) => setState(() => _isActive = value),
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
                        _latitude != null
                            ? Icons.location_on
                            : Icons.location_off,
                        color: _latitude != null ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _latitude != null
                              ? "تم تحديد الموقع — تظهر هذه الخدمة في "
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                _latitude != null
                                    ? "تحديث"
                                    : "استخدم موقعي",
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
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _submitting ? null : _save,
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
                          "حفظ التغييرات",
                          style: TextStyle(color: Colors.white),
                        ),
                ),
              ],
            ),
          );
        },
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

class _EditFormData {
  final List<ServiceCategory> categories;

  _EditFormData({required this.categories});
}
