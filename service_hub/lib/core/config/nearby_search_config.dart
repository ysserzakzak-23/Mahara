/// Radius settings of the «خدمات قريبة مني» search, in one place.
///
/// Mirrors the backend (backend_updated/app/core/config.py):
/// NEARBY_DEFAULT_RADIUS_KM and NEARBY_MAX_RADIUS_KM. The backend enforces
/// the maximum; these values drive the radius slider.
class NearbySearchConfig {
  NearbySearchConfig._();

  static const double defaultRadiusKm = 25;
  static const double minRadiusKm = 1;
  static const double maxRadiusKm = 200;
}
