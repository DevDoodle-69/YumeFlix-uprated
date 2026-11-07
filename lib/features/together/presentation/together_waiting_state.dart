import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';

import '../together_service.dart';

/// The guest waiting state: a live screen, never a dead one.
///
/// A guest who joins with the OTP before the host has started anything
/// sees the host's real room status, pushed over MQTT — "Host is still
/// finding a movie…" while the host browses, "Host picked X" once a title
/// is chosen — with a static monochrome circle and pulsing dots so the
/// screen reads as alive, a waiting clock, and the room's presence line.
/// No breathing, no shadow.
///
/// Two failure states, both real (never a local guess):
/// * the host leaves ([TogetherService.hostGone], via `bye` / presence
///   `left`) — "Host left the room", playback carries on locally;
/// * nothing is heard from the host for 30 s ([TogetherService.waitingStale])
///   — "No signal from the host yet", with Retry / Leave. The host
///   publishes a status on create and a heartbeat every 2 s, so 30 s of
///   total silence means the relay or the host is gone, not slow browsing.
///
/// When the host presses Start, the retained state arrives and the service
/// flips to `live` — this widget unmounts and the player takes over.
class TogetherGuestWaitingState extends StatefulWidget {
  const TogetherGuestWaitingState({
    required this.service,
    required this.onRetry,
    required this.onLeave,
    super.key,
  });

  final TogetherService service;
  final VoidCallback onRetry;
  final VoidCallback onLeave;

  @override
  State<TogetherGuestWaitingState> createState() =>
      _TogetherGuestWaitingStateState();
}

class _TogetherGuestWaitingStateState
    extends State<TogetherGuestWaitingState> {
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    widget.service.addListener(_onServiceChanged);
    // The waiting clock ticks once a second; nothing else here needs it.
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    widget.service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  String _elapsed() {
    final since = widget.service.waitingSinceMs;
    if (since == null) return '';
    final seconds =
        (DateTime.now().millisecondsSinceEpoch - since) ~/ 1000;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return 'Waiting $minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final colorScheme = Theme.of(context).colorScheme;
    final media = service.currentMedia;
    final hostGone = service.hostGone;
    final stale = service.waitingStale;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Static monochrome circle: the waiting screen is calm, not a
        // spinner — no breathing, no shadow. The pulsing dots below are
        // the only motion.
        Center(
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: YumeDesign.surfaceRaised,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.16),
                width: 1,
              ),
            ),
            child: const Icon(
              Icons.group_rounded,
              size: 34,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (hostGone) ...[
          const Text(
            'Host left the room',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'You’re watching on your own now, from the last synced position. '
            'Ask the host for a new code to start again.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: widget.onLeave,
            child: const Text('Leave room'),
          ),
        ] else ...[
          Text(
            // The live status, straight off the wire.
            service.roomStatus.label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Center(child: _PulsingDots()),
          const SizedBox(height: 8),
          Text(
            _elapsed(),
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          if (media != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: YumeDesign.surfaceRaised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
              child: Row(
                children: [
                  if (media.posterUrl != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        media.posterUrl!,
                        width: 40,
                        height: 60,
                        fit: BoxFit.cover,
                        errorBuilder: (context, _, _) =>
                            const SizedBox(width: 40, height: 60),
                      ),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Host picked',
                          style: TextStyle(fontSize: 12),
                        ),
                        Text(
                          media.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (media.episodeLabel != null)
                          Text(media.episodeLabel!),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            service.presenceLabel,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Keep this screen open — playback starts automatically when '
            'the host presses Start.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12),
          ),
          if (stale) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.16),
                ),
              ),
              child: Column(
                children: [
                  const Text(
                    'No signal from the host yet',
                    style: TextStyle(fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Check the room code, or ask the host to re-open '
                    'Together — the relay may have dropped.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: widget.onRetry,
                          child: const Text('Retry'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: widget.onLeave,
                          child: const Text('Leave'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _PulsingDots extends StatefulWidget {
  const _PulsingDots();

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Opacity(
                  opacity:
                      0.3 +
                      0.7 *
                          (0.5 -
                              0.5 *
                                  math.cos(
                                    (_controller.value * 2 * math.pi) -
                                        (i * 2 * math.pi / 3),
                                  )),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
