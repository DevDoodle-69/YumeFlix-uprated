import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// A cheap, slowly drifting ambient gradient sampled from the current
/// artwork accent.
///
/// Unlike [ArtworkAmbience] (the app-wide wash, which blurs two radial
/// gradients every frame), this one paints **two plain radial gradients**
/// whose centres drift on a 14 s loop via a single
/// [TweenAnimationBuilder] — no [ImageFilter], no per-frame blur, no
/// saveLayer. The drift is the only thing that animates, and it animates
/// alignment values, so the raster cost is one gradient repaint per frame
/// while the loop runs.
///
/// The accent comes from the hero artwork (see `extractArtworkAccent` in
/// `artwork_palette.dart`); when there is none yet, the brand violet fills
/// in so the screen never renders on a flat canvas.
class AmbientBackground extends StatelessWidget {
  final Color? accent;
  final Widget child;

  /// Set to false on screens that already sit on a photographic backdrop
  /// (details heroes) — the ambient layer is for list screens.
  final bool enabled;

  const AmbientBackground({
    super.key,
    required this.accent,
    required this.child,
    this.enabled = true,
  });

  static const Color _fallback = YumeDesign.violet;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(begin: _fallback, end: accent ?? _fallback),
      duration: const Duration(milliseconds: 1100),
      curve: Curves.easeInOutCubic,
      builder: (context, color, content) {
        final resolved = color ?? _fallback;
        final secondary = HSLColor.fromColor(resolved)
            .withHue((HSLColor.fromColor(resolved).hue + 42) % 360)
            .withSaturation(0.55)
            .withLightness(0.45)
            .toColor();
        final tertiary = HSLColor.fromColor(resolved)
            .withHue((HSLColor.fromColor(resolved).hue + 182) % 360)
            .withSaturation(0.40)
            .withLightness(0.35)
            .toColor();

        return _DriftingGradients(
          primary: resolved,
          secondary: secondary,
          tertiary: tertiary,
          child: content!,
        );
      },
      child: child,
    );
  }
}

/// The drifting layer: two radial gradients whose centres wander on a slow
/// loop, plus a faint diagonal wash. One [AnimationController], two
/// [AnimatedBuilder]s, and the gradients are the only thing repainted.
class _DriftingGradients extends StatefulWidget {
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Widget child;

  const _DriftingGradients({
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.child,
  });

  @override
  State<_DriftingGradients> createState() => _DriftingGradientsState();
}

class _DriftingGradientsState extends State<_DriftingGradients>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _drift;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: YumeDesign.ambientDuration,
    )..repeat(reverse: true);
    _drift = CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _drift,
      builder: (context, child) {
        // The drift is ±0.12 of the alignment range — enough to feel alive
        // on a 10 ft screen, small enough that the tint never slides off
        // the corner it belongs to.
        final t = _drift.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.78 + 0.12 * t, -0.82 + 0.10 * t),
                    radius: 1.18,
                    colors: [
                      widget.primary.withValues(
                        alpha: YumeDesign.ambientAlpha,
                      ),
                      widget.primary.withValues(alpha: 0.12),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.42, 1.0],
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment(0.86 - 0.12 * t, 0.74 - 0.10 * t),
                      radius: 1.2,
                      colors: [
                        widget.secondary.withValues(
                          alpha: YumeDesign.ambientAlphaSecondary,
                        ),
                        widget.secondary.withValues(alpha: 0.07),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.48, 1.0],
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
                      widget.tertiary.withValues(alpha: 0.05),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
            child!,
          ],
        );
      },
      child: widget.child,
    );
  }
}
