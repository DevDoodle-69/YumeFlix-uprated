import 'package:flutter/material.dart';

/// YumeFlix 2.6.0 design tokens — the single source of truth for the new
/// visual language.
///
/// "Liquid glass over deep space": a near-black indigo canvas, one vibrant
/// gradient ramp (violet → teal → rose), translucent glass surfaces with a
/// soft top-edge highlight, and large, consistent radii. Every screen in the
/// app reads its colours, radii, spacing and type from here (via
/// [AppTheme]) instead of inventing its own numbers.
class YumeDesign {
  YumeDesign._();

  // ── Canvas ──────────────────────────────────────────────────────────
  /// Deep-space canvas — darker than the 2.5.0 midnight indigo so poster
  /// artwork and glass panels carry the colour instead of the background.
  static const Color background = Color(0xFF070A14);
  static const Color surface = Color(0xFF0E1322);
  static const Color surfaceRaised = Color(0xFF151B30);
  static const Color surfaceHighest = Color(0xFF1D2440);

  // ── Gradient accents ────────────────────────────────────────────────
  /// Hero violet — the primary accent of the 2.6.0 ramp.
  static const Color violet = Color(0xFF8B7CFF);
  static const Color violetDeep = Color(0xFF5B4FE8);

  /// Teal — the cool end of the ramp, used for secondary accents and the
  /// "watched / synced" states.
  static const Color teal = Color(0xFF4FD1C5);
  static const Color tealDeep = Color(0xFF2AA79E);

  /// Rose — the warm end of the ramp, used sparingly (LIVE, errors, the
  /// tail of the hero gradient).
  static const Color rose = Color(0xFFFF6B8A);
  static const Color amber = Color(0xFFFFC24B);

  /// The brand ramp, in order. Used for section underlines, progress fills,
  /// focus glows and the ambient background.
  static const List<Color> accentRamp = [violet, teal, rose];

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: accentRamp,
  );

  static const LinearGradient accentGradientVertical = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [violet, violetDeep],
  );

  // ── Text ────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFF4F6FF);
  static const Color textSecondary = Color(0xFFB9C0D8);
  static const Color textMuted = Color(0xFF7B8393);

  // ── Glass ───────────────────────────────────────────────────────────
  /// Fill for a glass panel over artwork or the ambient background.
  /// Kept translucent so the artwork behind stays visible; the top-edge
  /// highlight in [glassBorder] is what sells the "glass" read, not opacity.
  static const Color glassFill = Color(0x26FFFFFF); // white 15%
  static const Color glassFillStrong = Color(0x33FFFFFF); // white 20%
  static const Color glassFillDark = Color(0x400A0E1E); // dark 25%

  /// A glass border is two tones in one: a brighter top/left edge and a
  /// dimmer bottom/right edge. [GlassCard] paints it as a single
  /// [BorderSide] plus a top highlight gradient; the single-side colour
  /// here is the fallback for plain [Container] borders.
  static const Color glassBorder = Color(0x33FFFFFF); // white 20%
  static const Color glassBorderStrong = Color(0x59FFFFFF); // white 35%

  /// The soft shadow a glass panel casts on the canvas.
  static List<BoxShadow> glassShadow({double blur = 24, double y = 8}) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: blur,
      offset: Offset(0, y),
    ),
  ];

  // ── Radii ───────────────────────────────────────────────────────────
  /// One card language: posters and large panels share [radiusCard];
  /// chips and pills share [radiusPill]; small controls use [radiusControl].
  static const double radiusCard = 22;
  static const double radiusCardSmall = 16;
  static const double radiusPanel = 28;
  static const double radiusControl = 12;
  static const double radiusPill = 999;
  static const double radiusChip = 10;

  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(radiusCard),
  );
  static const BorderRadius cardSmallRadius = BorderRadius.all(
    Radius.circular(radiusCardSmall),
  );
  static const BorderRadius panelRadius = BorderRadius.all(
    Radius.circular(radiusPanel),
  );
  static const BorderRadius pillRadius = BorderRadius.all(
    Radius.circular(radiusPill),
  );

  // ── Spacing (4 dp base scale) ───────────────────────────────────────
  static const double space2 = 4;
  static const double space4 = 8;
  static const double space6 = 12;
  static const double space8 = 16;
  static const double space10 = 20;
  static const double space12 = 24;
  static const double space16 = 32;
  static const double space20 = 40;
  static const double space24 = 48;

  /// Horizontal page inset (phone) and rail inset (widescreen), matching
  /// [LayoutConstants] so existing layout code stays in rhythm.
  static const double pageInset = 16;
  static const double railInset = 24;

  /// Gap between sections on a screen.
  static const double sectionGap = 24;

  /// Gap between cards in a horizontal rail.
  static const double railGap = 12;
  static const double railGapLarge = 16;

  // ── Poster cards ────────────────────────────────────────────────────
  /// Card widths for the new cinematic poster card. The rail keeps the same
  /// footprint as 2.5.0 so list heights and scroll math do not change.
  static const double posterWidthPhone = 132;
  static const double posterWidthLarge = 200;
  static const double backdropWidthPhone = 200;
  static const double backdropWidthLarge = 300;

  /// Focus / press scale. TV gets the larger lift (the card is the whole
  /// focus affordance from a sofa); touch gets the smaller one.
  static const double focusScaleTv = 1.08;
  static const double focusScaleTouch = 1.05;

  // ── Type scale (Outfit, as before) ──────────────────────────────────
  static const double displaySize = 34;
  static const double headlineSize = 24;
  static const double sectionTitleSize = 20;
  static const double sectionTitleSizeLarge = 24;
  static const double titleSize = 16;
  static const double bodySize = 15;
  static const double captionSize = 12;
  static const double overlineSize = 11;

  /// Letter-spacing for the small-caps section overlines and chip labels.
  static const double overlineTracking = 1.2;

  // ── Motion ──────────────────────────────────────────────────────────
  /// Staggered entrance: each rail item waits [staggerStep] longer than the
  /// previous one, capped at [staggerMaxItems] so a long rail does not keep
  /// animating after the user has scrolled past it.
  static const Duration staggerStep = Duration(milliseconds: 45);
  static const int staggerMaxItems = 8;
  static const Duration entranceDuration = Duration(milliseconds: 420);
  static const Duration ambientDuration = Duration(seconds: 14);

  // ── Ambient background ──────────────────────────────────────────────
  /// Alpha of the drifting colour blobs. Low on purpose: the ambient layer
  /// tints the canvas, it never competes with the poster on top of it.
  static const double ambientAlpha = 0.30;
  static const double ambientAlphaSecondary = 0.20;
}
