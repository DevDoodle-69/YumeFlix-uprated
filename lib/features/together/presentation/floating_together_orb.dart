import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/device_info_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../together_provider.dart';
import '../together_service.dart';
import 'together_start_button.dart';

/// The floating "Enjoy Together" orb: the room, always within reach.
///
/// Mounted ONCE, above the router (see `main.dart`), so it is visible the
/// whole time a room is active — while the host searches, browses, opens
/// details and picks a title, and in the player — and survives every route
/// push, including the details / view-all routes that sit outside the app
/// shell. It appears the moment a room is created and stays up until the
/// room is left. A minimal monochrome glass pill (translucent + backdrop
/// blur, hairline border, no halo, no pulse), draggable anywhere on screen.
/// The only motion is a subtle scale on press.
///
/// Start-button state machine (2.8.0) — decided in one place, the service
/// ([TogetherService.startState]), never here:
///
/// * browsing — the room is open but nothing is playing yet: the orb is
///   ONLY the small neutral pill ("Enjoy Together"). There is no
///   "Ready to start" text anywhere, never a start prompt over
///   non-player screens, and never while the movie is paused.
/// * ready — the host picked a title, a player is open, and the movie is
///   actually playing: the pill becomes the compact Start run button
///   (dark pill, slate-blue play icon, white "Start", no red, no
///   underline, no glow). Tapping it goes live at once.
/// * live — the Start button is gone, replaced by the tiny Live indicator
///   (slate-blue dot + "Live"). It never reappears while live.
/// * leaving the player without going live, or pausing, drops the state
///   back to browsing; Start returns only when playback resumes.
///
/// Start and chat come from the player while one is open: the player hook
/// registers its `goLive` and the player screen its open-chat action on
/// the service ([TogetherService.orbStartAction] /
/// [TogetherService.orbOpenChatAction]), and the orb reads them here. With
/// no player open there is no Start at all — the orb never falls back to
/// opening a title to start.
///
/// The position is a screen fraction kept in [TogetherService] for the
/// session and persisted to SharedPreferences, so it survives rotation,
/// app restarts and different screen sizes.
///
/// Tap toggles the expanded card, EXCEPT while ready, where a tap is the
/// Start itself: live room status (a real MQTT fact), the picked title,
/// the room code with copy, who is in the room, and the actions that make
/// sense right now — Start (host, in the player, while playing), Pick a
/// title (host, while browsing), Chat (in the player) and Leave.
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

  /// Host going live from the player. Normally null: the player hook
  /// registers its `goLive` on the service while a player is open and the
  /// orb prefers that. A non-null value here overrides it (used by tests
  /// and by any direct mount).
  final VoidCallback? onStart;

  /// Opening the glass chat panel over the player. Normally null: the
  /// player screen registers its open-chat action on the service while a
  /// player is open and the orb prefers that.
  final VoidCallback? onOpenChat;

  @override
  ConsumerState<FloatingTogetherOrb> createState() =>
      _FloatingTogetherOrbState();
}

class _FloatingTogetherOrbState extends ConsumerState<FloatingTogetherOrb> {
  static const Offset _kDefaultFraction = Offset(0.72, 0.78);
  static const double _kCollapsedWidth = 212;
  static const double _kExpandedWidth = 300;

