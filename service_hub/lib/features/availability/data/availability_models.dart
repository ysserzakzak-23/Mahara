// Mirrors backend/app/schemas/availability.py.

class AvailabilityWindow {
  final int id;
  final int dayOfWeek; // 0=Monday ... 6=Sunday, matching the backend.
  final String startTime; // "HH:MM:SS" as returned by the backend
  final String endTime;
  final bool isActive;

  AvailabilityWindow({
    required this.id,
    required this.dayOfWeek,
    required this.startTime,
    required this.endTime,
    this.isActive = true,
  });

  factory AvailabilityWindow.fromJson(Map<String, dynamic> json) =>
      AvailabilityWindow(
        id: json['id'] as int,
        dayOfWeek: json['day_of_week'] as int,
        startTime: json['start_time'] as String,
        endTime: json['end_time'] as String,
        isActive: json['is_active'] as bool? ?? true,
      );
}

/// One bookable hour of a provider's day (GET .../availability/slots).
/// Times are the backend's "HH:MM:SS" wall-clock strings.
class DaySlot {
  final String startTime;
  final String endTime;
  final bool isBooked;

  DaySlot({required this.startTime, required this.endTime, required this.isBooked});

  factory DaySlot.fromJson(Map<String, dynamic> json) => DaySlot(
        startTime: json['start_time'] as String,
        endTime: json['end_time'] as String,
        isBooked: json['is_booked'] as bool? ?? false,
      );

  int get startHour => int.parse(startTime.split(':')[0]);
  int get startMinute => int.parse(startTime.split(':')[1]);
}

class DaySlots {
  final String day; // "YYYY-MM-DD"
  final int dayOfWeek; // 0=Monday ... 6=Sunday
  final List<DaySlot> slots;

  DaySlots({required this.day, required this.dayOfWeek, required this.slots});

  factory DaySlots.fromJson(Map<String, dynamic> json) => DaySlots(
        day: json['day'] as String,
        dayOfWeek: json['day_of_week'] as int,
        slots: (json['slots'] as List)
            .map((e) => DaySlot.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

const List<String> kWeekdayNames = [
  'الاثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
];
