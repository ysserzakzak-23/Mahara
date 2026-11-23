import '../../../core/api/api_client.dart';
import 'service_models.dart';

/// Per-service "previous work" gallery (backend/app/routers/portfolio.py).
class PortfolioService {
  PortfolioService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<List<PortfolioItem>> list(int serviceId) async {
    final json = await _api.get('/services/$serviceId/portfolio', auth: false);
    return (json as List)
        .map((e) => PortfolioItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PortfolioItem> add(int serviceId, String imageUrl, {String? caption}) async {
    final json = await _api.post('/services/$serviceId/portfolio', body: {
      'image_url': imageUrl,
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    });
    return PortfolioItem.fromJson(json as Map<String, dynamic>);
  }

  Future<void> delete(int serviceId, int itemId) {
    return _api.delete('/services/$serviceId/portfolio/$itemId');
  }
}
