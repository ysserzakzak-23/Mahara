import '../../../core/api/api_client.dart';
import '../../../core/api/paged_result.dart';
import 'notification_models.dart';

class NotificationService {
  NotificationService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  /// One page of the signed-in user's notifications, newest first.
  ///
  /// Pagination is opt-in on the backend: [page] and [pageSize] are only
  /// sent when given, and without them the whole list comes back as one
  /// complete page. A backend that predates pagination ignores the two
  /// parameters and answers with the whole list as well, which
  /// [parsePagedResponse] reads as a single page with no next — so the
  /// caller stops asking instead of requesting page 2 forever.
  ///
  /// Reading a page never marks anything read; only [markRead] and
  /// [markAllRead] do.
  Future<PagedResult<AppNotification>> list({
    bool unreadOnly = false,
    int? page,
    int? pageSize,
  }) async {
    final query = <String, String>{
      'unread_only': '$unreadOnly',
      if (page != null) 'page': '$page',
      if (pageSize != null) 'page_size': '$pageSize',
    };
    final json = await _api.get('/notifications?${_queryString(query)}');
    return parsePagedResponse(json, AppNotification.fromJson);
  }

  Future<int> unreadCount() async {
    final json = await _api.get('/notifications/unread-count');
    return (json as Map<String, dynamic>)['unread_count'] as int;
  }

  Future<void> markRead(int id) {
    return _api.post('/notifications/$id/read');
  }

  Future<void> markAllRead() {
    return _api.post('/notifications/read-all');
  }

  /// Registers this device's FCM token with the backend so it can receive
  /// push notifications. Called on login and app startup — see
  /// core/push/push_notification_service.dart.
  Future<void> registerDevice(String fcmToken, {String? deviceLabel}) {
    return _api.post('/notifications/devices', body: {
      'fcm_token': fcmToken,
      if (deviceLabel != null) 'device_label': deviceLabel,
    });
  }
}

String _queryString(Map<String, String> query) =>
    query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
