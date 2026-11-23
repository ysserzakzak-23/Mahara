import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/location/location_service.dart';
import 'package:service_hub/core/utils/error_text.dart';
import 'package:service_hub/core/utils/status_labels.dart';
import 'package:service_hub/features/exchange/data/exchange_models.dart';

import '../helpers/fixtures.dart';

final _latin = RegExp('[A-Za-z]');
final _arabic = RegExp('[؀-ۿ]');

/// Every value of each backend enum (backend_updated/app/models/*.py).
const _backendValues = {
  'appointment (AppointmentStatus)': ['pending', 'confirmed', 'rejected', 'completed', 'cancelled'],
  'exchange request (ExchangeRequestStatus)': ['open', 'matched', 'closed'],
  'exchange proposal (ExchangeProposalStatus)': ['pending', 'accepted', 'rejected', 'withdrawn'],
  'service (ServiceStatus)': ['active', 'inactive', 'suspended'],
  'user role (UserRole)': ['user', 'admin'],
};

final _labelOf = <String, String Function(String?)>{
  'appointment (AppointmentStatus)': appointmentStatusLabel,
  'exchange request (ExchangeRequestStatus)': exchangeRequestStatusLabel,
  'exchange proposal (ExchangeProposalStatus)': exchangeProposalStatusLabel,
  'service (ServiceStatus)': serviceStatusLabel,
  'user role (UserRole)': userRoleLabel,
};

void main() {
  group('every backend value has an Arabic label', () {
    _backendValues.forEach((domain, values) {
      for (final value in values) {
        test('$domain: "$value"', () {
          final label = _labelOf[domain]!(value);
          expect(label, isNot(unknownLabel));
          expect(label, matches(_arabic));
          expect(label, isNot(matches(_latin)), reason: 'no English in "$label"');
        });
      }
    });
  });

  test('the exact Arabic wording', () {
    expect(exchangeRequestStatusLabel('open'), 'مفتوح');
    expect(exchangeRequestStatusLabel('matched'), 'محجوز');
    expect(exchangeRequestStatusLabel('closed'), 'مغلق');

    expect(exchangeProposalStatusLabel('pending'), 'قيد الانتظار');
    expect(exchangeProposalStatusLabel('accepted'), 'مقبول');
    expect(exchangeProposalStatusLabel('rejected'), 'مرفوض');
    expect(exchangeProposalStatusLabel('withdrawn'), 'مسحوب');

    expect(appointmentStatusLabel('pending'), 'بانتظار الموافقة');
    expect(appointmentStatusLabel('confirmed'), 'مؤكد');
    expect(appointmentStatusLabel('rejected'), 'مرفوض');
    expect(appointmentStatusLabel('completed'), 'مكتمل');
    expect(appointmentStatusLabel('cancelled'), 'ملغى');

    expect(serviceStatusLabel('active'), 'نشطة');
    expect(serviceStatusLabel('inactive'), 'متوقفة');
    expect(serviceStatusLabel('suspended'), 'موقوفة');

    expect(userRoleLabel('admin'), 'مشرف');
    expect(userRoleLabel('user'), 'مستخدم');
  });

  test('the maps cover exactly the backend values (nothing missing, nothing invented)', () {
    expect(exchangeRequestStatusLabels.keys.toSet(), {'open', 'matched', 'closed'});
    expect(exchangeProposalStatusLabels.keys.toSet(), {'pending', 'accepted', 'rejected', 'withdrawn'});
    expect(serviceStatusLabels.keys.toSet(), {'active', 'inactive', 'suspended'});
    expect(userRoleLabels.keys.toSet(), {'admin', 'user'});
    expect(appointmentStatusLabels.keys.toSet(),
        containsAll(['pending', 'confirmed', 'rejected', 'completed', 'cancelled']));
  });

  test('the same internal value can read differently per domain', () {
    // An appointment waits for the provider; a proposal waits for the owner.
    expect(appointmentStatusLabel('pending'), isNot(exchangeProposalStatusLabel('pending')));
  });

  test('case and surrounding spaces do not matter', () {
    expect(exchangeRequestStatusLabel(' OPEN '), 'مفتوح');
    expect(exchangeProposalStatusLabel('Pending'), 'قيد الانتظار');
    expect(appointmentStatusLabel('canceled'), 'ملغى'); // US spelling
  });

  group('unknown values never crash and never show English', () {
    final unknown = <String?>['archived', '', '   ', null, 'نص'];
    for (final value in unknown) {
      test('"$value"', () {
        for (final label in [
          appointmentStatusLabel(value),
          exchangeRequestStatusLabel(value),
          exchangeProposalStatusLabel(value),
          serviceStatusLabel(value),
          userRoleLabel(value),
        ]) {
          expect(label, unknownLabel);
        }
      });
    }

    test('an exchange status is not taken for a proposal status (and vice versa)', () {
      expect(exchangeProposalStatusLabel('open'), unknownLabel);
      expect(exchangeRequestStatusLabel('pending'), unknownLabel);
    });
  });

  group('price units', () {
    test('known units', () {
      expect(priceUnitLabel('fixed'), 'سعر ثابت');
      for (final unit in ['per_hour', 'hourly', 'hour']) {
        expect(priceUnitLabel(unit), 'بالساعة');
      }
      for (final unit in ['per_day', 'daily', 'day']) {
        expect(priceUnitLabel(unit), 'باليوم');
      }
      for (final unit in ['per_visit', 'visit']) {
        expect(priceUnitLabel(unit), 'بالزيارة');
      }
    });

    test('an unknown unit gives null (shown without a unit), never the English word', () {
      expect(priceUnitLabel('per_parsec'), isNull);
      expect(priceUnitLabel(null), isNull);
    });
  });

  group('internal values stay internal', () {
    test('parsing and labelling a proposal leaves its status untouched', () {
      final json = exchangeProposalJsonFor('pending');
      final proposal = ExchangeProposalModel.fromJson(json);
      exchangeProposalStatusLabel(proposal.status);

      expect(proposal.status, 'pending'); // business logic still sees 'pending'
      expect(proposal.isPending, isTrue);
      expect(json['status'], 'pending');
    });

    test('a request keeps its internal status for comparisons', () {
      final request = ExchangeRequestModel.fromJson(exchangeRequestJson(status: 'open'));
      expect(exchangeRequestStatusLabel(request.status), 'مفتوح');
      expect(request.status, 'open');
      expect(request.isOpen, isTrue);
    });
  });

  group('errorText', () {
    test('the app\'s own messages are shown as they are', () {
      expect(errorText(ApiException('الخدمة غير موجودة', statusCode: 404)), 'الخدمة غير موجودة');
      expect(errorText(LocationServiceException('خدمة الموقع مطفية')), 'خدمة الموقع مطفية');
    });

    test('any other error becomes a generic Arabic sentence, never Dart\'s English text', () {
      for (final error in <Object?>[
        StateError('Bad state: boom'),
        const FormatException('Unexpected character'),
        TypeError(),
        'some string',
        null,
        ApiException('   '),
      ]) {
        expect(errorText(error), genericErrorText);
      }
      expect(genericErrorText, isNot(matches(_latin)));
    });
  });
}

Map<String, dynamic> exchangeProposalJsonFor(String status) => {
      'id': 3,
      'status': status,
      'message': null,
      'proposer': providerJson(),
      'proposed_service': serviceListItemJson(),
      'request': exchangeRequestJson(),
    };
