import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Full-screen image viewer with pinch-to-zoom, opened when the user taps
/// a thumbnail (profile avatar or a portfolio "previous work" photo) to
/// see it larger. Pass either [imageUrl] (a network image, resolved via
/// ApiConfig.resolveUrl by the caller) or [imageBytes] (an unsaved local
/// pick, e.g. before upload finishes) — exactly one should be provided.
class FullScreenImageViewer extends StatelessWidget {
  final String? imageUrl;
  final Uint8List? imageBytes;

  const FullScreenImageViewer({super.key, this.imageUrl, this.imageBytes})
      : assert(
          imageUrl != null || imageBytes != null,
          'Provide either imageUrl or imageBytes',
        );

  static Route<void> route({String? imageUrl, Uint8List? imageBytes}) {
    return MaterialPageRoute(
      builder: (_) => FullScreenImageViewer(
        imageUrl: imageUrl,
        imageBytes: imageBytes,
      ),
      fullscreenDialog: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: imageBytes != null
              ? Image.memory(imageBytes!, fit: BoxFit.contain)
              : Image.network(
                  imageUrl!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(
                    Icons.broken_image,
                    color: Colors.white54,
                    size: 60,
                  ),
                ),
        ),
      ),
    );
  }
}
