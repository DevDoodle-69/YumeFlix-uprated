import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';

/// The 2.6.0 section header — one header language for every rail on every
/// screen.
///
/// Title in bold, a short gradient underline in the accent ramp, and an
/// optional trailing action (a "View all" pill, a clear button, arrows).
/// The old per-widget headers each drew their own 20–30 dp blue bar under
/// the title; the gradient underline replaces all of them.
///
/// [StaggeredEntrance] is the cheap entrance used by rails: a one-shot
/// fade + 12 dp rise, staggered by [YumeDesign.staggerStep] per index and
/// capped at [YumeDesign.staggerMaxItems] so long rails stop animating
/// after the first screenful. It is a single [TweenAnimationBuilder] per
/// item, it runs once, and it never rebuilds the list.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool isLarge;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.isLarge = false,
  });

  /// The "View all" pill used by rails. Kept here so every rail's trailing
  /// action looks identical.
  static Widget viewAllPill({
    required String label,
    required VoidCallback onTap,
  }) {
    return _ViewAllPill(label: label, onTap: onTap);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isLarge
                ? YumeDesign.sectionTitleSizeLarge
                : YumeDesign.sectionTitleSize,
            fontWeight: FontWeight.w800,
            color: theme.colorScheme.onSurface,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 5),
        Container(
          width: 28,
          height: 3,
          decoration: BoxDecoration(
            gradient: YumeDesign.accentGradient,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: YumeDesign.captionSize,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: titleWidget),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          trailing!,
        ],
      ],
    );

    if (onTap == null) return header;
    return GestureDetector(onTap: onTap, child: header);
  }
}

class _ViewAllPill extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _ViewAllPill({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: YumeDesign.pillRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            borderRadius: YumeDesign.pillRadius,
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.10),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 10,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-shot staggered entrance for rail items and section headers.
///
/// Fades in and rises 12 dp over 420 ms, delayed [index] × 45 ms, capped
/// so items past the eighth appear immediately. Cheap by design: one
/// [TweenAnimationBuilder] per item, no controller to dispose, no rebuild
/// after the entrance finishes.
class StaggeredEntrance extends StatelessWidget {
  final int index;
  final Widget child;

  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final capped = index.clamp(0, YumeDesign.staggerMaxItems);
    final delay = YumeDesign.staggerStep * capped;
    final total = YumeDesign.entranceDuration + delay;
    // Linear time base: `value` is elapsed/total, so the delay is a real
    // hold at the start rather than a slower animation. Easing is applied
    // to the post-delay progress below.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total,
      builder: (context, value, child) {
        final elapsed = value * total.inMilliseconds;
        final raw = ((elapsed - delay.inMilliseconds) /
                YumeDesign.entranceDuration.inMilliseconds)
            .clamp(0.0, 1.0);
        // easeOutCubic applied by hand (the builder's curve is linear).
        final t = 1 - (1 - raw) * (1 - raw) * (1 - raw);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
