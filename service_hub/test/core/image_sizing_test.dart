// Image sizing (audit C2): what gets uploaded, and what gets decoded.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:service_hub/core/utils/image_sizing.dart';

/// Builds a context with a given device pixel ratio.
Future<BuildContext> contextWith(WidgetTester tester, double dpr) async {
  late BuildContext captured;
  await tester.pumpWidget(MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Builder(builder: (context) {
      captured = context;
      return const SizedBox();
    }),
  ));
  return captured;
}

/// What the picker does to a photo, from its documented rule: the longest
/// side is capped, the aspect ratio is kept, and a smaller photo is left
/// alone. Used here to check the cap we chose, not the plugin itself.
({int width, int height}) picked(int width, int height, {int cap = maxUploadImageDimension}) {
  if (width <= cap && height <= cap) return (width: width, height: height);
  final scale = cap / (width > height ? width : height);
  return (width: (width * scale).round(), height: (height * scale).round());
}

void main() {
  group('upload cap', () {
    test('is 1600 px, enough for a full-screen photo on a high-density phone', () {
      expect(maxUploadImageDimension, 1600);
      // A 3x phone 430 logical px wide shows 1290 px; the cap is above that.
      expect(maxUploadImageDimension, greaterThan(430 * 3));
    });

    test('a 12 MP camera photo is capped on its longest side', () {
      expect(picked(4000, 3000), (width: 1600, height: 1200));
      expect(picked(3000, 4000), (width: 1200, height: 1600));   // portrait
    });

    for (final (w, h) in [(4000, 3000), (3000, 4000), (4032, 3024), (2000, 1000)]) {
      test('the aspect ratio of ${w}x$h survives the cap', () {
        final out = picked(w, h);
        expect(out.width / out.height, closeTo(w / h, 0.01));
        expect(out.width <= maxUploadImageDimension, isTrue);
        expect(out.height <= maxUploadImageDimension, isTrue);
      });
    }

    for (final (w, h) in [(300, 168), (1134, 1134), (576, 1024), (1600, 1200)]) {
      test('a photo already within the cap (${w}x$h) is untouched', () {
        expect(picked(w, h), (width: w, height: h));     // never enlarged
      });
    }
  });

  group('decodePixels', () {
    testWidgets('scales the box by the device pixel ratio', (tester) async {
      final context = await contextWith(tester, 3);
      expect(decodePixels(context, 50), 150);
      expect(decodePixels(context, 110), 330);
    });

    testWidgets('follows the screen it is on', (tester) async {
      for (final (dpr, expected) in [(1.0, 50), (2.0, 100), (2.625, 131), (4.0, 200)]) {
        final context = await contextWith(tester, dpr);
        expect(decodePixels(context, 50), expected, reason: 'dpr $dpr');
      }
    });
  });

  group('sizedNetworkImage', () {
    testWidgets('decodes at the drawn size and never enlarges or distorts',
        (tester) async {
      final context = await contextWith(tester, 3);

      final provider = sizedNetworkImage(context, 'http://x/a.jpg', longestSide: 50)
          as ResizeImage;

      expect(provider.width, 150);
      // Only one side is constrained, so the other follows the image's own
      // shape: nothing is squashed.
      expect(provider.height, isNull);
      expect(provider.allowUpscaling, isFalse);
      expect((provider.imageProvider as NetworkImage).url, 'http://x/a.jpg');
    });

    testWidgets('two boxes of different sizes decode differently', (tester) async {
      final context = await contextWith(tester, 2);

      final thumbnail =
          sizedNetworkImage(context, 'http://x/a.jpg', longestSide: 50) as ResizeImage;
      final cover =
          sizedNetworkImage(context, 'http://x/a.jpg', longestSide: 390) as ResizeImage;

      expect(thumbnail.width, 100);
      expect(cover.width, 780);
    });

    testWidgets('the same URL and size is the same cache entry', (tester) async {
      final context = await contextWith(tester, 3);

      final first = sizedNetworkImage(context, 'http://x/a.jpg', longestSide: 50);
      final second = sizedNetworkImage(context, 'http://x/a.jpg', longestSide: 50);
      final other = sizedNetworkImage(context, 'http://x/b.jpg', longestSide: 50);

      // Flutter's image cache is keyed by the provider's equality, so the
      // same photo at the same size is fetched and decoded once...
      expect(first, second);
      // ...and a different photo (a replaced avatar has a new URL) is not
      // served from the old entry.
      expect(first, isNot(other));
    });
  });
}
