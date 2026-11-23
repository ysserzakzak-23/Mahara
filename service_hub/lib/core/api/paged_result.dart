import 'api_exception.dart';

/// One page of a list endpoint, however the backend answered.
///
/// Pagination is opt-in, so a list endpoint can legitimately answer in two
/// shapes and the app has to read both:
///
///   * a **bare JSON array** — the whole collection. Either the request asked
///     for no page, or the backend predates pagination and ignored the
///     parameters (FastAPI drops unknown query parameters, so an older
///     server answers `?page=1&page_size=20` with the entire list);
///   * an **envelope** `{items, page, page_size, has_next}`, with `total`
///     only where a screen shows a count.
///
/// Anything else is a bug or a broken response and is reported as an error —
/// never quietly turned into an empty list, which on screen is
/// indistinguishable from "you have nothing".
class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.hasNext,
    this.total,
  });

  /// The whole collection as one complete page (a bare-array response).
  PagedResult.complete(List<T> items)
      : this(items: items, page: 1, pageSize: items.length, hasNext: false);

  final List<T> items;
  final int page;
  final int pageSize;

  /// Whether another page follows this one.
  final bool hasNext;

  /// The exact number of matching rows — only the admin lists ask the
  /// backend for it, so it is null everywhere else.
  final int? total;

  bool get isEmpty => items.isEmpty;
  int get length => items.length;
}

/// Reads a list response in either shape (see [PagedResult]).
///
/// [build] turns one JSON object into a model. Throws [ApiException] with
/// the app's usual Arabic wording if the response is neither a list nor a
/// well-formed envelope.
PagedResult<T> parsePagedResponse<T>(
  Object? json,
  T Function(Map<String, dynamic> item) build,
) {
  if (json is List) {
    return PagedResult.complete(_items(json, build));
  }
  if (json is Map<String, dynamic> && json['items'] is List) {
    return PagedResult(
      items: _items(json['items'] as List, build),
      page: _int(json, 'page'),
      pageSize: _int(json, 'page_size'),
      hasNext: _bool(json, 'has_next'),
      // Absent on every endpoint that does not show a count.
      total: json.containsKey('total') ? _int(json, 'total') : null,
    );
  }
  throw _malformed();
}

List<T> _items<T>(List raw, T Function(Map<String, dynamic>) build) {
  final out = <T>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) throw _malformed();
    out.add(build(item));
  }
  return out;
}

int _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  // A whole number sent as 20.0 is still a page size.
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw _malformed();
}

bool _bool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw _malformed();
}

/// Deliberately the app's generic message: a broken response shape is a bug,
/// not something to explain to the user, and no server text is involved.
ApiException _malformed() =>
    ApiException('حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.');
