import 'package:flutter/material.dart';

/// A small white "chat bubble with a phone" glyph, built from plain
/// Material widgets — no icon-font dependency needed. Meant to sit on a
/// WhatsApp-green button so it reads as "message on WhatsApp" at a glance.
///
/// (Not using the `font_awesome_flutter` package here: its currently
/// published version subclasses Flutter's `IconData`, which recent Flutter
/// versions made a `final` class — so that package fails to compile against
/// an up-to-date Flutter SDK until it's updated upstream.)
class WhatsAppGlyph extends StatelessWidget {
  final double size;
  final Color bubbleColor;
  final Color phoneColor;

  const WhatsAppGlyph({
    super.key,
    this.size = 22,
    this.bubbleColor = Colors.white,
    this.phoneColor = const Color(0xFF25D366),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(size / 2),
          topRight: Radius.circular(size / 2),
          bottomRight: Radius.circular(size / 2),
          bottomLeft: Radius.circular(size / 6),
        ),
      ),
      child: Icon(Icons.phone, size: size * 0.6, color: phoneColor),
    );
  }
}
