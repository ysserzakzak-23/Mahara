import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/date_labels.dart';

void main() {
  test('weekdayNameOf follows the real calendar (Monday-first names)', () {
    expect(weekdayNameOf(DateTime(2026, 11, 2)), 'الاثنين');
    expect(weekdayNameOf(DateTime(2026, 11, 7)), 'السبت');
    expect(weekdayNameOf(DateTime(2026, 11, 8)), 'الأحد');
  });

  test('formatLongDate uses the Levantine month names', () {
    expect(formatLongDate(DateTime(2026, 11, 2)), 'الاثنين 2 تشرين الثاني 2026');
    expect(formatLongDate(DateTime(2027, 1, 1)), 'الجمعة 1 كانون الثاني 2027');
    expect(kMonthNames.length, 12);
  });

  test('formatHm pads minutes and hours', () {
    expect(formatHm(DateTime(2026, 1, 1, 9, 5)), '09:05');
    expect(formatHm(DateTime(2026, 1, 1, 17, 30)), '17:30');
  });

  test('hmOf trims the seconds of a backend time', () {
    expect(hmOf('09:00:00'), '09:00');
    expect(hmOf('09:00'), '09:00');
  });

  test('isoDate pads month and day', () {
    expect(isoDate(DateTime(2026, 3, 7)), '2026-03-07');
    expect(isoDate(DateTime(2026, 11, 22)), '2026-11-22');
  });
}
