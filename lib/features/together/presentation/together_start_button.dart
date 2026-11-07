import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The floating Start button: the host's "go live" moment.
///
/// A gentle bob (never a frantic pulse) so it reads as alive without
/// shouting over the poster art, with a soft glow so it is findable at a
/// glance on a dark screen. Used on the Together tab while a room is
/// pending and over the player once the title is open.
class TogetherStartButton extends StatefulWidget {
  const TogetherStartButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  State<TogetherStartButton> createState() => _TogetherStartButtonState();
}

class _TogetherStartButtonState extends State<TogetherStartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _bob,
      builder: (context, child) {
        // -6..0 px of lift, eased: a float, not a bounce.
        final lift = -6.0 * (0.5 - 0.5 * math.cos(_bob.value * math.pi));
        return Transform.translate(offset: Offset(0, lift), child: child);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: colorScheme.primary.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: FilledButton.icon(
          onPressed: widget.onPressed,
          icon: const Icon(Icons.play_arrow_rounded, size: 26),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Start watching together',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
          ),
        ),
      ),
    );
  }
}
