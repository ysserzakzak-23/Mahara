import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/phone_utils.dart';

void main() {
  group('normalizedWhatsAppNumber', () {
    test('returns null for null, empty, whitespace and non-digit input', () {
      expect(normalizedWhatsAppNumber(null), isNull);
      expect(normalizedWhatsAppNumber(''), isNull);
      expect(normalizedWhatsAppNumber('   '), isNull);
      expect(normalizedWhatsAppNumber('abc'), isNull);
      expect(normalizedWhatsAppNumber('+'), isNull);
    });

    test('converts local Syrian format (leading 0) to 963', () {
      expect(normalizedWhatsAppNumber('0912345678'), '963912345678');
      expect(normalizedWhatsAppNumber('0912 345 678'), '963912345678');
      expect(normalizedWhatsAppNumber('0912-345-678'), '963912345678');
      expect(normalizedWhatsAppNumber('(0912) 345-678'), '963912345678');
    });

    test('keeps international formats', () {
      expect(normalizedWhatsAppNumber('+963 912 345 678'), '963912345678');
      expect(normalizedWhatsAppNumber('00963912345678'), '963912345678');
      expect(normalizedWhatsAppNumber('963912345678'), '963912345678');
    });

    test('respects other country codes when written with +', () {
      expect(normalizedWhatsAppNumber('+49 151 2345 6789'), '4915123456789');
    });

    test('returns null when the number is too short to be real', () {
      expect(normalizedWhatsAppNumber('12345'), isNull);
      expect(normalizedWhatsAppNumber('0123'), isNull);
    });
  });

  group('whatsAppUri', () {
    test('builds a wa.me link', () {
      expect(
        whatsAppUri('0912345678'),
        Uri.parse('https://wa.me/963912345678'),
      );
    });

    test('returns null for unusable numbers', () {
      expect(whatsAppUri(null), isNull);
      expect(whatsAppUri('12'), isNull);
    });
  });
}
