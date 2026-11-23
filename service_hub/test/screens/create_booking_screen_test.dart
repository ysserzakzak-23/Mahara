import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/theme/app_colors.dart';
import 'package:service_hub/core/theme/app_theme.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/features/booking/create_booking_screen.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

/// "Now" for these tests: Monday 2 November 2026, 08:00. The date picker
/// opens on the first bookable day from today, i.e. today for a provider who
/// works on Mondays (or who set no working hours at all).
final _monday8am = DateTime(2026, 11, 2, 8, 0);
final _tuesday8am = DateTime(2026, 11, 3, 8, 0);

Map<String, dynamic> _window(
  int day, {
  String start = '09:00:00',
  String end = '12:00:00',
  bool active = true,
}) =>
    {
      'id': day + 1,
      'day_of_week': day,
      'start_time': start,
      'end_time': end,
      'is_active': active,
    };

Map<String, dynamic> _slot(String start, String end, {bool booked = false}) =>
    {'start_time': start, 'end_time': end, 'is_booked': booked};

/// 09-10 free, 10-11 booked by somebody else, 11-12 free.
List<Map<String, dynamic>> get _usualSlots => [
      _slot('09:00:00', '10:00:00'),
      _slot('10:00:00', '11:00:00', booked: true),
      _slot('11:00:00', '12:00:00'),
    ];

Reply _day(List<Map<String, dynamic>> slots) =>
    Reply({'day': '2026-11-02', 'day_of_week': 0, 'slots': slots});

RoutedBackend _backend({
  List<Map<String, dynamic>>? windows,
  List<Map<String, dynamic>>? slots,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /providers/2/availability': Reply(windows ?? [_window(0)]),
      'GET /providers/2/availability/slots': _day(slots ?? _usualSlots),
      'POST /appointments': Reply(appointmentJson(), status: 201),
      ...extra,
    });

Map<String, String> _lastSlotsQuery(RoutedBackend b) => b.requests
    .where((r) => r.method == 'GET' && r.url.path.endsWith('/availability/slots'))
    .last
    .url
    .queryParameters;

