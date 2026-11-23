/// Raised whenever the backend returns a non-2xx response or the request
/// cannot be completed (network down, timeout, etc.). Carries a human-readable
/// message suitable for showing in a SnackBar.
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}
