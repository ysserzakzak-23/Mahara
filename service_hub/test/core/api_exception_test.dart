import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_exception.dart';

void main() {
  test('toString returns the human readable message', () {
    expect(ApiException('Nope').toString(), 'Nope');
  });

  test('isUnauthorized is true only for 401', () {
    expect(ApiException('x', statusCode: 401).isUnauthorized, isTrue);
    expect(ApiException('x', statusCode: 403).isUnauthorized, isFalse);
    expect(ApiException('x').isUnauthorized, isFalse);
  });
}
