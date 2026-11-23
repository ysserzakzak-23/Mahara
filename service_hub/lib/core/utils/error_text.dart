import '../api/api_exception.dart';
import '../location/location_service.dart';

/// Shown for an error that has no message meant for the user.
const String genericErrorText = 'حدث خطأ غير متوقع، يرجى المحاولة مرة أخرى.';

/// The text to show the user for [error].
///
/// The app's own exceptions already carry an Arabic message (the backend's
/// `detail`, or the location service's explanation) and it is shown as is.
/// Anything else — a parsing failure, a plugin error, a programming bug —
/// would otherwise print Dart's English description (e.g. "type 'Null' is
/// not a subtype of ..."), so it becomes [genericErrorText] instead.
String errorText(Object? error) {
  if (error is ApiException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  if (error is LocationServiceException && error.message.trim().isNotEmpty) {
    return error.message;
  }
  return genericErrorText;
}
