import '../../../core/api/api_client.dart';
import '../../../core/api/paged_result.dart';
import 'appointment_models.dart';

/// Booking/appointment access against the FastAPI backend.
class AppointmentService {
  AppointmentService({ApiClient? apiClient})
      : _api = apiClient ?? ApiClient.shared;

  final ApiClient _api;

  /// GET /appointments/me — one page of the user's bookings, as customer
  /// (default) or as provider.
  ///
  /// Pagination is opt-in on the backend: [page] and [pageSize] are only
  /// sent when given, and without them the whole list comes back as one
  /// complete page. A backend that predates pagination ignores the two
  /// parameters and answers with the whole list as well, which
  /// [parsePagedResponse] reads as a single page with no next — so the
  /// caller stops instead of asking for a page 2 that does not exist.
  ///
  /// A malformed body is an error, never an empty list: an empty bookings
  /// screen reads as "you have no appointments".
  Future<PagedResult<Appointment>> myAppointments({
    bool asProvider = false,
    int? page,
    int? pageSize,
  }) async {
    final query = <String, String>{
      'as_provider': '$asProvider',
      if (page != null) 'page': '$page',
      if (pageSize != null) 'page_size': '$pageSize',
    };
    final encoded = query.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final json = await _api.get('/appointments/me?$encoded');
    return parsePagedResponse(json, Appointment.fromJson);
  }

  /// POST /appointments — request a booking for a service.
  ///
  /// [startTime]/[endTime] must be explicit UTC `DateTime`s (built with
  /// `DateTime.utc(...)`, not `DateTime(...)`) — see
  /// CreateBookingScreen._confirm for why: the appointments table column is
  /// timezone-aware, so sending an unambiguous UTC instant avoids any
  /// dependency on the database session's timezone setting. Provider
  /// availability windows, by contrast, are plain wall-clock hours with no
  /// timezone concept, and are compared against this same UTC value's
  /// hour/minute directly on the backend (app/services/appointment_service.py).
  ///
  /// Leave both times out for a request without a day/hour: the backend
  /// accepts it only for a remote service whose provider set no working hours.
  Future<Appointment> createAppointment({
    required int serviceId,
    DateTime? startTime,
    DateTime? endTime,
    String? customerNotes,
  }) async {
    final json = await _api.post('/appointments', body: {
      'service_id': serviceId,
      if (startTime != null) 'start_time': startTime.toIso8601String(),
      if (endTime != null) 'end_time': endTime.toIso8601String(),
      if (customerNotes != null && customerNotes.isNotEmpty)
        'customer_notes': customerNotes,
    });
    return Appointment.fromJson(json as Map<String, dynamic>);
  }

  /// POST /appointments/{id}/cancel — also frees up the time slot so
  /// another customer can book the same provider/time again.
  Future<Appointment> cancel(int id, {String? reason}) async {
    final json = await _api.post('/appointments/$id/cancel', body: {
      if (reason != null && reason.isNotEmpty) 'cancellation_reason': reason,
    });
    return Appointment.fromJson(json as Map<String, dynamic>);
  }

  /// POST /appointments/{id}/complete — marks a past appointment as done.
  Future<Appointment> complete(int id) async {
    final json = await _api.post('/appointments/$id/complete');
    return Appointment.fromJson(json as Map<String, dynamic>);
  }

  /// POST /appointments/{id}/accept — provider-only: accepts a pending
  /// booking request, moving it from "pending" to "confirmed".
  Future<Appointment> accept(int id) async {
    final json = await _api.post('/appointments/$id/accept');
    return Appointment.fromJson(json as Map<String, dynamic>);
  }

  /// POST /appointments/{id}/reject — provider-only: declines a pending
  /// booking request, freeing up the time slot for someone else.
  Future<Appointment> reject(int id, {String? reason}) async {
    final json = await _api.post('/appointments/$id/reject', body: {
      if (reason != null && reason.isNotEmpty) 'cancellation_reason': reason,
    });
    return Appointment.fromJson(json as Map<String, dynamic>);
  }
}
