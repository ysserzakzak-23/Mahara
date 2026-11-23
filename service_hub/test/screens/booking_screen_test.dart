import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/auth/data/auth_service.dart';
import 'package:service_hub/features/booking/booking_screen.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

const _customerUser = {
  'id': 1, 'email': 'a@b.com', 'role': 'user', 'is_provider': false, 'is_active': true,
};
const _providerUser = {
  'id': 2, 'email': 'p@b.com', 'role': 'user', 'is_provider': true, 'is_active': true,
};

RoutedBackend _backend({
  Map<String, dynamic> user = _customerUser,
  List<Map<String, dynamic>>? appointments,
  Map<String, Reply> extra = const {},
}) =>
    RoutedBackend({
      'GET /users/me': Reply(user),
      'GET /appointments/me': Reply(appointments ?? [appointmentJson()]),
      ...extra,
    });

Widget _app(RoutedBackend backend) {
  final store = TokenStore();
  final api = apiFor(backend, tokenStore: store);
  return MaterialApp(
    home: BookingScreen(
      authService: AuthService(apiClient: api, tokenStore: store),
      appointmentService: AppointmentService(apiClient: api),
    ),
  );
}

Future<void> _open(WidgetTester tester, RoutedBackend backend) async {
  useTallScreen(tester);
  await tester.pumpWidget(_app(backend));
  await tester.pumpAndSettle();
}

