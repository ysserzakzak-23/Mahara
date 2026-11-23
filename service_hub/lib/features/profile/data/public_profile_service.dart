import '../../../core/api/api_client.dart';
import '../../service/data/service_models.dart';

/// Public, read-only profile lookup — used by the "visit provider's
/// profile" screen a customer reaches from a service listing. Deliberately
/// unauthenticated (no auth token required) since it's public info.
class PublicProfileService {
  PublicProfileService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<ServiceProvider> getProfile(int userId) async {
    final json = await _api.get('/users/$userId', auth: false);
    return ServiceProvider.fromJson(json as Map<String, dynamic>);
  }
}
