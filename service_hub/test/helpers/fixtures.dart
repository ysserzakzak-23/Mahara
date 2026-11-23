import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:service_hub/core/config/api_config.dart';

const jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// A token shaped like the one the backend signs, for tests that store one.
///
/// The signature is a placeholder: nothing in the app verifies it (only the
/// backend can), so a well-formed header and payload are all a test needs.
/// Mirrors app/core/security.py's payload.
String tokenFor(
  Object? subject, {
  String type = 'access',
  bool expired = false,
  String signature = 'not-a-real-signature',
}) {
  String segment(Map<String, Object?> part) =>
      base64Url.encode(utf8.encode(jsonEncode(part))).replaceAll('=', '');

  final issued = DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch ~/ 1000;
  return [
    segment({'alg': 'HS256', 'typ': 'JWT'}),
    segment({
      'sub': subject,
      'type': type,
      'iat': issued,
      'exp': expired ? issued + 60 : issued + 3600,
    }),
    signature,
  ].join('.');
}

/// Records the last request a service sent and answers with [body].
class FakeBackend {
  FakeBackend(this.body, {this.status = 200}) {
    client = MockClient((req) async {
      requests.add(req);
      return http.Response(
        body == null ? '' : jsonEncode(body),
        status,
        headers: jsonHeaders,
      );
    });
  }

  final Object? body;
  final int status;
  final List<http.Request> requests = [];
  late final http.Client client;

  http.Request get last => requests.last;
  Map<String, dynamic> get lastJsonBody =>
      jsonDecode(last.body) as Map<String, dynamic>;
}

Map<String, dynamic> categoryJson({
  int id = 1,
  String name = 'سباكة',
  bool isOther = false,
}) =>
    {
      'id': id,
      'name': name,
      'description': 'desc',
      'icon_name': 'plumbing',
      'is_active': true,
      'is_other': isOther,
    };

Map<String, dynamic> providerJson({int id = 10, String name = 'Ahmad Ali'}) => {
      'id': id,
      'is_provider': true,
      'profile': {
        'full_name': name,
        'avatar_url': '/uploads/a.jpg',
        'city': 'Damascus',
        'bio': 'bio',
        'phone_number': '0912345678',
      },
    };

Map<String, dynamic> serviceListItemJson({
  int id = 100,
  Object price = '25.50',
  Map<String, dynamic>? category,
  String? customLabel,
}) =>
    {
      'id': id,
      'title': 'Fix pipes',
      'price': price,
      'price_unit': 'per_hour',
      'status': 'active',
      'category': category ?? categoryJson(),
      'provider': providerJson(),
      'custom_category_label': customLabel,
    };

Map<String, dynamic> appointmentJson({int id = 5, String status = 'pending'}) =>
    {
      'id': id,
      'service_id': 100,
      'service_title': 'Fix pipes',
      'start_time': '2026-10-05T10:00:00',
      'end_time': '2026-10-05T11:00:00',
      'status': status,
      'customer_notes': 'note',
      'cancellation_reason': null,
      'customer': providerJson(id: 1, name: 'Customer'),
      'provider': providerJson(id: 2, name: 'Provider'),
    };

Map<String, dynamic> exchangeRequestJson({
  String status = 'open',
  Map<String, dynamic>? wantedCategory,
  String? wantedLabel,
}) =>
    {
      'id': 7,
      'status': status,
      'user': providerJson(),
      'offered_service': serviceListItemJson(),
      'offered_category': categoryJson(id: 1),
      'wanted_category': wantedCategory ?? categoryJson(id: 2, name: 'كهرباء'),
      'wanted_custom_category_label': wantedLabel,
    };


/// A canned answer for [RoutedBackend].
class Reply {
  const Reply(this.body, {this.status = 200});
  final Object? body;
  final int status;
}

/// Fake backend for screen tests: answers by "METHOD /path" (the `/api/v1`
/// prefix and the query string are ignored), e.g. `'GET /notifications'`.
/// Unknown routes answer 404 so a forgotten route fails loudly in the UI.
///
/// * `routes` is mutable: change a reply in the middle of a test.
/// * `gate`: while set, every request waits for it (to test loading states).
class RoutedBackend {
  RoutedBackend(Map<String, Reply> routes) : routes = Map.of(routes) {
    client = MockClient((req) async {
      requests.add(req);
      if (gate != null) await gate!.future;
      final path = req.url.path.replaceFirst(ApiConfig.apiPrefix, '');
      final key = '${req.method} $path';
      // A route may include the query ("GET /x?sent=true") to be more specific.
      final reply = this.routes['$key?${req.url.query}'] ??
          this.routes[key] ??
          Reply({'detail': 'No fake route for $key'}, status: 404);
      return http.Response(
        reply.body == null ? '' : jsonEncode(reply.body),
        reply.status,
        headers: jsonHeaders,
      );
    });
  }

  final Map<String, Reply> routes;
  final List<http.Request> requests = [];
  Completer<void>? gate;
  late final http.Client client;

  String _key(http.Request r) =>
      '${r.method} ${r.url.path.replaceFirst(ApiConfig.apiPrefix, '')}';

  /// How many times "METHOD /path" was called.
  int callsTo(String key) => requests.where((r) => _key(r) == key).length;

  /// The decoded JSON body of the last call to "METHOD /path".
  Map<String, dynamic> lastBodyOf(String key) => jsonDecode(
        requests.lastWhere((r) => _key(r) == key).body,
      ) as Map<String, dynamic>;
}
