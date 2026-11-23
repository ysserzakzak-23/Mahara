import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/booking/appointment_details_screen.dart';
import 'package:service_hub/features/booking/data/appointment_models.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';
import '../helpers/screen_helpers.dart';

/// 2026-10-05 is a Monday; the fixture books it 10:00-11:00.
Map<String, dynamic> _json({
  String status = 'pending',
  String? notes = 'note',
  String? reason,
}) =>
    {
      ...appointmentJson(status: status),
      'customer_notes': notes,
      'cancellation_reason': reason,
      'customer': withoutAvatar(providerJson(id: 1, name: 'Customer')),
      'provider': withoutAvatar(providerJson(id: 2, name: 'Provider')),
    };

class _Harness {
  final List<bool?> results = [];
  final List<(int, String)> openedProfiles = [];
}

Future<_Harness> _open(
  WidgetTester tester,
  RoutedBackend backend, {
  required bool asProvider,
  Map<String, dynamic>? json,
}) async {
  useTallScreen(tester);
  final harness = _Harness();
  final api = apiFor(backend);
  final appointment = Appointment.fromJson(json ?? _json());
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final result = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => AppointmentDetailsScreen(
                    appointment: appointment,
                    asProvider: asProvider,
                    appointmentService: AppointmentService(apiClient: api),
                    profileBuilder: (id, title) {
                      harness.openedProfiles.add((id, title));
                      return Scaffold(body: Text('PROFILE $id'));
                    },
                  ),
                ),
              );
              harness.results.add(result);
            },
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
  return harness;
}

