import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/booking/data/appointment_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

AppointmentService serviceFor(FakeBackend backend) => AppointmentService(
      apiClient: ApiClient(httpClient: backend.client, tokenStore: TokenStore()),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('myAppointments', () {
    test('requests the customer view by default and parses the list', () async {
      final backend = FakeBackend([appointmentJson(id: 1), appointmentJson(id: 2)]);
      final list = await serviceFor(backend).myAppointments();

      expect(backend.last.url.path, endsWith('/appointments/me'));
      expect(backend.last.url.queryParameters['as_provider'], 'false');
      expect(list.items.map((a) => a.id), [1, 2]);
    });

    test('asProvider switches the query flag', () async {
      final backend = FakeBackend(<dynamic>[]);
      final list = await serviceFor(backend).myAppointments(asProvider: true);

      expect(backend.last.url.queryParameters['as_provider'], 'true');
      expect(list.items, isEmpty);
      expect(list.isEmpty, isTrue);
    });
  });

  group('createAppointment', () {
    final start = DateTime.utc(2026, 10, 5, 10);
    final end = DateTime.utc(2026, 10, 5, 11);

    test('sends service id and UTC ISO times', () async {
      final backend = FakeBackend(appointmentJson(), status: 201);
      final created = await serviceFor(backend).createAppointment(
        serviceId: 100, startTime: start, endTime: end, customerNotes: 'bring tools',
      );

      expect(backend.last.url.path, endsWith('/appointments'));
      expect(backend.lastJsonBody, {
        'service_id': 100,
        'start_time': '2026-10-05T10:00:00.000Z',
        'end_time': '2026-10-05T11:00:00.000Z',
        'customer_notes': 'bring tools',
      });
      expect(created.id, 5);
    });

    test('omits customer_notes when empty', () async {
      for (final notes in [null, '']) {
        final backend = FakeBackend(appointmentJson(), status: 201);
        await serviceFor(backend).createAppointment(
          serviceId: 100, startTime: start, endTime: end, customerNotes: notes,
        );
        expect(backend.lastJsonBody.containsKey('customer_notes'), isFalse);
      }
    });

    test('a conflict is surfaced with the backend message', () async {
      final backend = FakeBackend(
        {'detail': 'The requested time conflicts with 1 existing appointment(s) for this provider'},
        status: 409,
      );
      await expectLater(
        serviceFor(backend).createAppointment(serviceId: 1, startTime: start, endTime: end),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.message, 'message', contains('conflicts'))),
      );
    });
  });

  group('status actions', () {
    test('cancel posts the reason when given', () async {
      final backend = FakeBackend(appointmentJson(status: 'cancelled'));
      await serviceFor(backend).cancel(5, reason: 'busy');

      expect(backend.last.method, 'POST');
      expect(backend.last.url.path, endsWith('/appointments/5/cancel'));
      expect(backend.lastJsonBody, {'cancellation_reason': 'busy'});
    });

    test('cancel without a reason sends an empty object', () async {
      final backend = FakeBackend(appointmentJson(status: 'cancelled'));
      await serviceFor(backend).cancel(5);
      expect(backend.lastJsonBody, isEmpty);
    });

    test('reject posts to /reject with the reason', () async {
      final backend = FakeBackend(appointmentJson(status: 'rejected'));
      final result = await serviceFor(backend).reject(5, reason: 'full');

      expect(backend.last.url.path, endsWith('/appointments/5/reject'));
      expect(backend.lastJsonBody, {'cancellation_reason': 'full'});
      expect(result.status, 'rejected');
    });

    test('accept posts to /accept', () async {
      final backend = FakeBackend(appointmentJson(status: 'confirmed'));
      final result = await serviceFor(backend).accept(5);

      expect(backend.last.url.path, endsWith('/appointments/5/accept'));
      expect(result.status, 'confirmed');
    });

    test('complete posts to /complete', () async {
      final backend = FakeBackend(appointmentJson(status: 'completed'));
      final result = await serviceFor(backend).complete(5);

      expect(backend.last.url.path, endsWith('/appointments/5/complete'));
      expect(result.status, 'completed');
    });
  });
}
