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
/// ONE Start control (2.9.0). There used to be two Start implementations
/// in this widget — the collapsed pill's own display-only "Start" row and
/// a [TogetherStartButton] inside the expanded card — and the user saw two
/// "Start" pills at once in the player. There is now exactly one: the
/// collapsed pill in the `ready` state IS the [TogetherStartButton] (a
/// real button, one call site in the whole app), driven by the service's
/// state machine ([TogetherService.startState]) and by nothing else. The
/// expanded card never renders a Start button: if the card is open when
/// the room becomes ready it collapses itself, so the pill is the thing on
/// screen. The outer [GestureDetector] handles drag and expand/collapse
/// only — its `onTap` is null while ready, so the button is the sole tap
/// handler and one tap can never fire Start twice.
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
/// * live — the orb hides ENTIRELY (2.10.0, Bug 1). The Start button is
///   gone and the Live status lives only in the player control panel's
///   Live indicator, next to the chat icon, where it can only
///   exist while the shared title is actually playing in an open player.
///   The old floating "Live" pill read the sticky session phase and
///   stayed up on the home screen, details and search long after the
///   user had left the player, paused or lost the host; it is deleted,
///   and [TogetherService.isShowingLive] is the only live fact any UI
///   reads. A live room that is paused or player-less falls back to
///   browsing here, and the neutral pill returns.
///
/// Start and chat come from the player while one is open: the player hook
/// registers its `goLive` and the player screen its open-chat action on
/// the service ([TogetherService.orbStartAction] /
/// [TogetherService.orbOpenChatAction]), and the orb reads them here. With
/// no player open there is no Start at all — the orb never falls back to
/// opening a title to start.
///
/// ORIENTATION (2.9.0). The player pins landscape at the window level
/// ([PlayerPlatformService.applyLandscapeOrientation]), so the orb — which
/// lives above the router, outside the player subtree — is laid out in
/// window coordinates and its content is always upright: there is no
/// rotated ancestor to counter-rotate against, and none is introduced
/// here. What rotation DID break was the pill's *position*: one saved
/// screen fraction was reused across orientations, so a fraction saved in
/// portrait landed on the seek bar / centre controls in landscape, and
/// the old fixed 64 px top clamp let the pill cover the room code and the
/// player's top status pills. The pill is now clamped every build — and
/// every drag — into an orientation-specific band: the top band (app bar,
/// room code, player status pills) is reserved, the bottom band (nav bar
/// in portrait, seek bar / transport in landscape) is reserved, and the
/// safe-area insets are honoured, so the pill can never cover primary
/// content in either orientation. The expanded card is height-capped and
/// scrollable, so it fits a short landscape window instead of covering it.
///
/// The position is a screen fraction kept in [TogetherService] for the
/// session and persisted to SharedPreferences, so it survives rotation,
/// app restarts and different screen sizes. The fraction is re-interpreted
/// through the current orientation's band on every build, so a position
/// saved in portrait is clamped into the landscape band (and back) rather
/// than landing on the controls.
///
/// Tap toggles the expanded card, EXCEPT while ready, where a tap is the
/// Start itself: live room status (a real MQTT fact), the picked title,
/// the room code with copy, who is in the room, and the actions that make
/// sense right now — Pick a title (host, while browsing), Chat (in the
/// player) and Leave.
///
/// TV never sees it: [DeviceProfile.isTv] hides Together entirely, the
/// same rule that hides the 5th nav tab (`showTogether: !profile.isTv`).
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
  static const Offset _kDefaultFractionPortrait = Offset(0.72, 0.78);

  /// Landscape default: right edge, in the free middle band — clear of
  /// the top status pills and of the seek bar / transport below.
  static const Offset _kDefaultFractionLandscape = Offset(0.86, 0.45);

  static const double _kCollapsedWidth = 212;
  static const double _kExpandedWidth = 300;

  /// Portrait: app bar + room-code / title area. Landscape: the player's
  /// top status pills. The pill's top edge never goes above this band.
  static const double _kReservedTopPortrait = 120;
  static const double _kReservedTopLandscape = 96;

  /// Portrait: bottom nav bar + margin. Landscape: the bottom chrome
  /// (seek bar + transport, [HotstarPlayerStyle.bottomChromeHeight]).
  /// The pill's bottom edge never goes below this band.
  static const double _kReservedBottomPortrait = 96;
  static const double _kReservedBottomLandscape = 152;

  Offset _fraction = _kDefaultFractionPortrait;
  bool _hasPosition = false;
  bool _expanded = false;
  bool _dragMoved = false;
  bool _pressed = false;
  bool _collapseScheduled = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final service = ref.read(togetherServiceProvider);
      await service.loadOrbPosition();
      if (!mounted) return;
      setState(() {
        final saved = service.orbPositionFraction;
        if (saved != null) {
          _fraction = saved;
          _hasPosition = true;
        }
      });
    });
  }

  void _copyOtp(String otp) {
    Clipboard.setData(ClipboardData(text: otp));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room code copied — send it to your friend')),
    );
  }

  /// The pixel band the pill's top-left corner may sit in, for the current
  /// orientation and the pill size actually rendered. The top band (room
  /// code / status pills) and the bottom band (nav bar / seek bar) are
  /// reserved, and the safe-area insets are honoured on every edge, so a
  /// drag can never park the pill over primary content.
  ({double left, double top, double right, double bottom}) _orbBounds(
    Size size,
    EdgeInsets padding,
    Orientation orientation,
    double pillWidth,
    double pillHeight,
  ) {
    final left = padding.left + 8;
    final right = math.max(left, size.width - padding.right - 8 - pillWidth);
    final top = orientation == Orientation.landscape
        ? padding.top + _kReservedTopLandscape
        : padding.top + _kReservedTopPortrait;
    final reservedBottom = orientation == Orientation.landscape
        ? _kReservedBottomLandscape
        : _kReservedBottomPortrait;
    final bottom = math.max(
      top,
      size.height - padding.bottom - reservedBottom - pillHeight,
    );
    return (left: left, top: top, right: right, bottom: bottom);
  }

  Offset _clampFraction(
    Offset fraction,
    Size size,
    EdgeInsets padding,
    Orientation orientation,
    double pillWidth,
    double pillHeight,
  ) {
    final bounds = _orbBounds(size, padding, orientation, pillWidth, pillHeight);
    return Offset(
      (fraction.dx * size.width)
          .clamp(bounds.left, bounds.right)
          .toDouble() /
          size.width,
      (fraction.dy * size.height)
          .clamp(bounds.top, bounds.bottom)
          .toDouble() /
          size.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(togetherServiceProvider);
    final isTv =
        ref.watch(deviceProfileProvider).asData?.value.isTv ?? false;
    if (!service.isSessionActive || isTv) return const SizedBox.shrink();
    // 2.10.0, Bug 1: while the room is live AND the shared title is
    // actually playing in an open player, the orb hides entirely — the
    // Live status lives only in the player control panel, which unmounts
    // the moment playback stops or the player closes. Showing any pill
    // here in that state is how the stale "Live" pill ended up on the
    // home screen: this widget sits above the router and outlives the
    // player, so it must never render a live claim of its own.
    if (service.startState == TogetherStartState.live) {
      return const SizedBox.shrink();
    }

    final media = MediaQuery.of(context);
    final size = media.size;
    final orientation = media.orientation;
    final padding = media.padding;
    // The ready / live pills are compact run / status chips, much
    // narrower than the browsing pill — the drag clamp uses the width
    // actually rendered, so a narrow pill can still reach the screen edge.
    final collapsedWidth = switch (service.startState) {
      TogetherStartState.ready => 104.0,
      _ => _kCollapsedWidth,
    };
    final width = _expanded ? _kExpandedWidth : collapsedWidth;
    // The expanded card is height-capped (see below), so its drag height
    // is the capped height, never the full 340 dp of content.
    final height = _expanded
        ? math.min(340.0, size.height - padding.vertical - 24)
        : 48.0;
    // The saved fraction is re-interpreted through this orientation's
    // band on every build: a position saved in portrait is clamped into
    // the landscape band (and back), never left sitting on the controls.
    // With no saved position yet, each orientation starts from its own
    // default instead of inheriting the other one's.
    final baseFraction = _hasPosition
        ? _fraction
        : orientation == Orientation.landscape
        ? _kDefaultFractionLandscape
        : _kDefaultFractionPortrait;
    final clampedFraction = _clampFraction(
      baseFraction,
      size,
      padding,
      orientation,
      width,
      height,
    );
    final bounds = _orbBounds(size, padding, orientation, width, height);
    final left = clampedFraction.dx * size.width;
    final top = clampedFraction.dy * size.height;

    final isReady = service.startState == TogetherStartState.ready;
    // The card must not stay open over the Start pill: the pill is the
    // only Start control, so an open card in the ready state collapses
    // itself on the next frame and the pill is what the host sees.
    if (_expanded && isReady && !_collapseScheduled) {
      _collapseScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _collapseScheduled = false;
        if (!mounted) return;
        final current = ref.read(togetherServiceProvider);
        if (_expanded &&
            current.startState == TogetherStartState.ready) {
          setState(() => _expanded = false);
        }
      });
    }

    return Positioned(
      left: left.clamp(bounds.left, bounds.right).toDouble(),
      top: top.clamp(bounds.top, bounds.bottom).toDouble(),
      child: GestureDetector(
        onPanStart: (_) => _dragMoved = false,
        onPanUpdate: (details) {
          if (details.delta.distance > 2) _dragMoved = true;
          // Drag from where the pill actually is: with no saved position
          // yet that is the orientation's default, not the other
          // orientation's.
          final base = _hasPosition
              ? _fraction
              : orientation == Orientation.landscape
              ? _kDefaultFractionLandscape
              : _kDefaultFractionPortrait;
          setState(() {
            _hasPosition = true;
            _fraction = _clampFraction(
              Offset(
                base.dx + details.delta.dx / size.width,
                base.dy + details.delta.dy / size.height,
              ),
              size,
              padding,
              orientation,
              width,
              height,
            );
          });
        },
        onPanEnd: (_) {
          ref.read(togetherServiceProvider).setOrbPosition(_fraction);
        },
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        // While ready the pill IS the Start button (a real InkWell
        // inside [TogetherStartButton]) and the sole tap handler: a null
        // onTap here means no competing recogniser, so one tap fires
        // Start exactly once. Otherwise a tap toggles the card.
        onTap: isReady
            ? null
            : () {
                if (_dragMoved) return;
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
    // Ready gets its own compact pill below; browsing / reconnecting /
    // waiting share the neutral pill. There is deliberately no "Ready to
    // start" state anywhere: while browsing the orb is only ever the
    // neutral pill, and Start appears only as the run button, only while
    // the movie is playing. And there is deliberately no live pill any
    // more (2.10.0, Bug 1): `build` hides the orb entirely while live,
    // so this switch never sees `live` — the defensive arm below keeps
    // it that way if the gate ever changes, instead of resurrecting a
    // pill that can outlive the player.
    switch (service.startState) {
      case TogetherStartState.ready:
        // THE Start button — the single one in the app. Tapping it goes
        // live at once; goLive flips the phase to live synchronously, so
        // the button vanishes in the same rebuild and the Live indicator
        // in the player control panel takes its place. No second Start
        // lives anywhere else. The action is resolved at tap time, not
        // build time: the player hook registers its goLive on the service
        // while a player is open, and the button must use the action
        // current at the tap.
        return TogetherStartButton(
          onPressed: () {
            final onStart = widget.onStart ?? service.orbStartAction;
            onStart?.call();
          },
        );
      case TogetherStartState.live:
        return const SizedBox.shrink();
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

  Widget _expandedCard(BuildContext context, TogetherService service) {
    final colorScheme = Theme.of(context).colorScheme;
    final media = service.currentMedia;
    final otp = service.otp ?? '';
    final isHost = service.role == TogetherRole.host;
    final isPendingHost =
        isHost && service.phase == TogetherPhase.pendingHost;
    // No Start button lives in this card any more (2.9.0): the collapsed
    // pill is the single Start control, and the card collapses itself
    // when the room becomes ready. A host who expanded the card while
    // browsing sees a neutral hint instead — never a second Start.
    final isReady = service.startState == TogetherStartState.ready;
    // Chat action: the player registers it on the service while it is
    // open; the widget's own callback overrides (tests, direct mounts).
    final onOpenChat = widget.onOpenChat ?? service.orbOpenChatAction;
    final mediaQuery = MediaQuery.of(context);
    return _glass(
      context,
      SizedBox(
        width: _kExpandedWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // A short landscape window cannot hold the whole card: cap
            // it and scroll, instead of covering the picture.
            maxHeight: math.max(
              200.0,
              mediaQuery.size.height - mediaQuery.padding.vertical - 24,
            ),
          ),
          child: SingleChildScrollView(
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
                        // 44 dp hit target for the collapse chevron.
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 20,
                          ),
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
                  if (isReady)
                    const Text(
                      'Playing — tap Start on the floating pill to go live.',
                      style: TextStyle(
                        fontSize: 12,
                        color: YumeDesign.textSecondary,
                        decoration: TextDecoration.none,
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
