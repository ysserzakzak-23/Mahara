import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/notifications/notifications_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

Map<String, dynamic> _n(
  int id, {
  String type = 'appointment_booked',
  String title = 'Title',
  String message = 'Message',
  bool read = false,
}) =>
    {
      'id': id,
      'type': type,
      'title': title,
      'message': message,
      'is_read': read,
      'created_at': '2026-10-05T10:00:00Z',
    };

Widget _app(RoutedBackend backend) => MaterialApp(
      home: NotificationsScreen(
        service: NotificationService(apiClient: apiFor(backend)),
      ),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  testWidgets('shows a spinner, then the notifications', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([_n(1, title: 'New booking', message: 'Ahmad booked you')]),
    });
    await tester.pumpWidget(_app(backend));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('New booking'), findsOneWidget);
    expect(find.text('Ahmad booked you'), findsOneWidget);
  });

  testWidgets('asks the backend for the full list (not only unread)', (tester) async {
    final backend = RoutedBackend({'GET /notifications': const Reply([])});
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(backend.requests.first.url.queryParameters['unread_only'], 'false');
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(_app(RoutedBackend({'GET /notifications': const Reply([])})));
    await tester.pumpAndSettle();

    expect(find.text('لا توجد إشعارات بعد.'), findsOneWidget);
  });

  testWidgets('shows the error when loading fails', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': const Reply({'detail': 'Invalid or expired token'}, status: 401),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(find.text('Invalid or expired token'), findsOneWidget);
  });

  testWidgets('unread items are bold, read items are normal', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([
        _n(1, title: 'Unread one'),
        _n(2, title: 'Read one', read: true),
      ]),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.text('Unread one')).style?.fontWeight, FontWeight.bold);
    expect(tester.widget<Text>(find.text('Read one')).style?.fontWeight, FontWeight.normal);
  });

  testWidgets('each type gets its own icon', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([
        _n(1, type: 'appointment_accepted', title: 'a'),
        _n(2, type: 'exchange_match_found', title: 'b'),
        _n(3, type: 'barter_match', title: 'c'),
        _n(4, type: 'new_review', title: 'd'),
        _n(5, type: 'system', title: 'e'),
      ]),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.event_note), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    expect(find.byIcon(Icons.handshake_outlined), findsOneWidget);
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(find.byIcon(Icons.notifications_none), findsOneWidget);
  });

  testWidgets('tapping an unread notification marks it read and reloads',
      (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([_n(7, title: 'Unread one')]),
      'POST /notifications/7/read': const Reply(null, status: 204),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    backend.routes['GET /notifications'] = Reply([_n(7, title: 'Unread one', read: true)]);
    await tester.tap(find.text('Unread one'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('POST /notifications/7/read'), 1);
    expect(backend.callsTo('GET /notifications'), 2);
    expect(tester.widget<Text>(find.text('Unread one')).style?.fontWeight, FontWeight.normal);
  });

  testWidgets('tapping an already-read notification does nothing', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([_n(7, title: 'Old one', read: true)]),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old one'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('POST /notifications/7/read'), 0);
    expect(backend.callsTo('GET /notifications'), 1);
  });

  testWidgets('"تحديد الكل كمقروء" calls the backend and reloads', (tester) async {
    final backend = RoutedBackend({
      'GET /notifications': Reply([_n(1), _n(2)]),
      'POST /notifications/read-all': const Reply(null, status: 204),
    });
    await tester.pumpWidget(_app(backend));
    await tester.pumpAndSettle();

    await tester.tap(find.text('تحديد الكل كمقروء'));
    await tester.pumpAndSettle();

    expect(backend.callsTo('POST /notifications/read-all'), 1);
    expect(backend.callsTo('GET /notifications'), 2);
  });
}
