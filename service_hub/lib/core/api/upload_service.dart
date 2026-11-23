import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import 'api_client.dart';

/// POST /uploads/image — shared by the avatar picker (profile), the service
/// cover-photo picker (add service), and the portfolio ("previous work")
/// photo picker. Returns the relative URL to store on the owning resource
/// (UserProfile.avatarUrl, Service.coverImageUrl, or a new PortfolioItem).
///
/// Takes an [XFile] (from image_picker) rather than a filesystem path:
/// `XFile.readAsBytes()` works identically on mobile, desktop, and web,
/// whereas a raw path is meaningless on web (there's no real file to open).
class UploadService {
  UploadService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<String> uploadImage(XFile file) async {
    final bytes = await file.readAsBytes();
    final json = await _api.uploadFile(
      '/uploads/image',
      fieldName: 'file',
      bytes: bytes,
      filename: file.name,
      contentType: _mediaTypeFor(file),
    );
    return (json as Map<String, dynamic>)['url'] as String;
  }

  /// The backend only accepts a fixed set of image MIME types (see
  /// app/routers/uploads.py: ALLOWED_CONTENT_TYPES), and rejects anything
  /// else — including the generic "application/octet-stream" that
  /// MultipartFile.fromBytes defaults to when no content type is given.
  /// [XFile.mimeType] (set by the browser on web, or by the OS on
  /// mobile/desktop) is the most reliable signal; the file extension is
  /// only a fallback for the rare case it's missing.
  MediaType _mediaTypeFor(XFile file) {
    final reported = file.mimeType;
    if (reported != null && reported.contains('/')) {
      final parts = reported.split('/');
      return MediaType(parts[0], parts[1]);
    }

    final name = file.name.toLowerCase();
    if (name.endsWith('.png')) return MediaType('image', 'png');
    if (name.endsWith('.webp')) return MediaType('image', 'webp');
    if (name.endsWith('.gif')) return MediaType('image', 'gif');
    // Covers .jpg/.jpeg, and is a reasonable default for anything else the
    // gallery picker returns.
    return MediaType('image', 'jpeg');
  }
}
