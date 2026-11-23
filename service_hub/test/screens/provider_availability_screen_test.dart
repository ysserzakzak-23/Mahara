import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/features/availability/provider_availability_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _window(int id, int day, {String start = '09:00:00', String end = '17:00:00', bool active = true}) => {
      'id': id,
      'day_of_week': day,
      'start_time': start,
      'end_time': end,
      'is_active': active,
    };

RoutedBackend _backend({List<Map<String, dynamic>>? windows, Map<String, Reply> extra = const {}}) =>
    RoutedBackend({
      'GET /providers/2/availability': Reply(windows ?? []),
      ...extra,
    });

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(MaterialApp(
    home: ProviderAvailabilityScreen(
      providerId: 2,
      service: AvailabilityService(apiClient: apiFor(backend)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  testWidgets('shows an explanation when no hours are set', (tester) async {
    await _open(tester, _backend());
    expect(find.textContaining("لم تحدد ساعات عمل بعد"), findsOneWidget);
  });

  testWidgets('lists windows sorted by weekday and hides deactivated ones', (tester) async {
    await _open(
      tester,
      _backend(windows: [
        _window(3, 4, start: '10:00:00', end: '14:30:00'),
        _window(1, 0),
        _window(2, 2, active: false),
      ]),
    );

    expect(find.text('الاثنين'), findsOneWidget);
    expect(find.text('09:00 - 17:00'), findsOneWidget);
    expect(find.text('الجمعة'), findsOneWidget);
    expect(find.text('10:00 - 14:30'), findsOneWidget);
    expect(find.text('الأربعاء'), findsNothing); // deactivated

    expect(tester.getTopLeft(find.text('الاثنين')).dy,
        lessThan(tester.getTopLeft(find.text('الجمعة')).dy));
  });

  testWidgets('shows the error when loading fails', (tester) async {
    await _open(
      tester,
      _backend(extra: {
        'GET /providers/2/availability': const Reply({'detail': 'boom'}, status: 500),
      }),
    );
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('removing a window deactivates it and reloads', (tester) async {
    final backend = _backend(windows: [_window(9, 0)], extra: {
      'DELETE /providers/2/availability/9': const Reply(null, status: 204),
    });
    await _open(tester, backend);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(backend.callsTo('DELETE /providers/2/availability/9'), 1);
    expect(backend.callsTo('GET /providers/2/availability'), 2);
  });

  group('adding a window', () {
    testWidgets('the dialog starts at Monday 09:00 - 17:00', (tester) async {
      await _open(tester, _backend());

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('إضافة فترة توفر'), findsOneWidget);
      expect(find.text('البداية: 09:00'), findsOneWidget);
      expect(find.text('النهاية: 17:00'), findsOneWidget);
    });

    testWidgets('Add sends the defaults and reloads', (tester) async {
      final backend = _backend(extra: {
        'POST /providers/2/availability': Reply(_window(1, 0), status: 201),
      });
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'إضافة'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('POST /providers/2/availability'),
          {'day_of_week': 0, 'start_time': '09:00:00', 'end_time': '17:00:00'});
      expect(backend.callsTo('GET /providers/2/availability'), 2);
    });

    testWidgets('the chosen weekday is sent', (tester) async {
      final backend = _backend(extra: {
        'POST /providers/2/availability': Reply(_window(1, 2), status: 201),
      });
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('الأربعاء').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'إضافة'));
      await tester.pumpAndSettle();

      expect(backend.lastBodyOf('POST /providers/2/availability')['day_of_week'], 2);
    });

    testWidgets('Cancel sends nothing', (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'إلغاء'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /providers/2/availability'), 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('backend validation errors are shown', (tester) async {
      final backend = _backend(extra: {
        'POST /providers/2/availability': const Reply(
          {'detail': 'end_time must be after start_time'},
          status: 422,
        ),
      });
      await _open(tester, backend);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ElevatedButton, 'إضافة'));
      await pumpFrames(tester);

      expect(find.text('end_time must be after start_time'), findsOneWidget);
    });
  });
}
