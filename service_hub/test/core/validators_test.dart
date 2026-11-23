import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/validators.dart';

void main() {
  group('passwordError', () {
    test('rejects empty and short passwords', () {
      expect(passwordError(''), 'كلمة المرور مطلوبة');
      expect(passwordError('1234567'), kPasswordRuleText);
    });

    test('accepts 8 or more characters', () {
      expect(passwordError('12345678'), isNull);
      expect(passwordError('a much longer password'), isNull);
    });
  });

  group('phoneError', () {
    test('is required', () {
      expect(phoneError(''), 'رقم الجوال مطلوب');
      expect(phoneError('   '), 'رقم الجوال مطلوب');
    });

    test('needs at least 10 digits', () {
      expect(phoneError('091234567'), kPhoneRuleText);
      expect(phoneError('0912345678'), isNull);
      expect(phoneError('+963 912 345 678'), isNull);
    });

    test('rejects letters', () {
      expect(phoneError('09123abc678'), 'رقم الجوال يجب أن يحتوي على أرقام فقط');
    });

    test('accepts Arabic-Indic digits', () {
      expect(phoneError('٠٩١٢٣٤٥٦٧٨'), isNull);
      expect(phoneDigitCount('٠٩١٢٣٤٥٦٧٨'), 10);
    });
  });

  group('confirmPasswordError', () {
    test('requires a value that matches', () {
      expect(confirmPasswordError('Secret123', ''), 'يرجى تأكيد كلمة المرور');
      expect(confirmPasswordError('Secret123', 'Other'), 'كلمتا المرور غير متطابقتين');
      expect(confirmPasswordError('Secret123', 'Secret123'), isNull);
    });
  });

  group('emailError', () {
    test('validates the format', () {
      expect(emailError(''), 'البريد الإلكتروني مطلوب');
      expect(emailError('nope'), 'أدخل بريداً إلكترونياً صحيحاً');
      expect(emailError(' a@b.com '), isNull);
    });
  });

  test('normalizeDigits converts Arabic-Indic and Persian digits', () {
    expect(normalizeDigits('٠١٢٣٤٥٦٧٨٩'), '0123456789');
    expect(normalizeDigits('۰۱۲'), '012');
    expect(normalizeDigits('abc 12'), 'abc 12');
  });
}
