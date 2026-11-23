// Mirrors backend/app/schemas/appointment.py.

import '../../service/data/service_models.dart';
import '../../../core/utils/category_names.dart';

class Appointment {
  final int id;
  final int serviceId;
  final String serviceTitle;
  /// null when the customer chose no day/hour: only possible for a remote
  /// service whose provider set no working hours — they agree on it later.
  final DateTime? startTime;
  final DateTime? endTime;
  final String status;
  final String? customerNotes;
  final String? cancellationReason;
  final ServiceProvider customer;
  final ServiceProvider provider;

  Appointment({
    required this.id,
    required this.serviceId,
    required this.serviceTitle,
    this.startTime,
    this.endTime,
    required this.status,
    this.customerNotes,
    this.cancellationReason,
    required this.customer,
    required this.provider,
  });

  factory Appointment.fromJson(Map<String, dynamic> json) => Appointment(
        id: json['id'] as int,
        serviceId: json['service_id'] as int,
        // The backend names a service by its category (see display_title).
        serviceTitle: arabicCategoryName(json['service_title'] as String? ?? 'خدمة'),
        // Deliberately NOT .toLocal() here: this app treats appointment
        // times as plain local wall-clock time end-to-end (see
        // AppointmentService.createAppointment for why) — the backend
        // just echoes back the same clock time we sent, so calling
        // .toLocal() here would shift it by the device's UTC offset a
        // second time and display the wrong hour.
        startTime: json['start_time'] == null
            ? null
            : DateTime.parse(json['start_time'] as String),
        endTime: json['end_time'] == null
            ? null
            : DateTime.parse(json['end_time'] as String),
        status: json['status']?.toString() ?? 'pending',
        customerNotes: json['customer_notes'] as String?,
        cancellationReason: json['cancellation_reason'] as String?,
        customer:
            ServiceProvider.fromJson(json['customer'] as Map<String, dynamic>),
        provider:
            ServiceProvider.fromJson(json['provider'] as Map<String, dynamic>),
      );

  /// False for a request that has no day/hour yet.
  bool get hasTime => startTime != null && endTime != null;
}
