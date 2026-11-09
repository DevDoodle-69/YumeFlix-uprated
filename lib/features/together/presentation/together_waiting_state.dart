import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';

import '../connection.dart';
import '../models.dart';
import '../together_service.dart';
import 'floating_together_orb.dart' show TogetherRoomRemainingIndicator;

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
///   publishes a status on create and a heartbeat every 1 s, so 30 s of
///   total silence means the relay or the host is gone, not slow browsing.
///
/// A third state, also real: the relay itself drops while the room is
/// open ([TogetherService.reconnecting]) — "Connection lost —
/// reconnecting…", with the attempt count. The stale card stays hidden
/// while that runs: the reconnect loop is already retrying, and the
/// room re-syncs automatically when the relay answers.
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

class _TogetherGuestWaitingStateState extends State<TogetherGuestWaitingState> {
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
    final seconds = (DateTime.now().millisecondsSinceEpoch - since) ~/ 1000;
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return 'Waiting $minutes:${rest.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    // Guest only, at the widget itself — not just at the call site. A host
    // must never see "Host is still finding a movie…" about themselves:
    // the host's own screen already says "Waiting for your friend to join",
    // and this state rendered over it is the giant overlapping overlay the
    // host reported. Any caller that shows this widget to a host gets
    // nothing instead.
    if (service.role != TogetherRole.guest) {
      return const SizedBox.shrink();
    }
    final colorScheme = Theme.of(context).colorScheme;
    final media = service.currentMedia;
    final hostGone = service.hostGone;
    final stale = service.waitingStale;
    // A relay drop is not a host departure and not a dead room: while
    // the service retries the relay, the headline says so honestly —
    // "Connection lost — reconnecting…" — instead of the last known room
    // status, which is stale the moment the relay drops (it could still
    // say "Host is playing" while nothing is arriving). The reconnect
    // re-syncs automatically when the relay answers; nothing here asks
    // the guest to do anything.
    final reconnecting = service.reconnecting;

    // 2.12.0 LATE JOINER: a guest who joins a room that is ALREADY live
    // must never sit on the waiting screen. The join starts in
    // `waitingGuest` with the default `hostBrowsing` status, and only
    // the retained live state flips the phase to `live` — until it (or
    // the auto-open coordinator) arrives, the guest would otherwise
    // wait under the wrong copy, "Host is still finding a movie…".
    // Any live signal that HAS arrived proves the room is already live:
    // a live room status (`hostPlaying` / `hostPaused`, pushed by the
    // host in answer to this guest's presence `joined`) or an auto-open
    // already resolving (`guestAutoOpenPending`). While one of those
    // holds, this card yields to a proper loading state — never the
    // waiting text, never a blank screen — and the phase flip (or the
    // coordinator's open) takes over from there. The one window no
    // widget can distinguish is "no live signal has arrived yet",
    // which is genuinely indistinguishable from a browsing host: the
    // room's creation time alone cannot tell a live room from a
    // browsing one, and only the retained live state (or the host's
    // status answer to this guest's presence) proves it. The 30 s
    // stale card below is the honest fallback for that window.
    // Host-gone and reconnecting still win over this branch: a dead
    // room is not a joining room.
    final joiningLive =
        service.guestAutoOpenPending ||
        service.roomStatus == TogetherRoomStatus.hostPlaying ||
        service.roomStatus == TogetherRoomStatus.hostPaused;
    if (joiningLive && !hostGone && !reconnecting) {
      return MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: YumeDesign.accentLight,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Joining the live session…',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Opening the host’s title — playback starts automatically.',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: YumeDesign.textSecondary,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              service.presenceLabel,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
            if (service.roomEndsAtMs != null) ...[
              const SizedBox(height: 12),
              Center(
                child: TogetherRoomRemainingIndicator(
                  remaining: service.remainingTime,
                ),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: widget.onLeave,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 44),
              ),
              child: const Text('Leave room'),
            ),
          ],
        ),
      );
    }

    // Bounded by construction: the text scale is capped (a large system
    // font scale must not blow the waiting copy up past the card), every
    // line has an explicit small size in white/grey on dark — no red, no
    // yellow, no underline, no giant font — and every line that can grow
    // ellipsises instead of overflowing or overlapping the card below.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Column(
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'You’re watching on your own now, from the last synced position. '
              'Ask the host for a new code to start again.',
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: widget.onLeave,
              child: const Text('Leave room'),
            ),
          ] else ...[
            Text(
              // The live status, straight off the wire — or the honest
              // reconnecting line while the relay is down (never a stale
              // "Host is playing" over a dropped connection).
              reconnecting
                  ? 'Connection lost — reconnecting…'
                  : service.roomStatus.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
            const Center(child: _PulsingDots()),
            const SizedBox(height: 8),
            Text(
              _elapsed(),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
                decoration: TextDecoration.none,
              ),
            ),
            if (service.roomEndsAtMs != null) ...[
              const SizedBox(height: 12),
              Center(
                child: TogetherRoomRemainingIndicator(
                  remaining: service.remainingTime,
                ),
              ),
            ],
            if (reconnecting) ...[
              const SizedBox(height: 8),
              Text(
                'Attempt ${service.reconnectAttempt + 1} of '
                '$kTogetherMaxReconnectAttempts — the room re-syncs '
                'automatically when the relay answers.',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: YumeDesign.textSecondary,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          Text(
                            media.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              decoration: TextDecoration.none,
                            ),
                          ),
                          // One S/E line, never two: the title already
                          // ends with ` · S{n} E{n}` for a series episode.
                          if (media.episodeLabel != null &&
                              !media.titleCarriesEpisodeLabel)
                            Text(
                              media.episodeLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant,
                                decoration: TextDecoration.none,
                              ),
                            ),
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Keep this screen open — playback starts automatically when '
              'the host presses Start.',
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white70,
                decoration: TextDecoration.none,
              ),
            ),
            // The stale card stays hidden while a reconnect is already
            // running: its Retry would cancel the loop that is already
            // retrying, and "the relay may have dropped" is the wrong
            // copy for a drop the app is actively recovering from — the
            // reconnecting line above is the honest state instead.
            if (stale && !reconnecting) ...[
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
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        decoration: TextDecoration.none,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Check the room code, or ask the host to re-open '
                      'Together — the relay may have dropped.',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white70,
                        decoration: TextDecoration.none,
                      ),
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
      ),
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
