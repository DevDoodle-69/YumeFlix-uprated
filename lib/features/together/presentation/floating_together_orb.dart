import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/device_info_provider.dart';
import '../together_provider.dart';
import '../together_service.dart';

/// The floating "Enjoy Together" orb: the room, always within reach.
///
/// Appears the moment a room is created — while the host is still browsing,
/// not only once a video is playing — and stays up over home, browse and
/// (when the coordinator mounts it there) the player, until the room is
/// left. Glassmorphism (translucent + backdrop blur) with a breathing
/// pulse and a soft glow, draggable anywhere on screen.
///
/// The position is a screen fraction kept in [TogetherService] for the
/// session and persisted to SharedPreferences, so it survives rotation,
/// app restarts and different screen sizes.
///
/// Tap toggles the expanded card: live room status (a real MQTT fact),
/// the picked title, the room code with copy, who is in the room, and the
/// actions that make sense right now — Start (host, in the player),
/// Pick a title (host, while browsing), Chat (in the player) and Leave.
///
/// TV never sees it: [DeviceProfile.isTv] hides Together entirely, the
/// same rule that hides the 5th nav tab (`showTogether: !profile.isTv`).
///
/// Mount once per route that needs it, as a direct child of a [Stack]:
/// the coordinator mounts one in AppScaffold (home / browse) and one in
/// the player Stack (see the integration snippet in the 2.6.0 report).
/// Two mounts never exist at the same time — the player route sits above
/// the shell — so the orb is never doubled.
class FloatingTogetherOrb extends ConsumerStatefulWidget {
  const FloatingTogetherOrb({this.onStart, this.onOpenChat, super.key});

  /// Host going live from the player: `() => _togetherHook!.goLive()`.
  /// Null while browsing (there is no engine position to go live from),
  /// where the card offers "Pick a title" instead.
  final VoidCallback? onStart;

  /// Opening the glass chat panel over the player. Null while browsing,
  /// where there is no panel to open.
  final VoidCallback? onOpenChat;

  @override
  ConsumerState<FloatingTogetherOrb> createState() =>
      _FloatingTogetherOrbState();
}

