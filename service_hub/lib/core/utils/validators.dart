/// Input rules shared by the register / reset-password / edit-profile screens.
/// They mirror the backend rules in app/schemas/user.py.
library;

const int kMinPasswordLength = 8;
const int kMinPhoneDigits = 10;

/// Rule texts shown permanently under the fields so the user knows the rule
/// before typing.
const String kPasswordRuleText = 'يجب أن تتكون كلمة المرور من 8 أحرف أو أكثر';
const String kPhoneRuleText = 'يجب أن يتكون رقم الجوال من 10 أرقام أو أكثر';
const String kConfirmPasswordRuleText = 'أعد كتابة كلمة المرور نفسها للتأكيد';

/// Converts Arabic-Indic (٠-٩) and Persian (۰-۹) digits to 0-9 so numbers typed
/// on an Arabic keyboard are accepted by the validators and the backend.
String normalizeDigits(String input) {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final a = arabicIndic.indexOf(ch);
    final p = persian.indexOf(ch);
    if (a >= 0) {
      buffer.write(a);
    } else if (p >= 0) {
      buffer.write(p);
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

bool isValidEmail(String value) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());

int phoneDigitCount(String value) =>
    normalizeDigits(value).replaceAll(RegExp(r'[^0-9]'), '').length;

String? emailError(String value) {
  if (value.trim().isEmpty) return 'البريد الإلكتروني مطلوب';
  if (!isValidEmail(value)) return 'أدخل بريداً إلكترونياً صحيحاً';
  return null;
}

String? passwordError(String value) {
  if (value.isEmpty) return 'كلمة المرور مطلوبة';
  if (value.length < kMinPasswordLength) return kPasswordRuleText;
  return null;
}

String? confirmPasswordError(String password, String confirm) {
  if (confirm.isEmpty) return 'يرجى تأكيد كلمة المرور';
  if (password != confirm) return 'كلمتا المرور غير متطابقتين';
  return null;
}

String? phoneError(String value) {
  final text = normalizeDigits(value).trim();
  if (text.isEmpty) return 'رقم الجوال مطلوب';
  if (!RegExp(r'^[0-9+\-\s()]+$').hasMatch(text)) {
    return 'رقم الجوال يجب أن يحتوي على أرقام فقط';
  }
  if (phoneDigitCount(text) < kMinPhoneDigits) return kPhoneRuleText;
  return null;
}