Future<void> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  DateTime? now,
  bool remote = false,
  // When set, the app's real light/dark themes are used in that mode.
  ThemeMode? themeMode,
}) async {
  useTallScreen(tester);
  final api = apiFor(backend);
  final clock = now ?? _monday8am;
  await tester.pumpWidget(MaterialApp(
    theme: themeMode == null ? null : appTheme,
    darkTheme: themeMode == null ? null : darkAppTheme,
    themeMode: themeMode ?? ThemeMode.system,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CreateBookingScreen(
                  serviceId: 100,
                  serviceTitle: 'Fix pipes',
                  providerId: 2,
                  isRemote: remote,
                  appointmentService: AppointmentService(apiClient: api),
                  availabilityService: AvailabilityService(apiClient: api),
                  clock: () => clock,
                ),
              ),
            ),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

Future<void> _pickDate(WidgetTester tester) async {
  await tester.tap(find.text('اختر تاريخ الموعد'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('OK')); // accepts the proposed day
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('اضغط لاختيار الوقت'));
  await tester.pumpAndSettle();
}

Future<void> _tapSlotInSheet(WidgetTester tester, String start) async {
  final chip = find.byKey(Key('slot-$start'));
  // the hours sit in a horizontal scroller: bring this one into view first
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Finder get _chooseButton => find.widgetWithText(ElevatedButton, 'اختيار هذا الوقت');

/// Opens the hours sheet, taps one hour and confirms the choice.
Future<void> _chooseSlot(WidgetTester tester, String start) async {
  await _openSheet(tester);
  await _tapSlotInSheet(tester, start);
  await tester.tap(_chooseButton);
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.text('تأكيد الحجز'));
  await pumpFrames(tester);
}

bool _chipSelected(WidgetTester tester, String start) =>
    tester.widget<ChoiceChip>(find.byKey(Key('slot-$start'))).selected;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('working days', () {
    testWidgets('a collapsed "أيام الدوام" card says how many days, then lists them with hours',
        (tester) async {
      await _open(tester, _backend(windows: [_window(2, start: '14:00:00', end: '16:00:00'), _window(0)]));

      expect(find.text('حجز موعد'), findsOneWidget);
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('أيام الدوام'), findsOneWidget);
      expect(find.text('2 أيام عمل'), findsOneWidget);
      expect(find.text('اختر تاريخ الموعد'), findsOneWidget);
      expect(find.text('الاثنين'), findsNothing); // collapsed

      await tester.tap(find.text('أيام الدوام'));
      await tester.pumpAndSettle();

      expect(find.text('الاثنين'), findsOneWidget);
      expect(find.text('من 09:00 إلى 12:00'), findsOneWidget);
      expect(find.text('الأربعاء'), findsOneWidget);
      expect(find.text('من 14:00 إلى 16:00'), findsOneWidget);
      expect(find.text('الثلاثاء'), findsNothing); // day off
    });

    testWidgets('days are listed Sunday first', (tester) async {
      await _open(tester, _backend(windows: [_window(0), _window(6), _window(3)]));
      await tester.tap(find.text('أيام الدوام'));
      await tester.pumpAndSettle();

      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('الأحد'), lessThan(y('الاثنين')));
      expect(y('الاثنين'), lessThan(y('الخميس')));
    });

    testWidgets('several windows on one day are joined', (tester) async {
      await _open(tester, _backend(windows: [_window(0), _window(0, start: '14:00:00', end: '16:00:00')]));
      await tester.tap(find.text('أيام الدوام'));
      await tester.pumpAndSettle();

      expect(find.text('من 09:00 إلى 12:00 و من 14:00 إلى 16:00'), findsOneWidget);
    });

    testWidgets('a failure to load the hours is shown', (tester) async {
      await _open(tester, _backend(extra: {
        'GET /providers/2/availability': const Reply({'detail': 'down'}, status: 500),
      }));

      expect(find.textContaining('تعذّر تحميل ساعات المزوّد'), findsOneWidget);
    });

    testWidgets('the date picker only offers working days', (tester) async {
      // Tuesday morning, provider works Mondays: the picker proposes next Monday.
      final backend = _backend();
      await _open(tester, backend, now: _tuesday8am);
      await _pickDate(tester);

      expect(find.text('الاثنين 9 تشرين الثاني 2026'), findsOneWidget);
      expect(_lastSlotsQuery(backend), {'day': '2026-11-09'});
    });
  });

  group('provider without working hours', () {
    testWidgets('an on-site service cannot be booked', (tester) async {
      final backend = _backend(windows: const []);
      await _open(tester, backend);

      expect(find.text('لم يحدد المزوّد أيام دوام بعد، لا يمكن الحجز حالياً.'), findsOneWidget);
      expect(find.text('اختر تاريخ الموعد'), findsNothing);
      expect(find.byKey(const Key('no-time-note')), findsNothing);
    });

    testWidgets('switched-off windows count as no working hours', (tester) async {
      await _open(tester, _backend(windows: [_window(0, active: false)]), remote: true);

      expect(find.byKey(const Key('no-time-note')), findsOneWidget);
    });

    testWidgets('a remote service explains that no day or hour is needed', (tester) async {
      await _open(tester, _backend(windows: const []), remote: true);

      expect(find.byKey(const Key('no-time-note')), findsOneWidget);
      expect(find.textContaining('هذه الخدمة عن بعد ولم يحدد المزوّد أوقات دوام'), findsOneWidget);
      expect(find.text('أيام الدوام'), findsNothing);
      expect(find.text('اختر تاريخ الموعد'), findsNothing);
      expect(find.text('اضغط لاختيار الوقت'), findsNothing);
    });

    testWidgets('the request is sent with the notes and no day or hour', (tester) async {
      final backend = _backend(windows: const []);
      await _open(tester, backend, remote: true);
      await tester.enterText(find.byType(TextField), '  أحتاج مساعدة بالتصميم  ');

      await _confirm(tester);

      expect(backend.lastBodyOf('POST /appointments'), {
        'service_id': 100,
        'customer_notes': 'أحتاج مساعدة بالتصميم',
      });
      expect(find.text('تم إرسال طلب الحجز! سيتواصل معك المزوّد للاتفاق على الموعد.'), findsOneWidget);
      expect(find.byType(CreateBookingScreen), findsNothing);
    });

    testWidgets('it can be sent without any notes', (tester) async {
      final backend = _backend(windows: const []);
      await _open(tester, backend, remote: true);

      await _confirm(tester);

      expect(backend.lastBodyOf('POST /appointments'), {'service_id': 100});
    });

    testWidgets('no hours are loaded for the slots of a request without time', (tester) async {
      final backend = _backend(windows: const []);
      await _open(tester, backend, remote: true);
      await _confirm(tester);

      expect(backend.callsTo('GET /providers/2/availability/slots'), 0);
    });

    testWidgets('a refusal from the server is shown and the form stays', (tester) async {
      final backend = _backend(windows: const [], extra: {
        'POST /appointments': const Reply({'detail': 'خطأ بالسيرفر'}, status: 500),
      });
      await _open(tester, backend, remote: true);

      await _confirm(tester);

      expect(find.text('خطأ بالسيرفر'), findsOneWidget);
      expect(find.byType(CreateBookingScreen), findsOneWidget);
    });

    testWidgets('a remote service whose provider DID set hours is booked on a day and hour',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend, remote: true);

      expect(find.byKey(const Key('no-time-note')), findsNothing);
      expect(find.text('اختر تاريخ الموعد'), findsOneWidget);

      await _confirm(tester);
      expect(find.text('يرجى اختيار اليوم والساعة.'), findsOneWidget);
      expect(backend.callsTo('POST /appointments'), 0);
    });
  });

  group('hours of the chosen day', () {
    testWidgets('picking a date asks for that day and shows the card of available times',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _pickDate(tester);

      expect(_lastSlotsQuery(backend), {'day': '2026-11-02'});
      expect(find.text('الاثنين 2 تشرين الثاني 2026'), findsOneWidget);
      expect(find.text('الأوقات المتاحة'), findsOneWidget);
      expect(find.text('مدة الموعد ساعة واحدة'), findsOneWidget);
      expect(find.text('اضغط لاختيار الوقت'), findsOneWidget);
    });

    testWidgets('the sheet lists free hours and greys out booked ones', (tester) async {
      await _open(tester, _backend());
      await _pickDate(tester);
      await _openSheet(tester);

      expect(find.text('اختر الوقت المناسب'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(2)); // 09-10 and 11-12
      expect(find.text('09:00 - 10:00'), findsOneWidget);
      expect(find.text('11:00 - 12:00'), findsOneWidget);
      expect(find.text('10:00 - 11:00 · محجوز'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('slot-10:00')), matching: find.byType(ChoiceChip)), findsNothing);
    });

    testWidgets('"اختيار هذا الوقت" is disabled until an hour is tapped; tapping another moves the choice',
        (tester) async {
      await _open(tester, _backend());
      await _pickDate(tester);
      await _openSheet(tester);

      expect(tester.widget<ElevatedButton>(_chooseButton).onPressed, isNull);
      await _tapSlotInSheet(tester, '09:00');
      expect(tester.widget<ElevatedButton>(_chooseButton).onPressed, isNotNull);
      expect(_chipSelected(tester, '09:00'), isTrue);

      await _tapSlotInSheet(tester, '11:00');
      expect(_chipSelected(tester, '09:00'), isFalse);
      expect(_chipSelected(tester, '11:00'), isTrue);
    });

    testWidgets('the chosen hour is shown on the card and stays ticked when reopened',
        (tester) async {
      await _open(tester, _backend());
      await _pickDate(tester);
      await _chooseSlot(tester, '11:00');

      expect(find.text('11:00 - 12:00'), findsOneWidget);
      expect(find.text('اضغط لاختيار الوقت'), findsNothing);

      await tester.tap(find.text('11:00 - 12:00'));
      await tester.pumpAndSettle();
      expect(_chipSelected(tester, '11:00'), isTrue);
    });

    testWidgets('hours that already started today are not offered', (tester) async {
      await _open(tester, _backend(), now: DateTime(2026, 11, 2, 10, 30));
      await _pickDate(tester);
      await _openSheet(tester);

      expect(find.byKey(const Key('slot-09:00')), findsNothing);
      expect(find.byKey(const Key('slot-10:00')), findsNothing);
      expect(find.byKey(const Key('slot-11:00')), findsOneWidget);
    });

    testWidgets('a day that is fully booked says so and the card does not open', (tester) async {
      await _open(tester, _backend(slots: [
        _slot('09:00:00', '10:00:00', booked: true),
        _slot('10:00:00', '11:00:00', booked: true),
      ]));
      await _pickDate(tester);

      expect(find.text('كل ساعات هذا اليوم محجوزة أو انتهت، جرّب يوماً آخر.'), findsOneWidget);
      await tester.tap(find.text('اضغط لاختيار الوقت'));
      await tester.pumpAndSettle();
      expect(find.text('اختر الوقت المناسب'), findsNothing);
    });

    testWidgets('a day the provider does not work says so', (tester) async {
      await _open(tester, _backend(slots: const []));
      await _pickDate(tester);

      expect(find.text('المزوّد لا يعمل في هذا اليوم، اختر يوماً آخر.'), findsOneWidget);
    });

    testWidgets('a failure to load the hours of the day is shown', (tester) async {
      await _open(tester, _backend(extra: {
        'GET /providers/2/availability/slots': const Reply({'detail': 'down'}, status: 500),
      }));
      await _pickDate(tester);

      expect(find.textContaining('تعذّر تحميل الساعات'), findsOneWidget);
    });
  });

  group('validation before calling the backend', () {
    testWidgets('requires a day and an hour', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await _confirm(tester);
      expect(find.text('يرجى اختيار اليوم والساعة.'), findsOneWidget);

      await _pickDate(tester); // hour still missing
      await _confirm(tester);
      expect(find.text('يرجى اختيار اليوم والساعة.'), findsWidgets);
      expect(backend.callsTo('POST /appointments'), 0);
    });

    testWidgets('a booked hour cannot be chosen', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _pickDate(tester);
      await _openSheet(tester);

      await _tapSlotInSheet(tester, '10:00'); // booked: nothing happens
      expect(tester.widget<ElevatedButton>(_chooseButton).onPressed, isNull);

      await tester.tapAt(const Offset(10, 10)); // close the sheet
      await tester.pumpAndSettle();
      await _confirm(tester);

      expect(find.text('يرجى اختيار اليوم والساعة.'), findsWidgets);
      expect(backend.callsTo('POST /appointments'), 0);
    });

    testWidgets('closing the sheet without choosing keeps the previous state', (tester) async {
      await _open(tester, _backend());
      await _pickDate(tester);
      await _openSheet(tester);
      await _tapSlotInSheet(tester, '09:00');

      await tester.tapAt(const Offset(10, 10)); // dismiss, not "اختيار هذا الوقت"
      await tester.pumpAndSettle();

      expect(find.text('اضغط لاختيار الوقت'), findsOneWidget);
    });
  });

  group('booking', () {
    testWidgets('sends the chosen hour as UTC with trimmed notes, then closes',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _pickDate(tester);
      await _chooseSlot(tester, '11:00');
      await tester.enterText(find.byType(TextField), '  bring tools  ');

      await _confirm(tester);

      final start = DateTime.utc(2026, 11, 2, 11);
      expect(backend.lastBodyOf('POST /appointments'), {
        'service_id': 100,
        'start_time': start.toIso8601String(),
        'end_time': start.add(const Duration(hours: 1)).toIso8601String(),
        'customer_notes': 'bring tools',
      });
      expect(find.text('تم إرسال طلب الحجز! سيقبله المزوّد أو يرفضه.'), findsOneWidget);
      expect(find.byType(CreateBookingScreen), findsNothing);
      expect(find.text('OPEN'), findsOneWidget);
    });

    testWidgets('empty notes are not sent', (tester) async {
      final backend = _backend();
      await _open(tester, backend);
      await _pickDate(tester);
      await _chooseSlot(tester, '09:00');

      await _confirm(tester);

      expect(backend.lastBodyOf('POST /appointments').containsKey('customer_notes'), isFalse);
    });

    testWidgets(
        'when somebody takes the hour first, the message is shown, the hours are '
        'reloaded and the choice is cleared', (tester) async {
      final backend = _backend(extra: {
        'POST /appointments': const Reply(
          {'detail': 'تم حجز هذا الوقت للتو من قبل شخص آخر'},
          status: 409,
        ),
      });
      await _open(tester, backend);
      await _pickDate(tester);
      await _chooseSlot(tester, '09:00');
      expect(backend.callsTo('GET /providers/2/availability/slots'), 1);

      await _confirm(tester);

      expect(find.text('تم حجز هذا الوقت للتو من قبل شخص آخر'), findsOneWidget);
      expect(find.byType(CreateBookingScreen), findsOneWidget);
      expect(backend.callsTo('GET /providers/2/availability/slots'), 2);
      expect(find.text('اضغط لاختيار الوقت'), findsOneWidget); // choice cleared
    });

    testWidgets('another kind of error keeps the form and the choice', (tester) async {
      final backend = _backend(extra: {
        'POST /appointments': const Reply({'detail': 'خطأ'}, status: 500),
      });
      await _open(tester, backend);
      await _pickDate(tester);
      await _chooseSlot(tester, '09:00');

      await _confirm(tester);

      expect(find.text('خطأ'), findsOneWidget);
      expect(backend.callsTo('GET /providers/2/availability/slots'), 1);
      expect(find.text('09:00 - 10:00'), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'تأكيد الحجز')).onPressed,
        isNotNull,
      );
    });
  });

  group('time button colours (light and dark mode)', () {
    final button = find.byKey(const Key('time-picker-button'));

    BoxDecoration decorationOf(WidgetTester tester) => tester
        .widget<Container>(find.descendant(of: button, matching: find.byType(Container)).first)
        .decoration! as BoxDecoration;

    Text labelOf(WidgetTester tester) => tester.widget<Text>(
        find.descendant(of: button, matching: find.text('اضغط لاختيار الوقت')));

    Icon clockOf(WidgetTester tester) => tester.widget<Icon>(
        find.descendant(of: button, matching: find.byIcon(Icons.access_time_rounded)));

    /// WCAG contrast ratio between two colours.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    testWidgets('light mode keeps the original look', (tester) async {
      await _open(tester, _backend(), themeMode: ThemeMode.light);
      await _pickDate(tester);

      expect(decorationOf(tester).color, const Color.fromARGB(255, 224, 219, 219));
      expect(decorationOf(tester).borderRadius, BorderRadius.circular(12));
      expect(clockOf(tester).color, appTheme.colorScheme.primary);
      expect(labelOf(tester).style!.color, isNull); // default text colour, as before
      expect(labelOf(tester).style!.fontWeight, FontWeight.w600);
    });

    testWidgets('dark mode: a dark field with clearly readable text and clock icon',
        (tester) async {
      await _open(tester, _backend(), themeMode: ThemeMode.dark);
      await _pickDate(tester);

      final background = decorationOf(tester).color!;
      expect(background, AppColors.darkField); // the dark theme's own field colour
      expect(background, isNot(const Color.fromARGB(255, 224, 219, 219)));

      final text = labelOf(tester).style!.color!;
      final icon = clockOf(tester).color!;
      expect(contrast(text, background), greaterThanOrEqualTo(4.5)); // WCAG AA text
      expect(contrast(icon, background), greaterThanOrEqualTo(3.0)); // WCAG AA graphics
      expect(labelOf(tester).style!.fontWeight, FontWeight.w600);
      // Same size and shape as in light mode.
      expect(decorationOf(tester).borderRadius, BorderRadius.circular(12));
    });

    testWidgets('dark and light mode give the button the same size', (tester) async {
      await _open(tester, _backend(), themeMode: ThemeMode.light);
      await _pickDate(tester);
      final lightSize = tester.getSize(button);

      await tester.pumpWidget(const SizedBox()); // start again from scratch
      await _open(tester, _backend(), themeMode: ThemeMode.dark);
      await _pickDate(tester);
      expect(tester.getSize(button), lightSize);
    });

    testWidgets('in dark mode the time picker still opens and the choice is shown',
        (tester) async {
      await _open(tester, _backend(), themeMode: ThemeMode.dark);
      await _pickDate(tester);

      await _openSheet(tester);
      expect(find.byKey(const Key('slot-09:00')), findsOneWidget);
      // An unselected hour is readable on the dark sheet too.
      final hour = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('slot-09:00')),
        matching: find.text('09:00 - 10:00'),
      ));
      expect(hour.style!.color, darkAppTheme.colorScheme.onSurface);

      await _tapSlotInSheet(tester, '09:00');
      await tester.tap(_chooseButton);
      await tester.pumpAndSettle();

      expect(find.descendant(of: button, matching: find.text('09:00 - 10:00')), findsOneWidget);
      final chosen = tester.widget<Text>(
          find.descendant(of: button, matching: find.text('09:00 - 10:00')));
      expect(contrast(chosen.style!.color!, decorationOf(tester).color!),
          greaterThanOrEqualTo(4.5));
    });

    testWidgets('in light mode an unselected hour keeps its original colour', (tester) async {
      await _open(tester, _backend(), themeMode: ThemeMode.light);
      await _pickDate(tester);
      await _openSheet(tester);

      final hour = tester.widget<Text>(find.descendant(
        of: find.byKey(const Key('slot-09:00')),
        matching: find.text('09:00 - 10:00'),
      ));
      expect(hour.style!.color, Colors.black87);
    });
  });
}
