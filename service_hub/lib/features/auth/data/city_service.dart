import '../../../core/api/api_client.dart';

/// Access to the platform's fixed list of cities (backend/app/core/constants.py).
/// Used at registration, on the change-city screen, and as a search filter.
class CityService {
  CityService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<List<String>> cities() async {
    final json = await _api.get('/cities', auth: false);
    return (json as List).map((e) => e.toString()).toList();
  }
}
