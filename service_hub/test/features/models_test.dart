import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/features/admin/data/admin_models.dart';
import 'package:service_hub/features/auth/data/auth_models.dart';
import 'package:service_hub/features/availability/data/availability_models.dart';
import 'package:service_hub/features/booking/data/appointment_models.dart';
import 'package:service_hub/features/exchange/data/exchange_models.dart';
import 'package:service_hub/features/notifications/data/notification_models.dart';
import 'package:service_hub/features/reviews/data/review_models.dart';
import 'package:service_hub/features/service/data/service_models.dart';

import '../helpers/fixtures.dart';

void main() {
  group('auth models', () {
    test('AuthTokens', () {
      final t = AuthTokens.fromJson({'access_token': 'a', 'refresh_token': 'r'});
      expect((t.accessToken, t.refreshToken), ('a', 'r'));
    });

    test('UserProfile tolerates missing fields', () {
      final p = UserProfile.fromJson({});
      expect(p.fullName, '');
      expect(p.phoneNumber, isNull);
    });

    test('AppUser applies defaults for optional fields', () {
      final u = AppUser.fromJson({'id': 1, 'email': 'a@b.com'});
      expect(u.role, 'user');
      expect(u.isProvider, isFalse);
      expect(u.isActive, isTrue);
      expect(u.profile, isNull);
    });

    test('AppUser parses a nested profile', () {
      final u = AppUser.fromJson({
        'id': 1,
        'email': 'a@b.com',
        'role': 'admin',
        'is_provider': true,
        'profile': {'full_name': 'Ahmad', 'city': 'Damascus'},
      });
      expect(u.role, 'admin');
      expect(u.isProvider, isTrue);
      expect(u.profile!.fullName, 'Ahmad');
      expect(u.profile!.city, 'Damascus');
    });
  });

  group('ServiceProvider', () {
    test('reads data from the nested profile', () {
      final p = ServiceProvider.fromJson(providerJson());
      expect(p.fullName, 'Ahmad Ali');
      expect(p.city, 'Damascus');
      expect(p.displayName, 'Ahmad Ali');
    });

    test('falls back to "Provider #id" when there is no profile', () {
      final p = ServiceProvider.fromJson({'id': 42});
      expect(p.displayName, 'مزوّد #42');
      expect(p.isProvider, isFalse);
    });
  });

  group('ServiceCategory', () {
    test('defaults', () {
      final c = ServiceCategory.fromJson({'id': 1, 'name': 'X'});
      expect(c.isActive, isTrue);
      expect(c.isOther, isFalse);
    });
  });

  group('ServiceListItem', () {
    test('parses a price sent as a string (Decimal)', () {
      final s = ServiceListItem.fromJson(serviceListItemJson(price: '25.50'));
      expect(s.price, 25.5);
    });

    test('parses int and double prices', () {
      expect(ServiceListItem.fromJson(serviceListItemJson(price: 30)).price, 30.0);
      expect(ServiceListItem.fromJson(serviceListItemJson(price: 12.25)).price, 12.25);
    });

    test('an unparsable price is treated as "no price" (null, not 0) instead of crashing', () {
      expect(ServiceListItem.fromJson(serviceListItemJson(price: 'abc')).price, isNull);
    });

    test('a service without a price parses with price == null', () {
      final json = serviceListItemJson()..['price'] = null;
      expect(ServiceListItem.fromJson(json).price, isNull);
      final detail = (serviceListItemJson()..['description'] = 'I fix all kinds of pipes')..['price'] = null;
      expect(ServiceDetail.fromJson(detail).price, isNull);
    });

    test('the service is named by display_title (its category), falling back to a legacy title',
        () {
      final named = serviceListItemJson()
        ..['title'] = null
        ..['display_title'] = 'سباكة';
      expect(ServiceListItem.fromJson(named).title, 'سباكة');

      final both = serviceListItemJson()
        ..['title'] = 'Old name'
        ..['display_title'] = 'كهرباء';
      expect(ServiceListItem.fromJson(both).title, 'كهرباء');

      final legacyOnly = serviceListItemJson()..['title'] = 'Old name';
      expect(ServiceListItem.fromJson(legacyOnly).title, 'Old name');

      final neither = serviceListItemJson()..['title'] = null;
      expect(ServiceListItem.fromJson(neither).title, 'خدمة');

      final detail = (serviceListItemJson()..['description'] = 'I fix all kinds of pipes')
        ..['title'] = null
        ..['display_title'] = 'سباكة';
      expect(ServiceDetail.fromJson(detail).title, 'سباكة');
    });

    test('optional search fields are null by default', () {
      final s = ServiceListItem.fromJson(serviceListItemJson());
      expect(s.distanceKm, isNull);
      expect(s.similarityScore, isNull);
      expect(s.isRemote, isFalse);
    });

    test('geo/semantic fields are parsed when present', () {
      final json = serviceListItemJson()
        ..['distance_km'] = 3
        ..['similarity_score'] = '0.82'
        ..['average_rating'] = 4.5
        ..['total_reviews'] = 12;
      final s = ServiceListItem.fromJson(json);
      expect(s.distanceKm, 3.0);
      expect(s.similarityScore, 0.82);
      expect(s.averageRating, 4.5);
      expect(s.totalReviews, 12);
    });

    group('displayCategoryLabel', () {
      test('curated category shows its own name', () {
        final s = ServiceListItem.fromJson(
            serviceListItemJson(customLabel: 'ignored label'));
        expect(s.displayCategoryLabel, 'سباكة');
      });

      test('"أخرى" category shows the trimmed custom label', () {
        final s = ServiceListItem.fromJson(serviceListItemJson(
          category: categoryJson(name: 'أخرى', isOther: true),
          customLabel: '  سباك  ',
        ));
        expect(s.displayCategoryLabel, 'سباك');
      });

      test('"أخرى" with a blank/missing label falls back to the name', () {
        for (final label in [null, '', '   ']) {
          final s = ServiceListItem.fromJson(serviceListItemJson(
            category: categoryJson(name: 'أخرى', isOther: true),
            customLabel: label,
          ));
          expect(s.displayCategoryLabel, 'أخرى');
        }
      });
    });
  });

  group('ServiceDetail', () {
    Map<String, dynamic> detail() => {
          'id': 1,
          'title': 'T',
          'description': null,
          'price': '10.00',
          'latitude': '33.5',
          'longitude': 36.3,
          'category': categoryJson(),
          'provider': providerJson(),
        };

    test('null description becomes an empty string; coords are parsed', () {
      final d = ServiceDetail.fromJson(detail());
      expect(d.description, '');
      expect(d.latitude, 33.5);
      expect(d.longitude, 36.3);
      expect(d.price, 10.0);
    });

    test('displayCategoryLabel follows the same rule as the list item', () {
      final json = detail()
        ..['category'] = categoryJson(name: 'أخرى', isOther: true)
        ..['custom_category_label'] = 'Gardener';
      expect(ServiceDetail.fromJson(json).displayCategoryLabel, 'Gardener');
    });
  });

  test('PortfolioItem defaults', () {
    final p = PortfolioItem.fromJson({'id': 1, 'image_url': '/uploads/a.jpg'});
    expect(p.displayOrder, 0);
    expect(p.caption, isNull);
  });

  group('Appointment', () {
    test('parses fields and nested people', () {
      final a = Appointment.fromJson(appointmentJson());
      expect(a.id, 5);
      expect(a.status, 'pending');
      expect(a.customer.fullName, 'Customer');
      expect(a.provider.id, 2);
    });

    test('keeps the wall-clock time exactly as sent (no timezone shifting)', () {
      final a = Appointment.fromJson(appointmentJson());
      expect(a.startTime, DateTime(2026, 10, 5, 10, 0));
      expect(a.endTime, DateTime(2026, 10, 5, 11, 0));
      expect(a.startTime!.isUtc, isFalse);
    });

    test('defaults the title when missing', () {
      final json = appointmentJson()..remove('service_title');
      expect(Appointment.fromJson(json).serviceTitle, 'خدمة');
    });
  });

  group('exchange models', () {
    test('ExchangeRequestModel status helpers', () {
      expect(ExchangeRequestModel.fromJson(exchangeRequestJson()).isOpen, isTrue);
      expect(
        ExchangeRequestModel.fromJson(exchangeRequestJson(status: 'matched')).isOpen,
        isFalse,
      );
    });

    test('wantedCategoryLabel uses the custom label only for "أخرى"', () {
      final normal = ExchangeRequestModel.fromJson(
          exchangeRequestJson(wantedLabel: 'ignored'));
      expect(normal.wantedCategoryLabel, 'كهرباء');

      final other = ExchangeRequestModel.fromJson(exchangeRequestJson(
        wantedCategory: categoryJson(id: 9, name: 'أخرى', isOther: true),
        wantedLabel: ' Painter ',
      ));
      expect(other.wantedCategoryLabel, 'Painter');

      final blank = ExchangeRequestModel.fromJson(exchangeRequestJson(
        wantedCategory: categoryJson(id: 9, name: 'أخرى', isOther: true),
        wantedLabel: ' ',
      ));
      expect(blank.wantedCategoryLabel, 'أخرى');
    });

    test('DirectMatch defaults match_type to direct', () {
      final m = DirectMatch.fromJson({'other_request': exchangeRequestJson()});
      expect(m.matchType, 'direct');
      expect(m.otherRequest.id, 7);
    });

    test('ExchangeProposalModel.isPending', () {
      Map<String, dynamic> proposal(String status) => {
            'id': 1,
            'status': status,
            'message': 'hi',
            'proposer': providerJson(),
            'proposed_service': serviceListItemJson(),
            'request': exchangeRequestJson(),
          };
      expect(ExchangeProposalModel.fromJson(proposal('pending')).isPending, isTrue);
      expect(ExchangeProposalModel.fromJson(proposal('accepted')).isPending, isFalse);
    });
  });

  group('admin models', () {
    test('PlatformStats defaults everything to zero', () {
      final s = PlatformStats.fromJson({});
      expect(s.totalUsers, 0);
      expect(s.averagePlatformRating, 0.0);
    });

    test('PlatformStats converts an int rating to double', () {
      expect(PlatformStats.fromJson({'average_platform_rating': 4}).averagePlatformRating, 4.0);
    });

    test('AdminUser reads the name from the profile', () {
      final u = AdminUser.fromJson({
        'id': 1,
        'email': 'a@b.com',
        'profile': {'full_name': 'Admin'},
      });
      expect(u.fullName, 'Admin');
      expect(u.role, 'user');
    });

    test('AdminServiceListing parses a string price', () {
      final l = AdminServiceListing.fromJson({
        'id': 1, 'title': 'T', 'price': '99.90', 'provider_id': 2, 'category_id': 3,
      });
      expect(l.price, 99.9);
      expect(l.status, 'active');
    });
  });

  test('AppNotification parses date and defaults', () {
    final n = AppNotification.fromJson({
      'id': 1,
      'type': 'appointment_booked',
      'title': 'T',
      'message': 'M',
      'created_at': '2026-10-05T10:00:00Z',
    });
    expect(n.isRead, isFalse);
    expect(n.relatedEntityId, isNull);
    expect(n.createdAt, DateTime.utc(2026, 10, 5, 10));
  });

  group('availability', () {
    test('AvailabilityWindow', () {
      final w = AvailabilityWindow.fromJson({
        'id': 1, 'day_of_week': 0, 'start_time': '09:00:00', 'end_time': '17:00:00',
      });
      expect(w.isActive, isTrue);
      expect(w.startTime, '09:00:00');
    });

    test('an appointment without a day/hour parses (remote request)', () {
      final a = Appointment.fromJson({
        ...appointmentJson(),
        'start_time': null,
        'end_time': null,
      });
      expect(a.startTime, isNull);
      expect(a.endTime, isNull);
      expect(a.hasTime, isFalse);
    });

    test('a normal appointment has a time', () {
      expect(Appointment.fromJson(appointmentJson()).hasTime, isTrue);
    });

    test('DaySlot and DaySlots', () {
      final day = DaySlots.fromJson({
        'day': '2026-11-02',
        'day_of_week': 0,
        'slots': [
          {'start_time': '09:30:00', 'end_time': '10:30:00', 'is_booked': true},
        ],
      });
      expect(day.day, '2026-11-02');
      final slot = day.slots.single;
      expect(slot.isBooked, isTrue);
      expect(slot.startHour, 9);
      expect(slot.startMinute, 30);
    });

    test('kWeekdayNames is Monday-first with 7 entries', () {
      expect(kWeekdayNames.length, 7);
      expect(kWeekdayNames.first, 'الاثنين');
      expect(kWeekdayNames.last, 'الأحد');
    });
  });

  group('reviews', () {
    test('Review', () {
      final r = Review.fromJson({'id': 1, 'rating': 5, 'reviewer': providerJson()});
      expect(r.rating, 5);
      expect(r.comment, isNull);
    });

    test('RatingSummary defaults and int->double conversion', () {
      expect(RatingSummary.fromJson({}).averageRating, 0.0);
      expect(RatingSummary.fromJson({}).reviewCount, 0);
      expect(RatingSummary.fromJson({'average_rating': 4, 'review_count': 3}).averageRating, 4.0);
    });
  });
}
