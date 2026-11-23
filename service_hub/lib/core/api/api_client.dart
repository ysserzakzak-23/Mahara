import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config/api_config.dart';
import '../storage/token_store.dart';
import 'api_exception.dart';

/// Thin HTTP wrapper around the FastAPI backend.
///
/// Responsibilities:
///   - Prefixes every path with the API base URL ([ApiConfig.apiBaseUrl]).
///   - Encodes/decodes JSON.
///   - Attaches the `Authorization: Bearer <token>` header when a token exists.
///   - Translates non-2xx responses and network failures into [ApiException]s
///     carrying the backend's `detail` message.
///   - Keeps the session alive: when a request made with a stored access
///     token is answered 401, the token pair is refreshed through
///     `POST /auth/refresh` (once, shared by every request that needs it at
///     that moment) and the request is sent again, once. See [_send].
///
/// One instance — [ApiClient.shared] — serves the whole app, so the app keeps
/// one HTTP connection pool and one refresh state. Services default to it.
/// Tests build their own instance around a fake HTTP client.
class ApiClient {
  ApiClient({http.Client? httpClient, TokenStore? tokenStore})
      : _http = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null,
        _tokenStore = tokenStore ?? TokenStore();

  /// The one client the app uses. Created on first use and never closed:
  /// it lives as long as the app does (the OS reclaims it at exit).
  static ApiClient get shared => _shared ??= ApiClient();
  static ApiClient? _shared;

  final http.Client _http;
  // Only a client this ApiClient created itself may be closed by it; one
  // handed in belongs to the caller.
  final bool _ownsHttpClient;
  final TokenStore _tokenStore;

  /// Called when the server has refused the refresh token: the session is
  /// over and the stored tokens have been cleared. [MyApp] uses it to show
  /// the login screen. Never called for a network problem.
  void Function()? onSessionExpired;

  // The refresh in flight, shared by every request that hits a 401 while it
  // runs ("single flight"). Null when none is running.
  Future<bool>? _refreshing;

  static const Duration _timeout = Duration(seconds: 20);

  Future<dynamic> get(String path, {bool auth = true}) =>
      _send('GET', path, auth: auth);

  Future<dynamic> post(String path, {Object? body, bool auth = true}) =>
      _send('POST', path, body: body, auth: auth);

  Future<dynamic> patch(String path, {Object? body, bool auth = true}) =>
      _send('PATCH', path, body: body, auth: auth);

  Future<dynamic> put(String path, {Object? body, bool auth = true}) =>
      _send('PUT', path, body: body, auth: auth);

  Future<dynamic> delete(String path, {bool auth = true}) =>
      _send('DELETE', path, auth: auth);

  /// Uploads a single file as multipart/form-data (used for avatar, service
  /// cover, and portfolio image uploads against POST /uploads/image).
  /// Takes raw [bytes] + a [filename] instead of a filesystem path — a
  /// filesystem path doesn't work on Flutter Web (no real file to read
  /// there), so callers should get bytes via `XFile.readAsBytes()`, which
  /// works the same on web, mobile, and desktop.
  /// Returns the decoded JSON body (`{"url": "..."}`).
  Future<dynamic> uploadFile(
    String path, {
    required String fieldName,
    required List<int> bytes,
    required String filename,
    MediaType? contentType,
    bool auth = true,
  }) {
    final uri = Uri.parse('${ApiConfig.apiBaseUrl}$path');
    // Built fresh for every attempt: a MultipartRequest can be sent only
    // once, so the same object could never be retried.
    return _send(
      'POST',
      path,
      auth: auth,
      build: (headers) => http.MultipartRequest('POST', uri)
        ..headers.addAll(headers)
        ..files.add(
          http.MultipartFile.fromBytes(
            fieldName,
            bytes,
            filename: filename,
            // Without this, MultipartFile.fromBytes defaults to
            // application/octet-stream, which the backend's upload endpoint
            // rejects as "not an allowed image type" — regardless of what the
            // actual file extension/content is.
            contentType: contentType,
          ),
        ),
    );
  }

  /// Closes the HTTP client this instance created. Only for an instance of
  /// your own (e.g. a short-lived one in a test); never for [shared], which
  /// other code may be using.
  void close() {
    if (identical(this, _shared)) {
      throw StateError('ApiClient.shared is used by the whole app and is never closed.');
    }
    if (_ownsHttpClient) _http.close();
  }

