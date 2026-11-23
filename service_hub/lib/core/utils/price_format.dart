/// Shown wherever a service has no price (the price is optional).
const String noPriceLabel = 'السعر غير محدد';

/// "25.50 $", or [noPriceLabel] for a service published without a price.
/// Never prints "0" or "null" for a missing price.
String formatPrice(double? price, {int decimals = 2}) =>
    price == null ? noPriceLabel : '${price.toStringAsFixed(decimals)} \$';

/// The result of reading the optional price field of a service form.
class PriceInput {
  const PriceInput._(this.value, this.isValid);

  /// The price to send, or null when the field was left empty.
  final double? value;

  /// False when something was typed that isn't a positive amount.
  final bool isValid;

  /// Empty (or only spaces) -> no price (null, NOT zero). Otherwise the
  /// text must be a positive number with at most two decimals; Arabic-Indic
  /// digits and the Arabic decimal comma are accepted.
  static PriceInput parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const PriceInput._(null, true);
    const arabicDigits = '٠١٢٣٤٥٦٧٨٩';
    final normalized = StringBuffer();
    for (final ch in text.split('')) {
      final i = arabicDigits.indexOf(ch);
      normalized.write(i >= 0 ? '$i' : (ch == '٫' || ch == ',' ? '.' : ch));
    }
    final value = double.tryParse(normalized.toString());
    final ok = value != null &&
        value.isFinite &&
        value > 0 &&
        RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(normalized.toString());
    return ok ? PriceInput._(value, true) : const PriceInput._(null, false);
  }
}
