import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// The 2.7.0 glass primitives. One card language for the whole app:
///
/// * [GlassCard] — a neutral translucent panel with a hairline border
///   and a gentle black shadow. The blur is deliberately small
///   ([sigma] defaults to 10) and the widget is wrapped in a
///   [RepaintBoundary] by callers that sit over animated content; glass is
///   used for panels and chips, never as a full-screen backdrop, and never
///   with a coloured tint or halo.
/// * [GlassChip] — the single chip language: icon + label in a pill, in
///   monochrome neutral glass. No amber, no coloured badges.
/// * [GlassIconButton] — the single round icon-button language for headers.
///
/// All three are pure decoration over the caller's child — they own no
/// navigation, no focus handling and no data. Focus/scale behaviour stays
/// in [CardsWrapper] where it already lives.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final BorderRadius? borderRadius;
  final Color? fill;
  final double sigma;
  final bool showTopHighlight;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.fill,
    this.sigma = 10,
    // Kept for call-site compatibility; the top highlight gradient is
    // gone in 2.7.0 — glass is flat neutral, no highlight wash.
    this.showTopHighlight = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? YumeDesign.cardRadius;
    final content = ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: fill ?? YumeDesign.glassFill,
            borderRadius: radius,
            border: Border.all(
              color: YumeDesign.glassBorder,
              width: 1,
            ),
            // 2.7.0: flat neutral glass — no top-highlight gradient.
            boxShadow: YumeDesign.glassShadow(),
          ),
          child: child,
        ),
      ),
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: content,
      ),
    );
  }
}

/// One chip language for the whole app: a monochrome neutral-glass pill
/// with an optional leading icon. Used for ratings, years, durations,
/// types, providers and filter states — everywhere a small labelled badge
/// used to be a one-off [Container]. The optional [accent] is the single
/// muted slate-blue accent, used sparingly; the default is plain white
/// on neutral glass.
class GlassChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? accent;
  final bool filled;
  final TextStyle? labelStyle;
  final EdgeInsetsGeometry? padding;

  const GlassChip({
    super.key,
    required this.label,
    this.icon,
    this.accent,
    this.filled = false,
    this.labelStyle,
    this.padding,
  });

  /// Accent chip: the single muted slate-blue accent, filled. Use for
  /// the "primary" chip in a row (type, provider) so one chip leads.
  factory GlassChip.accent(
    String label, {
    Key? key,
    IconData? icon,
    Color accent = YumeDesign.accent,
  }) {
    return GlassChip(
      key: key,
      label: label,
      icon: icon,
      accent: accent,
      filled: true,
    );
  }

  /// A rating chip: white star + value, e.g. "8.4", in neutral glass.
  /// No amber, no coloured badge.
  factory GlassChip.rating(String value, {Key? key}) {
    return GlassChip(key: key, label: value, icon: Icons.star_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final tint = accent ?? Colors.white;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: YumeDesign.pillRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding:
              padding ??
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: filled
                ? tint.withValues(alpha: isDark ? 0.22 : 0.16)
                : Colors.black.withValues(alpha: 0.45),
            borderRadius: YumeDesign.pillRadius,
            border: Border.all(
              color: filled
                  ? tint.withValues(alpha: 0.45)
                  : Colors.white.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 11, color: tint),
                const SizedBox(width: 3),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    labelStyle ??
                    TextStyle(
                      color: filled ? tint : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The single round icon-button language for header bars: a 36 dp glass
/// circle with a centred icon. Replaces the assorted `CircleAvatar` +
/// `surfaceContainerHighest` buttons that used to differ per screen.
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool highlighted;
  final double size;

  /// When false the button renders dimmed and does not respond to taps
  /// (e.g. carousel arrows with no carousel loaded yet).
  final bool enabled;

  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.tooltip,
    this.highlighted = false,
    this.size = 36,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = ClipOval(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: highlighted
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.08),
            border: Border.all(
              color: highlighted
                  ? theme.colorScheme.primary
                  : Colors.white.withValues(alpha: 0.14),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            size: 18,
            color: highlighted
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );

    final tappable = Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.35,
          child: button,
        ),
      ),
    );

    if (tooltip == null) return tappable;
    return Tooltip(message: tooltip, child: tappable);
  }
}
