import 'package:geolocator/geolocator.dart';

/// Why the device's location couldn't be obtained — lets a screen offer the
/// right way out (retry, open the location settings, open the app settings).
enum LocationFailure {
  /// Location services (GPS) are switched off on the device.
  serviceDisabled,

  /// The user declined the permission prompt (it can be asked again).
  permissionDenied,

  /// The permission is permanently denied: only the app settings can fix it.
  permissionDeniedForever,

  /// Permission is fine but no position could be read (timeout, no fix...).
  unavailable,
}

/// Raised when the device's location can't be obtained — service disabled,
/// permission denied, etc. Carries an Arabic message ready to show in the UI.
class LocationServiceException implements Exception {
  final String message;
  final LocationFailure reason;

  LocationServiceException(
    this.message, {
    this.reason = LocationFailure.unavailable,
  });

  @override
  String toString() => message;
}

/// Thin wrapper around the `geolocator` plugin: checks/requests permission
/// and returns the device's current position, or throws a
/// [LocationServiceException] with a message ready to show the user.
///
/// It always asks the device for a fresh fix: it never falls back to a
/// cached "last known" position or to made-up coordinates.
class LocationService {
  /// How long to wait for a fix before giving up with a clear message.
  static const Duration fixTimeout = Duration(seconds: 20);

  Future<Position> getCurrentPosition() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw LocationServiceException(
        'خدمة الموقع مطفية على جهازك. فعّلها من الإعدادات وحاول مرة ثانية.',
        reason: LocationFailure.serviceDisabled,
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw LocationServiceException(
          'لازم تسمح للتطبيق بالوصول لموقعك عشان يلاقي الخدمات القريبة منك.',
          reason: LocationFailure.permissionDenied,
        );
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw LocationServiceException(
        'صلاحية الموقع مرفوضة بشكل دائم. فعّلها يدويًا من إعدادات التطبيق '
        'ثم حاول مرة ثانية.',
        reason: LocationFailure.permissionDeniedForever,
      );
    }

    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // "high" (GPS) rather than "medium" (~100 m+, network based): the
          // nearby search ranks services by their exact distance.
          accuracy: LocationAccuracy.high,
          timeLimit: fixTimeout,
        ),
      );
    } on LocationServiceDisabledException {
      throw LocationServiceException(
        'خدمة الموقع مطفية على جهازك. فعّلها من الإعدادات وحاول مرة ثانية.',
        reason: LocationFailure.serviceDisabled,
      );
    } catch (_) {
      throw LocationServiceException(
        'تعذّر تحديد موقعك الحالي. تأكد من تشغيل الموقع ووجودك في مكان '
        'مفتوح، ثم حاول مرة ثانية.',
      );
    }
  }

  /// Opens the device's location settings (to switch location on).
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  /// Opens this app's settings page (to grant a permanently denied permission).
  Future<bool> openAppSettings() => Geolocator.openAppSettings();
}
