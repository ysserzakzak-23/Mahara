import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'contract_support.dart';
import 'endpoints.dart';

/// Backend -> app: do the real responses fit the Dart models?
///
/// The backend generates example responses from its own schemas (see
/// tools/export_contract.py). Here they go through the app's real `fromJson`.
void main() {
  final contract = ApiContract.load();

  dynamic fresh(dynamic json) => jsonDecode(jsonEncode(json));

  group('every endpoint the app calls exists on the backend', () {
    for (final e in appEndpoints) {
      test('${e.method} ${e.path}', () {
        final operation = contract.operationFor(e.method, '$apiPrefix${e.path}');
        expect(
          operation,
          isNotNull,
          reason: 'The app calls ${e.method} $apiPrefix${e.path} but the backend has no '
              'such operation (renamed route, wrong method, or a typo).',
        );
      });
    }
  });

  group('responses fit the Dart models', () {
    for (final e in appEndpoints.where((e) => e.parse != null)) {
      final key = '${e.method} $apiPrefix${e.path}';
      final sample = contract.samples[key];

      group(key, () {
        if (sample == null) {
          test('the backend declares a JSON response', () {
            fail('The app parses the response of $key but the backend documents no JSON body.');
          });
          return;
        }

        test('parses a complete response', () {
          expect(() => e.parse!(fresh(sample['full'])), returnsNormally);
        });

        test('parses a response where every optional field is null', () {
          expect(() => e.parse!(fresh(sample['nulls'])), returnsNormally);
        });

        test('only reads fields the backend actually sends', () {
          final log = ReadLog();
          e.parse!(wrapRecording(fresh(sample['full']), '', log));

          final unexpected = log.missing
              .where((path) => !optionalEnrichmentKeys.contains(path.split('.').last))
              .toList()
            ..sort();
          expect(
            unexpected,
            isEmpty,
            reason: 'The Dart model reads fields that $key does not return - it would '
                'silently get null (renamed or removed field?):\n  ${unexpected.join('\n  ')}',
          );
        });
      });
    }
  });

  group('enum values the UI relies on still exist', () {
    enumExpectations.forEach((schemaName, literals) {
      test(schemaName, () {
        final schema = contract.schemas[schemaName] as Map<String, dynamic>?;
        expect(schema, isNotNull, reason: 'The backend has no enum called $schemaName any more.');
        final values = (schema!['enum'] as List).cast<String>();
        expect(
          values,
          containsAll(literals),
          reason: '$schemaName on the backend is $values; the app compares against $literals.',
        );
      });
    });

    test('NotificationType keeps the prefixes the notifications screen matches on', () {
      final values = ((contract.schemas['NotificationType'] as Map)['enum'] as List).cast<String>();
      for (final prefix in notificationTypePrefixes) {
        expect(values.any((v) => v.startsWith(prefix)), isTrue, reason: 'no type starts with "$prefix"');
      }
    });
  });
}