Finder _outlined(String label) => find.widgetWithText(OutlinedButton, label);
Finder _inDialog(String label) => find.widgetWithText(TextButton, label);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('what is shown', () {
    testWidgets('the booking in full: service, day, date, hours, status', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: false);

      expect(find.text('تفاصيل الموعد'), findsOneWidget);
      expect(find.text('Fix pipes'), findsOneWidget);
      expect(find.text('الاثنين 5 تشرين الأول 2026'), findsOneWidget);
      expect(find.text('من 10:00 إلى 11:00'), findsOneWidget);
      expect(find.text('بانتظار الموافقة'), findsOneWidget);
    });

    testWidgets('provider side: the other party is the customer', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: true);

      expect(find.text('Customer'), findsOneWidget);
      expect(find.text('Provider'), findsNothing);
      expect(find.text('العميل · عرض الملف الشخصي'), findsOneWidget);
      expect(find.text('ملاحظات العميل'), findsOneWidget);
      expect(find.text('note'), findsOneWidget);
    });

    testWidgets('customer side: the other party is the service provider',
        (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: false);

      expect(find.text('Provider'), findsOneWidget);
      expect(find.text('Customer'), findsNothing);
      expect(find.text('صاحب الخدمة · عرض الملف الشخصي'), findsOneWidget);
      expect(find.text('ملاحظاتك'), findsOneWidget);
    });

    testWidgets('no notes says so', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: true, json: _json(notes: null));
      expect(find.text('لا توجد ملاحظات.'), findsOneWidget);
    });

    testWidgets('blank notes count as no notes', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: true, json: _json(notes: '   '));
      expect(find.text('لا توجد ملاحظات.'), findsOneWidget);
    });

    testWidgets('a request without a day/hour says the two sides will agree on it',
        (tester) async {
      await _open(
        tester, RoutedBackend({}),
        asProvider: true,
        json: {..._json(), 'start_time': null, 'end_time': null},
      );

      expect(find.text('الموعد'), findsOneWidget);
      expect(find.textContaining('لم يُحدد يوم أو ساعة'), findsOneWidget);
      expect(find.text('اليوم والتاريخ'), findsNothing);
      expect(find.text('الوقت'), findsNothing);
      // everything else is still there, and it can still be accepted
      expect(find.text('Customer'), findsOneWidget);
      expect(find.text('note'), findsOneWidget);
      expect(_outlined('قبول'), findsOneWidget);
    });

    testWidgets('a cancellation reason is shown', (tester) async {
      await _open(
        tester, RoutedBackend({}),
        asProvider: true,
        json: _json(status: 'cancelled', reason: 'مريض'),
      );

      expect(find.text('ملغى'), findsOneWidget);
      expect(find.text('سبب الإلغاء'), findsOneWidget);
      expect(find.text('مريض'), findsOneWidget);
    });
  });

  group('the other party', () {
    testWidgets('provider side: tapping the name opens the customer profile',
        (tester) async {
      final harness = await _open(tester, RoutedBackend({}), asProvider: true);

      await tester.tap(find.byKey(const Key('open-profile')));
      await tester.pumpAndSettle();

      expect(harness.openedProfiles, [(1, 'ملف العميل')]);
      expect(find.text('PROFILE 1'), findsOneWidget);
    });

    testWidgets('customer side: tapping the name opens the provider profile',
        (tester) async {
      final harness = await _open(tester, RoutedBackend({}), asProvider: false);

      await tester.tap(find.text('Provider'));
      await tester.pumpAndSettle();

      expect(harness.openedProfiles, [(2, 'ملف المزوّد')]);
    });
  });

  group('which actions are offered', () {
    testWidgets('provider + pending: accept and reject', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: true);

      expect(_outlined('قبول'), findsOneWidget);
      expect(_outlined('رفض'), findsOneWidget);
      expect(_outlined('إلغاء الموعد'), findsNothing);
      expect(_outlined('تحديد كمكتمل'), findsNothing);
    });

    testWidgets('provider + confirmed: complete and cancel', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: true, json: _json(status: 'confirmed'));

      expect(_outlined('تحديد كمكتمل'), findsOneWidget);
      expect(_outlined('إلغاء الموعد'), findsOneWidget);
      expect(_outlined('قبول'), findsNothing);
      expect(_outlined('رفض'), findsNothing);
    });

    testWidgets('customer + pending: only cancel, with a waiting note', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: false);

      expect(_outlined('إلغاء الموعد'), findsOneWidget);
      expect(_outlined('قبول'), findsNothing);
      expect(_outlined('رفض'), findsNothing);
      expect(find.text('بانتظار موافقة صاحب الخدمة على طلبك.'), findsOneWidget);
    });

    testWidgets('customer + confirmed: only cancel', (tester) async {
      await _open(tester, RoutedBackend({}), asProvider: false, json: _json(status: 'confirmed'));

      expect(_outlined('إلغاء الموعد'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.text('بانتظار موافقة صاحب الخدمة على طلبك.'), findsNothing);
    });

    for (final status in ['completed', 'cancelled', 'rejected']) {
      for (final asProvider in [true, false]) {
        testWidgets('$status ($asProvider): nothing left to do', (tester) async {
          await _open(tester, RoutedBackend({}), asProvider: asProvider, json: _json(status: status));
          expect(find.byType(OutlinedButton), findsNothing);
        });
      }
    }
  });

  group('actions', () {
    testWidgets('accepting confirms the booking right on the page', (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/accept': Reply(_json(status: 'confirmed')),
      });
      await _open(tester, backend, asProvider: true);

      await tester.tap(_outlined('قبول'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/accept'), 1);
      expect(find.text('تم قبول الحجز.'), findsOneWidget);
      expect(find.text('مؤكد'), findsOneWidget);
      expect(_outlined('تحديد كمكتمل'), findsOneWidget); // new actions for the new status
      expect(_outlined('قبول'), findsNothing);
    });

    testWidgets('rejecting asks first; "رجوع" does nothing', (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/reject': Reply(_json(status: 'rejected')),
      });
      await _open(tester, backend, asProvider: true);

      await tester.tap(_outlined('رفض'));
      await tester.pumpAndSettle();
      expect(find.text('رفض طلب الحجز هذا؟'), findsOneWidget);
      await tester.tap(_inDialog('رجوع'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/reject'), 0);

      await tester.tap(_outlined('رفض'));
      await tester.pumpAndSettle();
      await tester.tap(_inDialog('رفض'));
      await tester.pumpAndSettle();
      expect(backend.callsTo('POST /appointments/5/reject'), 1);
      expect(find.text('مرفوض'), findsOneWidget);
      expect(find.text('تم رفض الحجز.'), findsOneWidget);
    });

    testWidgets('a customer can cancel after confirming', (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/cancel': Reply(_json(status: 'cancelled')),
      });
      await _open(tester, backend, asProvider: false, json: _json(status: 'confirmed'));

      await tester.tap(_outlined('إلغاء الموعد'));
      await tester.pumpAndSettle();
      expect(find.text('إلغاء هذا الموعد؟'), findsOneWidget);
      await tester.tap(_inDialog('إلغاء الموعد'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/cancel'), 1);
      expect(find.text('ملغى'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('a provider can mark a confirmed booking completed', (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/complete': Reply(_json(status: 'completed')),
      });
      await _open(tester, backend, asProvider: true, json: _json(status: 'confirmed'));

      await tester.tap(_outlined('تحديد كمكتمل'));
      await tester.pumpAndSettle();

      expect(backend.callsTo('POST /appointments/5/complete'), 1);
      expect(find.text('مكتمل'), findsOneWidget);
      expect(find.text('تم تحديد الموعد كمكتمل.'), findsOneWidget);
    });

    testWidgets('a refused action shows the backend message and changes nothing',
        (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/accept':
            const Reply({'detail': 'يمكن قبول الموعد المعلّق فقط'}, status: 409),
      });
      final harness = await _open(tester, backend, asProvider: true);

      await tester.tap(_outlined('قبول'));
      await tester.pumpAndSettle();

      expect(find.text('يمكن قبول الموعد المعلّق فقط'), findsOneWidget);
      expect(find.text('بانتظار الموافقة'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(harness.results, [false]);
    });
  });

  group('going back', () {
    testWidgets('without changes the list is told nothing happened', (tester) async {
      final harness = await _open(tester, RoutedBackend({}), asProvider: true);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(harness.results, [false]);
      expect(find.byType(AppointmentDetailsScreen), findsNothing);
    });

    testWidgets('after a change the list is told to reload', (tester) async {
      final backend = RoutedBackend({
        'POST /appointments/5/accept': Reply(_json(status: 'confirmed')),
      });
      final harness = await _open(tester, backend, asProvider: true);

      await tester.tap(_outlined('قبول'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();

      expect(harness.results, [true]);
    });
  });
}
