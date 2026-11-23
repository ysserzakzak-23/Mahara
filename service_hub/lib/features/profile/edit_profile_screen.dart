import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/upload_service.dart';
import '../../core/config/api_config.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/city_picker_field.dart';
import '../../shared/widgets/full_screen_image_viewer.dart';
import '../auth/data/auth_models.dart';
import '../auth/data/auth_service.dart';
import '../auth/data/city_service.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

class EditProfileScreen extends StatefulWidget {
  final AppUser user;

  /// Optional overrides, mainly so widget tests can inject fakes.
  final AuthService? authService;
  final UploadService? uploadService;
  final CityService? cityService;
  final ImagePicker? imagePicker;

  const EditProfileScreen({
    super.key,
    required this.user,
    this.authService,
    this.uploadService,
    this.cityService,
    this.imagePicker,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final AuthService _authService = widget.authService ?? AuthService();
  late final UploadService _uploader =
      widget.uploadService ?? UploadService();
  late final CityService _cityService = widget.cityService ?? CityService();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _bioController;

  bool _saving = false;
  bool _uploadingAvatar = false;
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  Uint8List? _imageBytes;
  String? _avatarUrl;
  bool _removePhoto = false;
  String? _selectedCity;
  late Future<List<String>> _citiesFuture;

  @override
  void initState() {
    super.initState();
    final p = widget.user.profile;
    _nameController = TextEditingController(text: p?.fullName ?? '');
    _phoneController = TextEditingController(text: p?.phoneNumber ?? '');
    _bioController = TextEditingController(text: p?.bio ?? '');
    _avatarUrl = p?.avatarUrl;
    _selectedCity = p?.city;
    _citiesFuture = _cityService.cities();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.length < 2) {
      _showMessage('الاسم يجب أن يتكون من حرفين على الأقل.');
      return;
    }

    // Phone is optional here (empty clears it), but if filled it must have
    // at least 10 digits.
    final phone = normalizeDigits(_phoneController.text).trim();
    if (phone.isNotEmpty) {
      final phoneProblem = phoneError(phone);
      if (phoneProblem != null) {
        _showMessage(phoneProblem);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      await _authService.updateProfile(
        fullName: name,
        phoneNumber: phone,
        bio: _bioController.text.trim(),
        avatarUrl: _avatarUrl,
        clearAvatar: _removePhoto,
        city: _selectedCity,
      );
      if (!mounted) return;
      _showMessage('تم تحديث الملف الشخصي.');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Picks a photo and immediately uploads it (POST /uploads/image), storing
  /// the returned URL to be saved along with the rest of the profile on
  /// [_save]. Reads bytes for an instant in-memory preview — this works on
  /// web as well as mobile/desktop, unlike a filesystem File.
  Future<void> _pickImage() async {
    final XFile? picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
      // Caps the longest edge; keeps the aspect ratio and never enlarges.
      maxWidth: maxUploadImageDimension.toDouble(),
      maxHeight: maxUploadImageDimension.toDouble(),
    );
    if (picked == null) return;

    final bytes = await picked.readAsBytes();
    setState(() {
      _imageBytes = bytes;
      _removePhoto = false;
      _uploadingAvatar = true;
    });

    try {
      final url = await _uploader.uploadImage(picked);
      if (!mounted) return;
      setState(() => _avatarUrl = url);
    } on ApiException catch (e) {
      _showMessage('تعذّر رفع الصورة: ${e.message}');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  /// Clears the photo locally; the actual deletion happens on [_save]
  /// (via AuthService.updateProfile(clearAvatar: true)).
  void _removeImage() {
    setState(() {
      _imageBytes = null;
      _avatarUrl = null;
      _removePhoto = true;
    });
  }

  void _viewFullImage() {
    if (_imageBytes == null && _avatarUrl == null) return;
    Navigator.of(context).push(
      FullScreenImageViewer.route(
        imageBytes: _imageBytes,
        imageUrl: _imageBytes == null ? ApiConfig.resolveUrl(_avatarUrl!) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تعديل الملف الشخصي"),
        titleSpacing: -2,
        backgroundColor: const Color.fromARGB(0, 77, 75, 75),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Stack(
              children: [
                GestureDetector(
                  onTap: _viewFullImage,
                  child: CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.grey.shade300,
                    backgroundImage: _imageBytes != null
                        ? MemoryImage(_imageBytes!)
                        : (_avatarUrl != null
                            ? sizedNetworkImage(
                                context,
                                ApiConfig.resolveUrl(_avatarUrl!),
                                longestSide: 100,   // radius 50
                              )
                            : null),
                    child: _imageBytes == null && _avatarUrl == null
                        ? const Icon(Icons.person, size: 45)
                        : null,
                  ),
                ),
                if (_uploadingAvatar)
                  const Positioned.fill(
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                if (_imageBytes != null || _avatarUrl != null)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _removeImage,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black54,
                        ),
                        child: const Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: _pickImage,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).primaryColor,
                      ),
                      child: const Icon(
                        Icons.add_a_photo_outlined,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 25),
            _boxed(
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(hintText: "الاسم الكامل"),
              ),
            ),
            const SizedBox(height: 15),
            _boxed(
              TextField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: "رقم الجوال"),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 6, top: 4),
              child: Builder(
                builder: (context) {
                  final text = _phoneController.text;
                  final problem =
                      text.trim().isEmpty ? null : phoneError(text);
                  return Text(
                    problem ?? kPhoneRuleText,
                    style: TextStyle(
                      fontSize: 12,
                      color: problem != null
                          ? Colors.redAccent
                          : Theme.of(context)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 15),
            _boxed(
              TextField(
                controller: _bioController,
                maxLines: 4,
                decoration: const InputDecoration(hintText: "نبذة عني"),
              ),
            ),
            const SizedBox(height: 15),
            FutureBuilder<List<String>>(
              future: _citiesFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const LinearProgressIndicator();
                }
                if (snapshot.hasError) {
                  return Text('تعذّر تحميل المدن: ${errorText(snapshot.error)}');
                }
                final cities = snapshot.data ?? [];
                return _boxed(
                  CityPickerField(
                    cities: cities,
                    selected: _selectedCity,
                    onChanged: (value) => setState(() => _selectedCity = value),
                    hint: "المدينة",
                  ),
                );
              },
            ),
            const SizedBox(height: 25),
            ElevatedButton(
              onPressed: _saving ? null : _save,
              child: _saving
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