Future<void> _openScheduleTab(WidgetTester tester) async {
  await tester.tap(find.text('جدول مواعيدي'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('customer view', () {
    testWidgets('shows a spinner while the account is being checked', (tester) async {
      final backend = _backend()..gate = Completer<void>();
      useTallScreen(tester);
      await tester.pumpWidget(_app(backend));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      backend.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('حجوزاتي'), findsOneWidget);
    });

    testWidgets('lists my bookings without tabs, asking for the customer view',
        (tester) async {
      final backend = _backend();
      await _open(tester, backend);

      expect(find.byType(TabBar), findsNothing);
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('2026-10-05 10:00'), findsOneWidget);
      expect(backend.requests.last.url.queryParameters['as_provider'], 'false');
    });

    testWidgets('statuses are shown with Arabic labels',
        (tester) async {
      await _open(tester, _backend(appointments: [
        appointmentJson(id: 1, status: 'pending'),
        appointmentJson(id: 2, status: 'confirmed'),
        appointmentJson(id: 3, status: 'cancelled'),
      ]));

      expect(find.text('بانتظار الموافقة'), findsOneWidget);
      expect(find.text('مؤكد'), findsOneWidget);
      expect(find.text('ملغى'), findsOneWidget);
    });

    testWidgets('customers get no accept/reject controls', (tester) async {
      await _open(tester, _backend());

      expect(find.byTooltip('قبول'), findsNothing);
      expect(find.byTooltip('رفض'), findsNothing);
    });

    testWidgets('empty list message', (tester) async {
      await _open(tester, _backend(appointments: []));
      expect(find.text('ليس لديك حجوزات بعد.'), findsOneWidget);
    });

    testWidgets('a failed list request shows the error', (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /appointments/me': const Reply({'detail': 'boom'}, status: 500),
        }),
      );
      expect(find.text('boom'), findsOneWidget);
    });

    testWidgets('if the account check fails it falls back to the customer view',
        (tester) async {
      await _open(
        tester,
        _backend(extra: {
          'GET /users/me': const Reply({'detail': 'expired'}, status: 401),
        }),
      );
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('حجوزاتي'), findsOneWidget);
      expect(find.text('Fix pipes'), findsOneWidget);
    });
  });

  group('provider view', () {
    testWidgets('providers get two tabs', (tester) async {
      await _open(tester, _backend(user: _providerUser));

      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('حجوزاتي'), findsOneWidget);
      expect(find.text('جدول مواعيدي'), findsOneWidget);
    });

    testWidgets('the schedule tab asks for the provider view and names the customer',
        (tester) async {
      final backend = _backend(user: _providerUser);
      await _open(tester, backend);
      await _openScheduleTab(tester);

      expect(backend.requests.last.url.queryParameters['as_provider'], 'true');
      expect(find.textContaining('· Customer'), findsOneWidget);
    });

    testWidgets('empty schedule message', (tester) async {
      await _open(tester, _backend(user: _providerUser, appointments: []));
      await _openScheduleTab(tester);
      expect(find.text('لم يحجزك أحد حتى الآن.'), findsOneWidget);
    });

    testWidgets('accepting a pending request confirms it and reloads', (tester) async {
      final backend = _backend(user: _providerUser, extra: {
        'POST /appointments/5/accept': Reply(appointmentJson(status: 'confirmed')),
      });
      await _open(tester, backend);
      await _openScheduleTab(tester);
      final before = backend.callsTo('GET /appointments/me');

      await tester.tap(find.byTooltip('قبول'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/accept'), 1);
      expect(backend.callsTo('GET /appointments/me'), greaterThan(before));
    });

    testWidgets('rejecting asks for confirmation first', (tester) async {
      final backend = _backend(user: _providerUser, extra: {
        'POST /appointments/5/reject': Reply(appointmentJson(status: 'rejected')),
      });
      await _open(tester, backend);
      await _openScheduleTab(tester);

      await tester.tap(find.byTooltip('رفض'));
      await tester.pumpAndSettle();
      expect(find.text('رفض طلب الحجز هذا؟'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'رجوع'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/reject'), 0);

      await tester.tap(find.byTooltip('رفض'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'رفض'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/reject'), 1);
    });

    testWidgets('a confirmed booking can be marked completed', (tester) async {
      final backend = _backend(
        user: _providerUser,
        appointments: [appointmentJson(status: 'confirmed')],
        extra: {
          'POST /appointments/5/complete': Reply(appointmentJson(status: 'completed')),
        },
      );
      await _open(tester, backend);
      await _openScheduleTab(tester);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تحديد كمكتمل'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/complete'), 1);
    });

    testWidgets('cancelling a confirmed booking asks for confirmation', (tester) async {
      final backend = _backend(
        user: _providerUser,
        appointments: [appointmentJson(status: 'confirmed')],
        extra: {
          'POST /appointments/5/cancel': Reply(appointmentJson(status: 'cancelled')),
        },
      );
      await _open(tester, backend);
      await _openScheduleTab(tester);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('إلغاء الموعد'));
      await tester.pumpAndSettle();
      expect(find.text('إلغاء هذا الموعد؟'), findsOneWidget);
      expect(backend.callsTo('POST /appointments/5/cancel'), 0);

      await tester.tap(find.widgetWithText(TextButton, 'إلغاء الموعد'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/cancel'), 1);
    });

    testWidgets('a rejected action shows the backend message', (tester) async {
      final backend = _backend(user: _providerUser, extra: {
        'POST /appointments/5/accept': const Reply(
          {'detail': 'Only pending appointments can be accepted'},
          status: 409,
        ),
      });
      await _open(tester, backend);
      await _openScheduleTab(tester);

      await tester.tap(find.byTooltip('قبول'));
      await pumpFrames(tester);

      expect(find.text('Only pending appointments can be accepted'), findsOneWidget);
    });
  });

  group('opening a booking', () {
    // (no avatars: NetworkImage cannot download inside flutter test)
    Map<String, dynamic> appt({String status = 'pending'}) => {
          ...appointmentJson(status: status),
          'customer': withoutAvatar(providerJson(id: 1, name: 'Customer')),
          'provider': withoutAvatar(providerJson(id: 2, name: 'Provider')),
        };

    testWidgets('customer: tapping a booking opens its details with the provider',
        (tester) async {
      await _open(tester, _backend(appointments: [appt()]));

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الموعد'), findsOneWidget);
      expect(find.text('Provider'), findsOneWidget);
      expect(find.text('صاحب الخدمة · عرض الملف الشخصي'), findsOneWidget);
    });

    testWidgets('provider schedule: the details name the customer and offer accept/reject',
        (tester) async {
      await _open(tester, _backend(user: _providerUser, appointments: [appt()]));
      await _openScheduleTab(tester);

      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الموعد'), findsOneWidget);
      expect(find.text('Customer'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'قبول'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'رفض'), findsOneWidget);
    });

    testWidgets('accepting inside the details reloads the list when you come back',
        (tester) async {
      final backend = _backend(user: _providerUser, appointments: [appt()], extra: {
        'POST /appointments/5/accept': Reply(appt(status: 'confirmed')),
      });
      await _open(tester, backend);
      await _openScheduleTab(tester);
      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();
      final before = backend.callsTo('GET /appointments/me');

      await tester.tap(find.widgetWithText(OutlinedButton, 'قبول'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/accept'), 1);
      expect(backend.callsTo('GET /appointments/me'), before); // not yet: still on the details

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(find.text('تفاصيل الموعد'), findsNothing);
      expect(backend.callsTo('GET /appointments/me'), greaterThan(before));
    });

    testWidgets('coming back without changes does not reload', (tester) async {
      final backend = _backend(appointments: [appt()]);
      await _open(tester, backend);
      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();
      final before = backend.callsTo('GET /appointments/me');

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(backend.callsTo('GET /appointments/me'), before);
    });

    testWidgets('a request without a day/hour is listed as "بدون موعد محدد"', (tester) async {
      await _open(tester, _backend(appointments: [
        {...appt(), 'start_time': null, 'end_time': null},
      ]));

      expect(find.textContaining('بدون موعد محدد'), findsOneWidget);
      await tester.tap(find.text('Fix pipes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('لم يُحدد يوم أو ساعة'), findsOneWidget);
    });

    testWidgets('the card buttons still work without opening the details',
        (tester) async {
      final backend = _backend(user: _providerUser, appointments: [appt()], extra: {
        'POST /appointments/5/accept': Reply(appt(status: 'confirmed')),
      });
      await _open(tester, backend);
      await _openScheduleTab(tester);

      await tester.tap(find.byTooltip('قبول'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/accept'), 1);
      expect(find.text('تفاصيل الموعد'), findsNothing);
    });
  });
}
