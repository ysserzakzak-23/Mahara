// The shared pagination parser (Phase 4, Group 0).
//
// Nothing consumes it yet. Three cases matter: the legacy bare array, the
// new envelope, and anything else — which must be reported as an error
// rather than becoming an empty list, since an empty list on screen reads
// as "you have nothing".

import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/api/api_exception.dart';
import 'package:service_hub/core/api/paged_result.dart';

/// A stand-in model, so the parser is tested apart from any real one.
class _Item {
  const _Item(this.id);
  final int id;

  static _Item build(Map<String, dynamic> json) => _Item(json['id'] as int);
}

List<Map<String, dynamic>> _rows(int count) =>
    [for (var i = 1; i <= count; i++) {'id': i}];

Map<String, dynamic> _envelope({
  int items = 2,
  int page = 1,
  int pageSize = 20,
  bool hasNext = false,
  int? total,
}) =>
    {
      'items': _rows(items),
      'page': page,
      'page_size': pageSize,
      'has_next': hasNext,
      'total': ?total,
    };

PagedResult<_Item> _parse(Object? json) => parsePagedResponse(json, _Item.build);

final throwsMalformed = throwsA(
  isA<ApiException>().having(
    (e) => e.message,
    'message',
    'حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.',
  ),
);

void main() {
  group('a legacy bare array is one complete page', () {
    test('every row is parsed, and there is no next page', () {
      final result = _parse(_rows(45));

      expect(result.length, 45);
      expect(result.items.first.id, 1);
      expect(result.items.last.id, 45);
      expect(result.hasNext, isFalse);
      expect(result.page, 1);
      expect(result.pageSize, 45); // the whole collection arrived at once
      expect(result.total, isNull);
    });

    test('an empty array is an empty page, not an error', () {
      final result = _parse(<dynamic>[]);

      expect(result.items, isEmpty);
      expect(result.isEmpty, isTrue);
      expect(result.hasNext, isFalse);
    });

    test('this is what an older backend answers to a paginated request', () {
      // FastAPI ignores unknown query parameters, so a backend that predates
      // pagination answers `?page=1&page_size=20` with the entire list.
      final result = _parse(_rows(120));

      expect(result.length, 120);
      expect(result.hasNext, isFalse); // nothing more to ask for
    });
  });

  group('the envelope is read field by field', () {
    test('items, page, page size and has_next', () {
      final result = _parse(_envelope(items: 20, page: 2, pageSize: 20, hasNext: true));

      expect(result.length, 20);
      expect(result.page, 2);
      expect(result.pageSize, 20);
      expect(result.hasNext, isTrue);
      expect(result.total, isNull); // absent unless the endpoint sends it
    });

    test('total is read when the endpoint sends one', () {
      expect(_parse(_envelope(total: 148)).total, 148);
    });

    test('an empty page is fine', () {
      final result = _parse(_envelope(items: 0, page: 9));

      expect(result.items, isEmpty);
      expect(result.hasNext, isFalse);
      expect(result.page, 9);
    });

    test('a whole number sent as a double is still a page size', () {
      // Some JSON encoders write 20 as 20.0.
      final result = _parse({
        'items': _rows(1), 'page': 1.0, 'page_size': 20.0, 'has_next': false,
      });

      expect(result.page, 1);
      expect(result.pageSize, 20);
    });

    test('pages can be collected across requests without losing anything', () {
      final first = _parse(_envelope(items: 20, page: 1, pageSize: 20, hasNext: true));
      final second = _parse(_envelope(items: 5, page: 2, pageSize: 20, hasNext: false));

      expect([...first.items, ...second.items].length, 25);
      expect(second.hasNext, isFalse);
    });
  });

  group('anything else is an error, never an empty list', () {
    final malformed = <String, Object?>{
      'null': null,
      'a string': 'not a list',
      'a number': 42,
      'a bare object': {'id': 1},
      'an object with no items': {'page': 1, 'page_size': 20, 'has_next': false},
      'items that is not a list': {'items': 'nope', 'page': 1, 'page_size': 20, 'has_next': false},
      'items that is null': {'items': null, 'page': 1, 'page_size': 20, 'has_next': false},
      'a missing page': {'items': [], 'page_size': 20, 'has_next': false},
      'a missing page size': {'items': [], 'page': 1, 'has_next': false},
      'a missing has_next': {'items': [], 'page': 1, 'page_size': 20},
      'a page that is text': {'items': [], 'page': 'one', 'page_size': 20, 'has_next': false},
      'a fractional page': {'items': [], 'page': 1.5, 'page_size': 20, 'has_next': false},
      'has_next that is text': {'items': [], 'page': 1, 'page_size': 20, 'has_next': 'yes'},
      'a total that is text': {
        'items': [], 'page': 1, 'page_size': 20, 'has_next': false, 'total': 'many',
      },
      'an error body': {'detail': 'something went wrong'},
    };

    malformed.forEach((description, json) {
      test('$description is rejected', () => expect(() => _parse(json), throwsMalformed));
    });

    test('a row that is not an object is rejected', () {
      expect(() => _parse([1, 2, 3]), throwsMalformed);
      expect(() => _parse({'items': ['x'], 'page': 1, 'page_size': 20, 'has_next': false}),
          throwsMalformed);
    });

    test('nothing malformed is quietly turned into an empty list', () {
      for (final json in malformed.values) {
        try {
          final result = _parse(json);
          fail('expected a thrown error, got ${result.length} items for $json');
        } on ApiException {
          // the only acceptable outcome
        }
      }
    });
  });

  group('PagedResult.complete', () {
    test('wraps a ready list as one finished page', () {
      final result = PagedResult<_Item>.complete([const _Item(1), const _Item(2)]);

      expect(result.length, 2);
      expect(result.page, 1);
      expect(result.pageSize, 2);
      expect(result.hasNext, isFalse);
      expect(result.total, isNull);
    });
  });
}