class _FloatingTogetherOrbState extends ConsumerState<FloatingTogetherOrb>
    with SingleTickerProviderStateMixin {
  static const Offset _kDefaultFraction = Offset(0.72, 0.78);
  static const double _kCollapsedWidth = 212;
  static const double _kExpandedWidth = 300;

  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat(reverse: true);

  Offset _fraction = _kDefaultFraction;
  bool _expanded = false;
  bool _dragMoved = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final service = ref.read(togetherServiceProvider);
      await service.loadOrbPosition();
      if (!mounted) return;
      setState(() {
        _fraction = service.orbPositionFraction ?? _kDefaultFraction;
      });
    });
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  void _copyOtp(String otp) {
    Clipboard.setData(ClipboardData(text: otp));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room code copied — send it to your friend')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(togetherServiceProvider);
    final isTv =
        ref.watch(deviceProfileProvider).asData?.value.isTv ?? false;
    if (!service.isSessionActive || isTv) return const SizedBox.shrink();

    final size = MediaQuery.sizeOf(context);
    final width = _expanded ? _kExpandedWidth : _kCollapsedWidth;
    final left = (_fraction.dx * size.width)
        .clamp(8.0, math.max(8.0, size.width - width - 8.0))
        .toDouble();
    final top = (_fraction.dy * size.height)
        .clamp(64.0, math.max(64.0, size.height - (_expanded ? 340.0 : 150.0)))
        .toDouble();

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanStart: (_) => _dragMoved = false,
        onPanUpdate: (details) {
          if (details.delta.distance > 2) _dragMoved = true;
          setState(() {
            _fraction = Offset(
              (_fraction.dx + details.delta.dx / size.width).clamp(0.0, 1.0),
              (_fraction.dy + details.delta.dy / size.height).clamp(0.0, 1.0),
            );
          });
        },
        onPanEnd: (_) {
          ref.read(togetherServiceProvider).setOrbPosition(_fraction);
        },
        onTap: () {
          if (_dragMoved) return;
          setState(() => _expanded = !_expanded);
        },
        child: AnimatedBuilder(
          animation: _breathe,
          builder: (context, child) {
            // 1.00–1.04 scale + glow swell: breathing, never a frantic pulse.
            final t = 0.5 - 0.5 * math.cos(_breathe.value * math.pi);
            return Transform.scale(
              scale: 1.0 + 0.03 * t,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.28 + 0.18 * t),
                      blurRadius: 22,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: child,
              ),
            );
          },
          child: _expanded
              ? _expandedCard(context, service)
              : _collapsedPill(context, service),
        ),
      ),
    );
  }

  Widget _glass(BuildContext context, Widget child, {double radius = 28}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          decoration: BoxDecoration(
            color: colorScheme.surface.withValues(alpha: 0.68),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _collapsedPill(BuildContext context, TogetherService service) {
    final colorScheme = Theme.of(context).colorScheme;
    final isLive = service.isLive;
    final isGuestWaiting = service.phase == TogetherPhase.waitingGuest;
    final label = service.reconnecting
        ? 'Reconnecting…'
        : isLive
        ? '● LIVE'
        : isGuestWaiting
        ? 'Waiting for host…'
        : service.role == TogetherRole.host &&
                service.pendingMedia != null
        ? 'Ready to start'
        : 'Enjoy Together';
    return _glass(
      context,
      SizedBox(
        width: _kCollapsedWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.group_rounded,
                size: 22,
                color: isLive
                    ? colorScheme.primary
                    : colorScheme.onSurface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              if (isGuestWaiting) ...[
                const SizedBox(width: 6),
                const _WaitingDots(),
              ],
              if (service.chatHasUnread)
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withValues(alpha: 0.8),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expandedCard(BuildContext context, TogetherService service) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = service.currentMedia;
    final otp = service.otp ?? '';
    final isHost = service.role == TogetherRole.host;
    final isPendingHost =
        isHost && service.phase == TogetherPhase.pendingHost;
    final canStart = isPendingHost && media != null;
    return _glass(
      context,
      SizedBox(
        width: _kExpandedWidth,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.group_rounded, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Enjoy Together',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => setState(() => _expanded = false),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Live status: a real MQTT fact, never a local guess.
              Text(
                service.reconnecting
                    ? 'Reconnecting to the Together relay…'
                    : service.roomStatus.label,
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              if (media != null) ...[
                const SizedBox(height: 6),
                Text(
                  media.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                service.presenceLabel,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Room $otp',
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => _copyOtp(otp),
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (canStart && widget.onStart != null)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() => _expanded = false);
                      widget.onStart!.call();
                    },
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start together'),
                  ),
                )
              else if (canStart)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() => _expanded = false);
                      context.go('/search');
                    },
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Open the title to start'),
                  ),
                )
              else if (isPendingHost)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() => _expanded = false);
                      context.go('/search');
                    },
                    icon: const Icon(Icons.search_rounded),
                    label: const Text('Pick a title to watch'),
                  ),
                )
              else if (service.phase == TogetherPhase.waitingGuest)
                const Text(
                  'Playback starts automatically when the host presses Start.',
                  style: TextStyle(fontSize: 12),
                ),
              if (widget.onOpenChat != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _expanded = false);
                      widget.onOpenChat!.call();
                    },
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    label: const Text('Open chat'),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    setState(() => _expanded = false);
                    ref.read(togetherServiceProvider).leaveRoom();
                  },
                  child: const Text('Leave room'),
                ),
              ),
            ],
          ),
        ),
      ),
      radius: 20,
    );
  }
}

/// Three pulsing dots: the guest-waiting "still alive" signal on the pill.
class _WaitingDots extends StatefulWidget {
  const _WaitingDots();

  @override
  State<_WaitingDots> createState() => _WaitingDotsState();
}

class _WaitingDotsState extends State<_WaitingDots>
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
                padding: const EdgeInsets.only(right: 2),
                child: Opacity(
                  opacity:
                      0.35 +
                      0.65 *
                          (0.5 -
                              0.5 *
                                  math.cos(
                                    (_controller.value * 2 * math.pi) -
                                        (i * 2 * math.pi / 3),
                                  )),
                  child: Container(
                    width: 5,
                    height: 5,
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
