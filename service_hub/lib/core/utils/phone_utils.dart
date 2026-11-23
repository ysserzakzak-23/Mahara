/// Turns a user-entered phone number (any of the messy formats people type —
/// spaces, dashes, parentheses, a leading 0, a leading +963/00963, etc.)
/// into the plain-digits-with-country-code form wa.me needs, e.g.
/// "0912 345 678" -> "963912345678".
///
/// Assumes Syria (+963) when the number is in local format (starts with a
/// single leading 0) since that's this app's city list / target market —
/// see backend/app/core/constants.py CITIES. A number that's already in
/// international form (leading + or 00) is respected as-is.
String? normalizedWhatsAppNumber(String? rawPhone) {
  if (rawPhone == null) return null;
  final trimmed = rawPhone.trim();
  if (trimmed.isEmpty) return null;

  final hadPlus = trimmed.startsWith('+');
  var digits = trimmed.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;

  if (hadPlus) {
    // Already international, e.g. "+963912345678".
  } else if (digits.startsWith('00')) {
    // "00963912345678" -> "963912345678"
    digits = digits.substring(2);
  } else if (digits.startsWith('0')) {
    // Local Syrian format, e.g. "0912345678" -> "963912345678"
    digits = '963${digits.substring(1)}';
  }
  // Otherwise: assume it already includes a country code as typed.

  // A real mobile number with country code is realistically at least 8
  // digits — guards against turning a garbage/partial value into a wa.me
  // link that just opens WhatsApp's own "invalid number" page.
  if (digits.length < 8) return null;

  return digits;
}

/// Builds a `wa.me` deep link for the given phone number, or null if the
/// number can't be normalized into something usable.
Uri? whatsAppUri(String? rawPhone) {
  final number = normalizedWhatsAppNumber(rawPhone);
  if (number == null) return null;
  return Uri.parse('https://wa.me/$number');
}
