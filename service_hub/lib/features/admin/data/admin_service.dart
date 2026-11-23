import '../../../core/api/api_client.dart';
import '../../../core/api/paged_result.dart';
import 'admin_models.dart';

/// Every call here requires an authenticated admin account — the backend's
/// `require_admin` dependency (app/core/dependencies.py) rejects everyone
/// else with a 403, which surfaces as an ApiException the admin screens
/// display as-is. Pagination changes nothing about that: a paginated
/// request from a non-admin is refused exactly like an unpaginated one.
class AdminService {
  AdminService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<PlatformStats> stats() async {
    final json = await _api.get('/admin/stats');
    return PlatformStats.fromJson(json as Map<String, dynamic>);
  }

  /// One page of all users, newest first.
  ///
  /// Opt-in pagination, in both shapes — see
  /// [NotificationService.list](../../notifications/data/notification_service.dart).
  /// The backend sends no `total`: nothing on the dashboard shows a count,
  /// and `has_next` is what decides whether to ask for more.
  Future<PagedResult<AdminUser>> users({int? page, int? pageSize}) async {
    final json = await _api.get(_paged('/admin/users', {}, page, pageSize));
    return parsePagedResponse(json, AdminUser.fromJson);
  }

  Future<AdminUser> setUserActive(int userId, bool isActive) async {
    final json = await _api.put(
      '/admin/users/$userId/active-status',
      body: {'is_active': isActive},
    );
    return AdminUser.fromJson(json as Map<String, dynamic>);
  }

  Future<AdminUser> setUserRole(int userId, String role) async {
    final json = await _api.put(
      '/admin/users/$userId/role',
      body: {'role': role},
    );
    return AdminUser.fromJson(json as Map<String, dynamic>);
  }

  /// One page of services for moderation, newest first, optionally filtered
  /// by status. The filter is applied before paging, so it holds across
  /// every page.
  Future<PagedResult<AdminServiceListing>> services({
    String? status,
    int? page,
    int? pageSize,
  }) async {
    final json = await _api.get(_paged(
      '/admin/services',
      {'status': ?status},
      page,
      pageSize,
    ));
    return parsePagedResponse(json, AdminServiceListing.fromJson);
  }

  Future<AdminServiceListing> setServiceStatus(int serviceId, String status) async {
    final json = await _api.put(
      '/admin/services/$serviceId/status',
      body: {'status': status},
    );
    return AdminServiceListing.fromJson(json as Map<String, dynamic>);
  }

  /// [path] with the filters plus the pagination parameters, which are left
  /// out entirely when not asked for — that absence is what keeps the
  /// legacy array response.
  String _paged(String path, Map<String, String> filters, int? page, int? pageSize) {
    final query = <String, String>{
      ...filters,
      if (page != null) 'page': '$page',
      if (pageSize != null) 'page_size': '$pageSize',
    };
    if (query.isEmpty) return path;
    final encoded =
        query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '$path?$encoded';
  }
}
