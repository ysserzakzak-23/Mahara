/// Sizes for the photos users upload and for the photos the app displays.
///
/// Two separate problems:
///   * what is SENT — a camera photo is ~4000 px wide (12 MP); the app never
///     shows one larger than the screen, so uploading the original wastes
///     the user's data and the server's disk. See [maxUploadImageDimension].
///   * what is DECODED — a decoded image costs width x height x 4 bytes of
///     memory whatever size it is drawn at, so a 12 MP photo in a 50 px
///     thumbnail costs ~48 MB. See [decodePixels].
library;

import 'package:flutter/widgets.dart';

/// The longest edge, in pixels, of a photo uploaded from the app.
///
/// Passed to `ImagePicker.pickImage` as both `maxWidth` and `maxHeight`, so
/// the longest edge is capped and the aspect ratio is kept (the picker
/// scales by the side that needs it most). The picker never enlarges a
/// smaller photo, and copies the EXIF data, so orientation is preserved.
///
/// One cap for all three kinds of photo, because each is drawn at up to the
/// full width of the screen and the widest phone screen is ~1440 px:
///
///   * a service cover fills the width of the details screen (it is never
///     opened full screen, so the banner is its largest use);
///   * an avatar is a small circle in the app (110 px at most) BUT tapping
///     it opens [FullScreenImageViewer] — so it needs full-screen detail,
///     and shrinking it to "thumbnail size" would blur that view;
///   * a portfolio photo is a grid tile that also opens in that viewer.
///
/// 1600 px leaves ~11% headroom over the widest phone. Raising it would
/// only help zooming past ~1.1x in the viewer, and every grid tile
/// downloads the whole file (the backend stores one size, and `cacheWidth`
/// lowers decoding, not downloading), so a bigger cap makes browsing a
/// provider's work measurably slower to make zooming slightly sharper.
///
/// Worth revisiting if the backend ever stores several sizes per photo, or
/// if the app gets a tablet layout: a 12.9" iPad would want ~2048 px.
const int maxUploadImageDimension = 1600;

/// How many device pixels to decode for an image drawn [longestSide]
/// logical pixels long.
///
/// Used as `cacheWidth` (or the width of a [ResizeImage]): the other side
/// follows the image's own aspect ratio, so nothing is distorted, and
/// `allowUpscaling` stays false, so an image smaller than the box is left
/// at its own size rather than blown up.
///
/// The constraint is the box's LONGEST side, so a photo whose shape roughly
/// matches its box is decoded at about one image pixel per device pixel. A
/// photo whose shape is very different from its box (a wide panorama in a
/// square avatar, say) is cropped by `BoxFit.cover` and can end up slightly
/// soft; that is the trade for never decoding a distorted image.
int decodePixels(BuildContext context, double longestSide) =>
    (longestSide * MediaQuery.devicePixelRatioOf(context)).round();

/// A network image decoded no larger than it is drawn.
///
/// [longestSide] is the longest side of the box the image fills, in logical
/// pixels. For [Image.network] pass `cacheWidth: decodePixels(...)` instead:
/// it does the same thing.
ImageProvider sizedNetworkImage(
  BuildContext context,
  String url, {
  required double longestSide,
}) {
  return ResizeImage(
    NetworkImage(url),
    width: decodePixels(context, longestSide),
    // Leaves an image that is already smaller than the box alone.
    allowUpscaling: false,
  );
}
