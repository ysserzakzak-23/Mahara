import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:service_hub/core/location/location_service.dart';

/// A valid 1x1 PNG (a broken image would make Flutter report a decode error).
final Uint8List kPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

XFile fakeImageFile({String name = 'photo.png'}) =>
    XFile.fromData(kPngBytes, name: name, mimeType: 'image/png');

/// Stands in for the gallery. Returns [next] (null = the user cancelled).
class FakeImagePicker implements ImagePicker {
  FakeImagePicker([this.next]);

  XFile? next;
  int calls = 0;

  /// The named arguments of the last `pickImage` call, so a test can check
  /// the size limits the screen asked the gallery for.
  Map<Symbol, dynamic> lastPickImage = const {};

  double? get maxWidth => lastPickImage[#maxWidth] as double?;
  double? get maxHeight => lastPickImage[#maxHeight] as double?;
  int? get imageQuality => lastPickImage[#imageQuality] as int?;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #pickImage) {
      calls++;
      lastPickImage = Map<Symbol, dynamic>.from(invocation.namedArguments);
      return Future<XFile?>.value(next);
    }
    return super.noSuchMethod(invocation);
  }
}

Position fakePosition({double lat = 33.5, double lon = 36.3}) => Position(
      longitude: lon,
      latitude: lat,
      timestamp: DateTime(2026, 10, 5),
      accuracy: 1,
      altitude: 0,
      altitudeAccuracy: 1,
      heading: 0,
      headingAccuracy: 1,
      speed: 0,
      speedAccuracy: 1,
    );

/// Stands in for GPS. Set [error] to make it fail, [gate] to make it wait.
class FakeLocationService extends LocationService {
  FakeLocationService({this.error, this.gate, Position? position})
      : position = position ?? fakePosition();

  Object? error;
  Completer<void>? gate;
  Position position;
  int calls = 0;
  int locationSettingsOpened = 0;
  int appSettingsOpened = 0;

  @override
  Future<Position> getCurrentPosition() async {
    calls++;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return position;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsOpened++;
    return true;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened++;
    return true;
  }
}
