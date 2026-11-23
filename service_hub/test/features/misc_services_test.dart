import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_client.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/storage/token_store.dart';
import 'package:service_hub/features/availability/data/availability_service.dart';
import 'package:service_hub/features/notifications/data/notification_service.dart';
import 'package:service_hub/features/reviews/data/review_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fixtures.dart';

ApiClient apiFor(FakeBackend backend) =>
    ApiClient(httpClient: backend.client, tokenStore: TokenStore());

const windowJson = {
  'id': 1,
  'day_of_week': 0,
  'start_time': '09:00:00',
  'end_time': '17:00:00',
  'is_active': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({'access_token': 'acc'}));

  group('AvailabilityService', () {
    test('slots asks for one day, is public and parses booked / free hours', () async {
      final backend = FakeBackend({
        'day': '2026-11-02',
        'day_of_week': 0,
        'slots': [
          {'start_time': '09:00:00', 'end_time': '10:00:00', 'is_booked': false},
          {'start_time': '10:00:00', 'end_time': '11:00:00', 'is_booked': true},
        ],
      });
      final day = await AvailabilityService(apiClient: apiFor(backend))
          .slots(2, DateTime(2026, 11, 2));

      expect(backend.last.url.path, endsWith('/providers/2/availability/slots'));
      expect(backend.last.url.queryParameters, {'day': '2026-11-02'});
      expect(backend.last.headers.containsKey('Authorization'), isFalse);
      expect(day.dayOfWeek, 0);
      expect(day.slots.map((s) => s.isBooked), [false, true]);
      expect(day.slots.first.startHour, 9);
    });

    test('slots pads single-digit months and days', () async {
      final backend = FakeBackend({'day': '2026-03-07', 'day_of_week': 5, 'slots': []});
      await AvailabilityService(apiClient: apiFor(backend)).slots(2, DateTime(2026, 3, 7));
      expect(backend.last.url.queryParameters['day'], '2026-03-07');
    });

    test('list is public and parses windows', () async {
      final backend = FakeBackend([windowJson]);
      final list = await AvailabilityService(apiClient: apiFor(backend)).list(2);

      expect(backend.last.url.path, endsWith('/providers/2/availability'));
      expect(backend.last.headers.containsKey('Authorization'), isFalse);
      expect(list.single.dayOfWeek, 0);
    });

    test('create appends :00 seconds to HH:MM times', () async {
      final backend = FakeBackend(windowJson, status: 201);
      await AvailabilityService(apiClient: apiFor(backend))
          .create(2, dayOfWeek: 0, startTime: '09:00', endTime: '17:30');

      expect(backend.lastJsonBody, {
        'day_of_week': 0,
        'start_time': '09:00:00',
        'end_time': '17:30:00',
      });
    });

    test('deactivate issues DELETE on the window', () async {
      final backend = FakeBackend(null, status: 204);
      await AvailabilityService(apiClient: apiFor(backend)).deactivate(2, 9);

      expect(backend.last.method, 'DELETE');
      expect(backend.last.url.path, endsWith('/providers/2/availability/9'));
    });
  });

  group('ReviewService', () {
    final reviewJson = {'id': 1, 'rating': 5, 'comment': 'great', 'reviewer': providerJson()};

    test('listReviews and summary', () async {
      var backend = FakeBackend([reviewJson]);
      final reviews = await ReviewService(apiClient: apiFor(backend)).listReviews(100);
      expect(backend.last.url.path, endsWith('/services/100/reviews'));
      expect(reviews.single.rating, 5);

      backend = FakeBackend({'average_rating': 4.5, 'review_count': 2});
      final summary = await ReviewService(apiClient: apiFor(backend)).summary(100);
      expect(backend.last.url.path, endsWith('/services/100/reviews/summary'));
      expect(summary.averageRating, 4.5);
    });

    test('submitReview sends rating and optional comment', () async {
      var backend = FakeBackend(reviewJson, status: 201);
      await ReviewService(apiClient: apiFor(backend))
          .submitReview(100, rating: 5, comment: 'great');
      expect(backend.lastJsonBody, {'rating': 5, 'comment': 'great'});

      backend = FakeBackend(reviewJson, status: 201);
      await ReviewService(apiClient: apiFor(backend)).submitReview(100, rating: 4, comment: '');
      expect(backend.lastJsonBody, {'rating': 4});
    });

    test('forwards the backend 403 message (e.g. never booked)', () async {
      final backend = FakeBackend(
        {'detail': 'You can only review services you have booked'},
        status: 403,
      );
      await expectLater(
        ReviewService(apiClient: apiFor(backend)).submitReview(100, rating: 5),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('booked'))
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });
  });

  group('NotificationService', () {
    test('list passes the unread_only flag', () async {
      final backend = FakeBackend(<dynamic>[]);
      final service = NotificationService(apiClient: apiFor(backend));

      await service.list();
      expect(backend.last.url.queryParameters['unread_only'], 'false');
      await service.list(unreadOnly: true);
      expect(backend.last.url.queryParameters['unread_only'], 'true');
    });

    test('unreadCount reads unread_count', () async {
      final backend = FakeBackend({'unread_count': 3});
      expect(await NotificationService(apiClient: apiFor(backend)).unreadCount(), 3);
      expect(backend.last.url.path, endsWith('/notifications/unread-count'));
    });

    test('markRead and markAllRead POST to the right endpoints', () async {
      final backend = FakeBackend(null, status: 204);
      final service = NotificationService(apiClient: apiFor(backend));

      await service.markRead(8);
      expect(backend.last.method, 'POST');
      expect(backend.last.url.path, endsWith('/notifications/8/read'));

      await service.markAllRead();
      expect(backend.last.url.path, endsWith('/notifications/read-all'));
    });

    test('registerDevice sends the FCM token and optional label', () async {
      final backend = FakeBackend(null, status: 204);
      final service = NotificationService(apiClient: apiFor(backend));

      await service.registerDevice('tok');
      expect(backend.lastJsonBody, {'fcm_token': 'tok'});

      await service.registerDevice('tok', deviceLabel: 'Pixel');
      expect(backend.lastJsonBody, {'fcm_token': 'tok', 'device_label': 'Pixel'});
    });
  });
}
