/// A distance in kilometres, the way the app shows it in Arabic:
///   * under 1 km  -> metres, rounded to 10 m ("500 متر", "80 متر");
///   * under 10 km -> one decimal, without a trailing ".0" ("1.2 كم", "3 كم");
///   * otherwise   -> whole kilometres ("12 كم").
String formatDistance(double km) {
  if (km < 0 || km.isNaN) km = 0;
  if (km < 1) {
    final metres = (km * 1000 / 10).round() * 10;
    if (metres >= 1000) return '1 كم';
    return '${metres < 10 ? 10 : metres} متر';
  }
  if (km < 10) {
    final rounded = (km * 10).round() / 10;
    if (rounded >= 10) return '10 كم';
    final text = rounded == rounded.roundToDouble()
        ? rounded.toStringAsFixed(0)
        : rounded.toStringAsFixed(1);
    return '$text كم';
  }
  return '${km.round()} كم';
}