  Offset _fraction = _kDefaultFraction;
  bool _expanded = false;
  bool _dragMoved = false;
  bool _pressed = false;

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
    // The ready / live pills are compact run / status chips, much
    // narrower than the browsing pill — the drag clamp uses the width
    // actually rendered, so a narrow pill can still reach the screen edge.
    final collapsedWidth = switch (service.startState) {
      TogetherStartState.ready => 104.0,
      TogetherStartState.live => 92.0,
      _ => _kCollapsedWidth,
    };
    final width = _expanded ? _kExpandedWidth : collapsedWidth;
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
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: () {
          if (_dragMoved) return;
          // Ready: the collapsed pill IS the Start button — a tap goes
          // live at once instead of opening the card. goLive flips the
          // phase to live synchronously, so the button vanishes in the
          // same rebuild and the Live indicator takes its place.
          if (!_expanded &&
              service.startState == TogetherStartState.ready) {
            final onStart = widget.onStart ?? service.orbStartAction;
            onStart?.call();
            return;
          }
          setState(() => _expanded = !_expanded);
        },
        // 2.7.0: no breathing pulse, no halo — a subtle press scale only,
        // over a plain black drop shadow from the glass itself.
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: _expanded
              ? _expandedCard(context, service)
              : _collapsedPill(context, service),
        ),
      ),
    );
  }

  Widget _glass(BuildContext context, Widget child, {double radius = 16}) {
    final colorScheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _collapsedPill(BuildContext context, TogetherService service) {
    // Ready and live get their own compact pills below; browsing /
    // reconnecting / waiting share the neutral pill. There is deliberately
    // no "Ready to start" state anywhere: while browsing the orb is only
    // ever the neutral pill, and Start appears only as the run button,
    // only while the movie is playing.
    switch (service.startState) {
      case TogetherStartState.ready:
        return _startRunPill();
      case TogetherStartState.live:
        return _livePill();
      case TogetherStartState.hidden:
      case TogetherStartState.browsing:
        break;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final isGuestWaiting = service.phase == TogetherPhase.waitingGuest;
    final label = service.reconnecting
        ? 'Reconnecting…'
        : isGuestWaiting
        ? 'Waiting for host…'
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
                color: colorScheme.onSurface,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: YumeDesign.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    decoration: TextDecoration.none,
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
                    border: Border.all(color: Colors.black, width: 1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The compact Start run button (2.8.0): a small dark pill — raised
  /// near-black fill, hairline border, muted slate-blue play icon, white
  /// 13 pt "Start". No red, no underline, no glow. The tap itself is
  /// handled by the outer [GestureDetector] (a tap while ready goes live
  /// instead of expanding), so this is display only — no nested button
  /// to fight the drag recogniser.
  Widget _startRunPill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: YumeDesign.surfaceRaised,
        borderRadius: YumeDesign.pillRadius,
        border: Border.all(color: YumeDesign.hairlineStrong),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_arrow_rounded,
            size: 18,
            color: YumeDesign.accentLight,
          ),
          SizedBox(width: 6),
          Text(
            'Start',
            style: TextStyle(
              color: YumeDesign.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  /// The tiny live indicator that replaces the Start button the moment
  /// the room goes live: a slate-blue dot + "Live", same dark pill, same
  /// neutral palette. Tapping it expands the card (chat, code, Leave).
  Widget _livePill() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: YumeDesign.surfaceRaised,
        borderRadius: YumeDesign.pillRadius,
        border: Border.all(color: YumeDesign.hairlineStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: YumeDesign.accent,
              shape: BoxShape.circle,
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
    );
  }

  Widget _expandedCard(BuildContext context, TogetherService service) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = service.currentMedia;
    final otp = service.otp ?? '';
    final isHost = service.role == TogetherRole.host;
    final isPendingHost =
        isHost && service.phase == TogetherPhase.pendingHost;
    // Start is offered only while the room is actually ready: a title
    // picked, a player open, and the movie playing. A host who expanded
    // the card while browsing sees a neutral hint instead of a Start
    // button they cannot use yet — never a start prompt over a paused or
    // absent player.
    final canStart =
        isPendingHost &&
        media != null &&
        service.startState == TogetherStartState.ready;
    // Start / chat actions: the player registers them on the service while
    // it is open; the widget's own callbacks override (tests, direct
    // mounts). No player open means no engine to go live from, so there
    // is no Start at all until a player is open and playing.
    final onStart = widget.onStart ?? service.orbStartAction;
    final onOpenChat = widget.onOpenChat ?? service.orbOpenChatAction;
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
              const SizedBox(height: 4),
              Text(
                // Relay + measured latency, straight off the service.
                service.connectionStatusLabel,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  // The code chip flexes: on a narrow card (or a wide test
                  // font) the chip ellipsises instead of pushing the Copy
                  // button out of the card.
                  Flexible(
                    child: Container(
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2,
                        ),
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
              if (canStart && onStart != null)
                Center(
                  child: TogetherStartButton(
                    onPressed: () {
                      setState(() => _expanded = false);
                      onStart.call();
                    },
                  ),
                )
              else if (isPendingHost && media != null)
                const Text(
                  'Play the movie first — the Start button appears once '
                  'it’s playing.',
                  style: TextStyle(
                    fontSize: 12,
                    color: YumeDesign.textSecondary,
                    decoration: TextDecoration.none,
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
              if (onOpenChat != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() => _expanded = false);
                      onOpenChat.call();
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
      radius: 16,
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
