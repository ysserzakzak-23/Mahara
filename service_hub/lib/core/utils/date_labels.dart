import '../../features/availability/data/availability_models.dart' show kWeekdayNames;

/// Month names as used in Syria / the Levant.
const List<String> kMonthNames = [
  'كانون الثاني',
  'شباط',
  'آذار',
  'نيسان',
  'أيار',
  'حزيران',
  'تموز',
  'آب',
  'أيلول',
  'تشرين الأول',
  'تشرين الثاني',
  'كانون الأول',
];

/// "الاثنين" for a [DateTime] (kWeekdayNames is Monday-first, like the backend).
String weekdayNameOf(DateTime d) => kWeekdayNames[d.weekday - 1];

/// "الاثنين 2 تشرين الثاني 2026"
String formatLongDate(DateTime d) =>
    '${weekdayNameOf(d)} ${d.day} ${kMonthNames[d.month - 1]} ${d.year}';

/// "09:05"
String formatHm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// "09:00" from the backend's "09:00:00".
String hmOf(String hhmmss) => hhmmss.length >= 5 ? hhmmss.substring(0, 5) : hhmmss;

/// "2026-11-02", the format the backend expects for a date parameter.
String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
