import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';
import '../together_service.dart';

/// The Live indicator for a Together watch party, in the player control
/// panel — the ONLY place a Live status renders (2.10.0, Bug 1).
///
/// The floating orb used to carry a "Live" pill above the router, and the
/// phase it read ([TogetherService.isLive]) is sticky: it flips to live
/// on Start and nothing flips it back except leaving the room, so the
/// pill stayed up on the home screen, the details screen and in the
/// player long after the user had left the player, paused, or lost the
/// host. That pill is gone. This chip renders only while
/// [TogetherService.isShowingLive] holds — live session, host present,
/// player open, shared title actually playing — and the player screen
/// passes null for its health the moment it stops holding, so the chip
/// unmounts instead of going stale.
///
/// A blinking dot + "Live": green ([TogetherLiveHealth.healthy]) while
/// every signal is inside budget, orange ([TogetherLiveHealth.degraded])
/// the moment the relay round-trip, the guest's drift or the host
/// heartbeat is not — see [TogetherService.liveHealth] for the
/// thresholds (RTT > 800 ms, drift > 750 ms, reconnecting, or no host
/// heartbeat for 3 s). The dot is decorative; the words carry the state,
/// so a screen reader hears "Live, connection healthy/degraded" and the
/// colour is never the only signal.
///
/// Accessibility (flutter-expert): the chip is at least 44 dp tall like
/// the icon buttons beside it, the text is never clipped by a fixed
/// height — the chip grows with the system text scale — and the label is
/// a real [Semantics] label, not colour alone. The blink is isolated in
/// a [RepaintBoundary] so it repaints only its own dot, never the row.
class TogetherLiveIndicator extends StatefulWidget {
  const TogetherLiveIndicator({required this.health, super.key});

  /// Health of the live session, from [TogetherService.liveHealth].
  final TogetherLiveHealth health;

  @override
  State<TogetherLiveIndicator> createState() => _TogetherLiveIndicatorState();
}

class _TogetherLiveIndicatorState extends State<TogetherLiveIndicator>
    with SingleTickerProviderStateMixin {
  /// Blinking green when healthy, blinking orange when degraded.
  ///
  /// Status colours, not the app accent: the brief requires green /
  /// orange here, and the dot is small, flat and halo-free, in keeping
  /// with the minimal palette everywhere else.
  static const Color _kHealthyDot = Color(0xFF4CAF50);
  static const Color _kDegradedDot = Color(0xFFED8A3C);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);
  late final Animation<double> _opacity = Tween<double>(
    begin: 1.0,
    end: 0.35,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final degraded = widget.health == TogetherLiveHealth.degraded;
    return Semantics(
      label: degraded
          ? 'Live, connection degraded'
          : 'Live, connection healthy',
      child: Tooltip(
        message: degraded
            ? 'Together live — connection degraded'
            : 'Together live',
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: YumeDesign.surfaceRaised,
            borderRadius: YumeDesign.pillRadius,
            border: Border.all(color: YumeDesign.hairlineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _opacity,
                  builder: (context, _) => Opacity(
                    opacity: _opacity.value,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: degraded ? _kDegradedDot : _kHealthyDot,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                'Live',
                style: TextStyle(
                  color: YumeDesign.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
