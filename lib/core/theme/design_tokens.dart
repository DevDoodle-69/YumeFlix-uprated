import 'package:flutter/material.dart';

/// YumeFlix 2.7.0 design tokens — the single source of truth for the
/// minimal visual language.
///
/// Near-black charcoal neutrals, white and grey text, hairline borders,
/// and ONE restrained muted accent (a desaturated slate-blue). No
/// gradients with colour stops, no coloured halo, no neon anywhere:
/// every screen reads its colours, radii, spacing and type from here
/// (via [AppTheme]) instead of inventing its own numbers.
///
/// What this replaced (2.6.0 "liquid glass over deep space"): a violet
/// → teal → rose gradient ramp, amber ratings, poster-sampled colour
/// colour washes and luminous accents. All of that is gone — the canvas
/// stays one neutral colour, artwork supplies the only colour on screen.
class YumeDesign {
  YumeDesign._();

  // ── Canvas ──────────────────────────────────────────────────────────
  /// Near-black charcoal canvas. One dark canvas for the whole app.
  static const Color background = Color(0xFF0B0D10);
  static const Color surface = Color(0xFF111417);
  static const Color surfaceRaised = Color(0xFF181C21);
  static const Color surfaceHighest = Color(0xFF21262D);

  // ── Accent ──────────────────────────────────────────────────────────
  /// The single restrained accent: desaturated slate-blue/grey. No halo,
  /// no gradient. Used sparingly — primary actions and active states
  /// only; everything else is white, grey or a hairline border.
  static const Color accent = Color(0xFF6B84A0);

  /// Lighter slate-blue for small text and icons on the dark canvas,
  /// where the fill accent would be too dark to read as a colour.
  static const Color accentLight = Color(0xFF8AA0B8);

  /// Muted accent fill for selected / active surfaces (e.g. a selected
  /// chip or progress fill). Flat colour, never a gradient.
  static const Color accentFill = Color(0xFF6B84A0);

  // ── Text ────────────────────────────────────────────────────────────
  static const Color textPrimary = Color(0xFFF2F4F7);
  static const Color textSecondary = Color(0xFF9AA3AD);
  static const Color textMuted = Color(0xFF6E7781);

  // ── Hairlines ───────────────────────────────────────────────────────
  /// Hairline border: white at low opacity, on any surface.
  static const Color hairline = Color(0x1AFFFFFF); // white 10%
  static const Color hairlineStrong = Color(0x29FFFFFF); // white 16%

  // ── Glass ───────────────────────────────────────────────────────────
  /// Fill for a glass panel over artwork. Neutral and restrained: low
  /// blur, no coloured halo, only where it aids readability over artwork.
  static const Color glassFill = Color(0x14FFFFFF); // white 8%
  static const Color glassFillStrong = Color(0x1FFFFFFF); // white 12%
  static const Color glassFillDark = Color(0x660B0D10); // canvas 40%

  /// Hairline border for glass panels.
  static const Color glassBorder = Color(0x1FFFFFFF); // white 12%
  static const Color glassBorderStrong = Color(0x33FFFFFF); // white 20%

  /// The soft shadow a glass panel casts on the canvas. Plain black —
  /// never a coloured halo.
  static List<BoxShadow> glassShadow({double blur = 16, double y = 6}) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.35),
      blurRadius: blur,
      offset: Offset(0, y),
    ),
  ];

  /// Neutral black scrim for text legibility over artwork: transparent
  /// to near-black. The only gradient allowed in the app, and it is
  /// monochrome by construction.
  static const LinearGradient legibilityScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Colors.transparent, Colors.black87],
    stops: [0.0, 1.0],
  );

  // ── Radii ───────────────────────────────────────────────────────────
  /// One card language, restrained: cards 16 dp, small cards 12 dp,
  /// panels 20 dp, controls 10 dp, chips 8 dp, pills fully round.
  static const double radiusCard = 16;
  static const double radiusCardSmall = 12;
  static const double radiusPanel = 20;
  static const double radiusControl = 10;
  static const double radiusPill = 999;
  static const double radiusChip = 8;

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
  /// Card widths for the cinematic poster card. The rail keeps the same
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
}
