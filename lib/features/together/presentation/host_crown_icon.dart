/// The host crown, drawn as a vector — never an emoji character.
///
/// No icon font in the app ships a crown (neither Material nor Cupertino
/// Icons has one), so the crown is a small three-point [CustomPaint] path.
/// It renders identically on every device and font, and it keeps the
/// app's own UI free of emoji characters (2.12.0: no emojis anywhere in
/// the app UI). The host is identified as `HOST` + this icon everywhere
/// — member list, chat bubbles, room header — never by colour alone and
/// never by a crown emoji character in a string.
library;

import 'package:flutter/material.dart';

/// A small three-point crown, drawn in [color] at [size] dp square.
///
/// The path is a filled crown silhouette in a 24 x 24 box: three points
/// with the middle one tallest, and a flat base. [size] scales the whole
/// box; the painter draws in box coordinates so the shape stays crisp
/// at any size.
class HostCrownIcon extends StatelessWidget {
  const HostCrownIcon({required this.color, this.size = 14, super.key});

  /// The crown fill colour — usually the surrounding text colour.
  final Color color;

  /// The square side in dp.
  final double size;

  @override
  Widget build(BuildContext context) {
    // No child: the painter draws in the box the SizedBox sizes, so the
    // shape stays crisp at any size and never depends on font rendering.
    // Screen readers get the word from the HOST text next to the icon.
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CrownPainter(color)),
    );
  }
}

class _CrownPainter extends CustomPainter {
  _CrownPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final w = size.width;
    final h = size.height;
    // Three points: outer points at 1/6 and 5/6 of the width, the middle
    // point tallest, valleys between them, flat base.
    final path = Path()
      ..moveTo(w * 0.08, h * 0.82)
      ..lineTo(w * 0.08, h * 0.34)
      ..lineTo(w * 0.30, h * 0.55)
      ..lineTo(w * 0.50, h * 0.16)
      ..lineTo(w * 0.70, h * 0.55)
      ..lineTo(w * 0.92, h * 0.34)
      ..lineTo(w * 0.92, h * 0.82)
      ..close();
    canvas.drawPath(path, paint);
    // The base band, slightly separated from the points.
    canvas.drawRect(
      Rect.fromLTWH(w * 0.08, h * 0.86, w * 0.84, h * 0.08),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CrownPainter oldDelegate) => oldDelegate.color != color;
}

/// `HOST` + crown icon, as one inline label.
///
/// The text is plain `HOST` — the crown is the icon widget beside it,
/// never a character in the string. Used by the member list and the
/// chat bubbles so the two can never disagree about how the host reads.
class HostIdentityLabel extends StatelessWidget {
  const HostIdentityLabel({
    this.fontSize = 13,
    this.fontWeight = FontWeight.w700,
    this.color,
    this.iconSize = 13,
    super.key,
  });

  final double fontSize;
  final FontWeight fontWeight;
  final Color? color;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final textColor = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            'HOST',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              fontWeight: fontWeight,
            ),
          ),
        ),
        const SizedBox(width: 3),
        HostCrownIcon(color: textColor, size: iconSize),
      ],
    );
  }
}
