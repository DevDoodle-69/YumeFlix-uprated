import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A low-contrast, full-screen color wash driven by the current hero artwork.
/// It stays behind app content so navigation, cards, dialogs, and the TV shell
/// all share one evolving visual atmosphere without affecting interaction.
class ArtworkAmbience extends StatelessWidget {
  final Color? accent;
  final Widget child;

  const ArtworkAmbience({super.key, required this.accent, required this.child});

  @override
  Widget build(BuildContext context) {
    const fallback = Color(0xFF26346E);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: fallback, end: accent ?? fallback),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeInOutCubic,
      builder: (context, color, content) {
        final resolvedColor = color ?? fallback;
        final secondary = HSLColor.fromColor(resolvedColor)
            .withHue((HSLColor.fromColor(resolvedColor).hue + 42) % 360)
            .withSaturation(0.52)
            .withLightness(0.42)
            .toColor();
        final tertiary = HSLColor.fromColor(resolvedColor)
            .withHue((HSLColor.fromColor(resolvedColor).hue + 182) % 360)
            .withSaturation(0.38)
            .withLightness(0.34)
            .toColor();
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: RepaintBoundary(
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 72, sigmaY: 72),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.78, -0.82),
                        radius: 1.18,
                        colors: [
                          resolvedColor.withValues(alpha: 0.34),
                          resolvedColor.withValues(alpha: 0.14),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.42, 1.0],
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(0.86, 0.74),
                          radius: 1.2,
                          colors: [
                            secondary.withValues(alpha: 0.24),
                            secondary.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.48, 1.0],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.018),
                      tertiary.withValues(alpha: 0.055),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            content!,
          ],
        );
      },
      child: child,
    );
  }
}
