import '../../../core/api/api_client.dart';
import '../../../core/utils/date_labels.dart';
import 'availability_models.dart';

/// Each provider manages their own recurring weekly working-hours windows
/// (backend/app/routers/availability.py). Appointment booking validates
/// requested times against these windows, so this is what actually
/// controls when a provider can be booked.
class AvailabilityService {
  AvailabilityService({ApiClient? apiClient}) : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  Future<List<AvailabilityWindow>> list(int providerId) async {
    final json =
        await _api.get('/providers/$providerId/availability', auth: false);
    return (json as List)
        .map((e) => AvailabilityWindow.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /providers/{id}/availability/slots?day=YYYY-MM-DD — the provider's
  /// one-hour slots for that day, each marked booked or free, so a customer
  /// never has to guess which hours are taken.
  Future<DaySlots> slots(int providerId, DateTime day) async {
    final json = await _api.get(
      '/providers/$providerId/availability/slots?day=${isoDate(day)}',
      auth: false,
    );
    return DaySlots.fromJson(json as Map<String, dynamic>);
  }

  /// [startTime]/[endTime] as "HH:MM" (24h); the backend accepts and
  /// returns "HH:MM:SS".
  Future<AvailabilityWindow> create(
    int providerId, {
    required int dayOfWeek,
    required String startTime,
    required String endTime,
  }) async {
    final json = await _api.post(
      '/providers/$providerId/availability',
      body: {
        'day_of_week': dayOfWeek,
        'start_time': '$startTime:00',
        'end_time': '$endTime:00',
      },
    );
    return AvailabilityWindow.fromJson(json as Map<String, dynamic>);
  }

  Future<void> deactivate(int providerId, int windowId) {
    return _api.delete('/providers/$providerId/availability/$windowId');
  }
}