  /// Sends one request and returns its decoded body.
  ///
  /// [build] makes the `http.BaseRequest` from the headers to send; it is
  /// called once per attempt, so every attempt is a brand-new request object
  /// (an `http.Request` or `MultipartRequest` cannot be sent twice). The
  /// default builds a JSON request from [body].
  ///
  /// Two kinds of retry, each at most once:
  ///   * a pure connection failure (not a timeout, not an HTTP error) — see
  ///     the comment in the loop;
  ///   * a 401 on a request that carried an access token: the token pair is
  ///     refreshed (see [_refreshTokens]) and the request is sent again with
  ///     the new token. A second 401, or a 401 on a request that had no
  ///     token, is reported to the caller as before.
  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    http.BaseRequest Function(Map<String, String> headers)? build,
  }) async {
    final uri = Uri.parse('${ApiConfig.apiBaseUrl}$path');
    final encodedBody = body == null ? null : jsonEncode(body);

    build ??= (headers) {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (encodedBody != null) request.body = encodedBody;
      return request;
    };

    var refreshed = false;
    while (true) {
      final headers = <String, String>{'Content-Type': 'application/json'};
      String? token;
      if (auth) {
        token = await _tokenStore.accessToken;
        if (token != null) headers['Authorization'] = 'Bearer $token';
      }

      final response = await _sendOnce(() => build!(headers));

      if (response.statusCode == 401 && token != null && !refreshed) {
        refreshed = true;
        if (await _refreshTokens(rejectedToken: token)) continue;
      }
      return _handleResponse(response);
    }
  }

  /// One attempt (plus the connection-failure retry) of a request.
  Future<http.Response> _sendOnce(http.BaseRequest Function() build) async {
    // One automatic retry on a pure connection failure (not a timeout, and
    // not an HTTP error response — those aren't retried). In practice this
    // papers over the split-second a local dev backend is unreachable
    // (e.g. uvicorn's --reload restarting after a file save), which
    // otherwise shows up as an intermittent, hard-to-reproduce "Could not
    // reach the server" error on actions like deleting a service.
    for (var attempt = 0; ; attempt++) {
      try {
        final streamed = await _http.send(build()).timeout(_timeout);
        return await http.Response.fromStream(streamed);
      } on TimeoutException {
        throw ApiException('استغرق السيرفر وقتاً طويلاً للرد، حاول مرة أخرى.');
      } on http.ClientException {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 600));
          continue;
        }
        throw ApiException(
          'تعذّر الوصول إلى السيرفر، تأكد من اتصالك بالإنترنت '
          'ومن أن السيرفر يعمل (${ApiConfig.baseUrl}).',
        );
      }
    }
  }

  /// Gets a new token pair for the stored refresh token. Returns true when
  /// the request that was refused with [rejectedToken] should be retried.
  ///
  /// Single flight: while one refresh runs, every other request that needs
  /// one waits for that same refresh instead of starting its own. A request
  /// whose 401 arrives after the refresh finished (the stored token is no
  /// longer the one it sent) just retries with the new token.
  Future<bool> _refreshTokens({required String rejectedToken}) async {
    if (await _tokenStore.accessToken != rejectedToken) {
      // Somebody already refreshed (or logged in/out) since this request
      // was sent: retry only if there is a token to retry with.
      return await _tokenStore.accessToken != null;
    }
    final inFlight = _refreshing;
    if (inFlight != null) return inFlight;
    final refresh = _doRefresh();
    _refreshing = refresh;
    try {
      return await refresh;
    } finally {
      _refreshing = null;
    }
  }

  /// `POST /auth/refresh`. Sent directly (not through [_send]), so it can
  /// never trigger a refresh of its own. Tokens are never logged or put
  /// into an exception message.
  Future<bool> _doRefresh() async {
    final refreshToken = await _tokenStore.refreshToken;
    if (refreshToken == null) return false;

    final http.Response response;
    try {
      response = await _sendOnce(
        () => http.Request('POST', Uri.parse('${ApiConfig.apiBaseUrl}/auth/refresh'))
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode({'refresh_token': refreshToken}),
      );
    } on ApiException {
      // The server could not be reached: nothing is known about the
      // session, so it is kept. The original request's 401 is reported.
      return false;
    }

    if (response.statusCode == 401) {
      // The refresh token itself is refused (expired, invalid, account
      // deactivated): the session is over.
      await _tokenStore.clear();
      onSessionExpired?.call();
      return false;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return false; // e.g. a 5xx: a server problem, not an expired session.
    }

    final decoded = _tryDecode(response.body);
    final access = decoded is Map ? decoded['access_token'] : null;
    final refresh = decoded is Map ? decoded['refresh_token'] : null;
    if (access is! String || access.isEmpty || refresh is! String || refresh.isEmpty) {
      return false; // never overwrite the stored tokens with something broken
    }
    // The backend rotates the refresh token: both are stored.
    await _tokenStore.saveTokens(accessToken: access, refreshToken: refresh);
    return true;
  }

  dynamic _handleResponse(http.Response response) {
    final status = response.statusCode;
    final hasBody = response.body.isNotEmpty;
    final decoded = hasBody ? _tryDecode(response.body) : null;

    if (status >= 200 && status < 300) {
      return decoded;
    }

    throw ApiException(_extractMessage(decoded), statusCode: status);
  }

  dynamic _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return body;
    }
  }

  /// Pulls a readable message out of the backend's error shape.
  /// Domain errors look like `{"detail": "...", "error_type": "..."}`.
  /// Pydantic validation errors look like `{"detail": [{"msg": "..."}]}`.
  String _extractMessage(dynamic decoded) {
    if (decoded is Map && decoded['detail'] != null) {
      final detail = decoded['detail'];
      if (detail is String) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] != null) {
          return first['msg'].toString();
        }
      }
    }
    return 'حدث خطأ ما، يرجى المحاولة مرة أخرى.';
  }
}
