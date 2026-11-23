import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/distance_format.dart';
import 'package:service_hub/core/utils/price_format.dart';

void main() {
  group('formatPrice', () {
    test('a missing price reads «السعر غير محدد», never 0 or null', () {
      expect(formatPrice(null), 'السعر غير محدد');
      expect(formatPrice(null, decimals: 0), 'السعر غير محدد');
    });

    test('a price keeps its amount and currency', () {
      expect(formatPrice(25.5), '25.50 \$');
      expect(formatPrice(30, decimals: 0), '30 \$');
    });
  });

  group('PriceInput.parse', () {
    for (final empty in ['', '   ']) {
      test('"$empty" means no price (null) and is valid', () {
        final input = PriceInput.parse(empty);
        expect(input.isValid, isTrue);
        expect(input.value, isNull);
      });
    }

    test('an empty price is never turned into zero', () {
      expect(PriceInput.parse('').value, isNot(0));
    });

    final valid = {'25': 25.0, '25.5': 25.5, ' 10.25 ': 10.25, '٢٥': 25.0, '٢٥٫٥': 25.5, '7,5': 7.5};
    valid.forEach((text, value) {
      test('"$text" is the price $value', () {
        final input = PriceInput.parse(text);
        expect(input.isValid, isTrue);
        expect(input.value, value);
      });
    });

    for (final bad in ['0', '0.00', '-5', 'abc', '1.234', '1e3', 'NaN', '12 \$']) {
      test('"$bad" is rejected', () {
        final input = PriceInput.parse(bad);
        expect(input.isValid, isFalse);
        expect(input.value, isNull);
      });
    }
  });

  group('formatDistance', () {
    final cases = {
      0.0: '10 متر',
      0.004: '10 متر',
      0.08: '80 متر',
      0.5: '500 متر',
      0.504: '500 متر',
      0.996: '1 كم',
      1.0: '1 كم',
      1.24: '1.2 كم',
      1.25: '1.3 كم',
      3.0: '3 كم',
      3.04: '3 كم',
      9.96: '10 كم',
      12.4: '12 كم',
      150.6: '151 كم',
    };
    cases.forEach((km, text) {
      test('$km km -> "$text"', () => expect(formatDistance(km), text));
    });

    test('nonsense input never shows a negative distance', () {
      expect(formatDistance(-1), '10 متر');
      expect(formatDistance(double.nan), '10 متر');
    });
  });
}
