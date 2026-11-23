import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api/api_exception.dart';
import '../../core/api/upload_service.dart';
import '../../core/config/api_config.dart';
import '../../shared/widgets/full_screen_image_viewer.dart';
import 'data/portfolio_service.dart';
import 'data/service_models.dart';
import '../../core/utils/error_text.dart';
import '../../core/utils/image_sizing.dart';

/// Lets a provider attach "previous work" photos to one of their services
/// (item: "اضافة صور الاعمال السابقة"). Reachable from the provider's own
/// service list on the profile screen.
class ServicePortfolioScreen extends StatefulWidget {
  final int serviceId;
  final String serviceTitle;

  /// Optional overrides, mainly so widget tests can inject fakes.
  final PortfolioService? portfolioService;
  final UploadService? uploadService;
  final ImagePicker? imagePicker;

  const ServicePortfolioScreen({
    super.key,
    required this.serviceId,
    required this.serviceTitle,
    this.portfolioService,
    this.uploadService,
    this.imagePicker,
  });

  @override
  State<ServicePortfolioScreen> createState() => _ServicePortfolioScreenState();
}

class _ServicePortfolioScreenState extends State<ServicePortfolioScreen> {
  late final PortfolioService _portfolio =
      widget.portfolioService ?? PortfolioService();
  late final UploadService _uploader =
      widget.uploadService ?? UploadService();
  late final ImagePicker _picker = widget.imagePicker ?? ImagePicker();

  late Future<List<PortfolioItem>> _future;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _future = _portfolio.list(widget.serviceId);
  }

  void _reload() => setState(() {
    _future = _portfolio.list(widget.serviceId);
  });

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addPhoto() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      // Caps the longest edge; keeps the aspect ratio and never enlarges.
      maxWidth: maxUploadImageDimension.toDouble(),
      maxHeight: maxUploadImageDimension.toDouble(),
    );
    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      final url = await _uploader.uploadImage(picked);
      await _portfolio.add(widget.serviceId, url);
      _reload();
    } on ApiException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _remove(PortfolioItem item) async {
    try {
      await _portfolio.delete(widget.serviceId, item.id);
      _reload();
    } on ApiException catch (e) {
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("${widget.serviceTitle} — أعمال سابقة")),
      floatingActionButton: FloatingActionButton(
        onPressed: _uploading ? null : _addPhoto,
        child: _uploading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.add_a_photo),
      ),
      body: FutureBuilder<List<PortfolioItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(errorText(snapshot.error)));
          }
          final items = snapshot.data ?? [];
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  "لا توجد صور أعمال سابقة بعد. اضغط على زر الكاميرا لإضافة صورة.",
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final item = items[i];
              return Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      FullScreenImageViewer.route(
                        imageUrl: ApiConfig.resolveUrl(item.imageUrl),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        ApiConfig.resolveUrl(item.imageUrl),
                        fit: BoxFit.cover,
                        // A tile of the 2-column grid.
                        cacheWidth: decodePixels(
                          context,
                          MediaQuery.sizeOf(context).width / 2,
                        ),
                        errorBuilder: (_, _, _) => Container(
                          color: Colors.grey.shade300,
                          child: const Icon(Icons.broken_image),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => _remove(item),
                      child: const CircleAvatar(
                        radius: 14,
                        backgroundColor: Colors.black54,
                        child: Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
