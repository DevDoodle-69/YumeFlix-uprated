/// Platform plumbing the player screen needs but should not own: Android
/// picture-in-picture, device orientation, and desktop full screen.
///
/// Every entry point is a no-op where the platform has no equivalent, never a
/// throw, so call sites need no capability checks of their own.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../../../core/providers/device_info_provider.dart';

/// Re-exported so a screen can mirror window state without importing the
/// window plugin itself.
export 'package:window_manager/window_manager.dart' show WindowListener;

/// Set while a route is drawing to the window's own edges.
///
/// The desktop title bar is drawn over every route and is an ancestor of them
/// all, so nothing below the router can reach it; a listenable the shell
/// watches is the only channel. It lives here so the shell only has to know
/// "something wants the whole window", not which screen it was.
final ValueNotifier<bool> immersiveRouteActive = ValueNotifier<bool>(false);

/// How many immersive routes are mounted. A plain bool breaks when two
/// overlap: the inner teardown would uncover the shell over the outer one.
int _immersiveRouteCount = 0;

/// Claims and releases the immersive flag, deferred past the current frame.
///
/// Callers claim from `initState` and release from `dispose`, and the shell
/// listening to this sits in `MaterialApp.builder` rather than below the
/// Navigator, so a synchronous notify throws during build and during the
/// tree lock.
void setImmersiveRoute({required bool active}) {
  _immersiveRouteCount += active ? 1 : -1;
  if (_immersiveRouteCount < 0) _immersiveRouteCount = 0;
  final wanted = _immersiveRouteCount > 0;
  if (immersiveRouteActive.value == wanted) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    immersiveRouteActive.value = _immersiveRouteCount > 0;
  });
}

/// Set while the app is in full screen mode — the ten-foot mode a desktop is
/// put into when it is plugged into a television.
///
/// Written only by `FullScreenMode` in the settings feature. It lives here
/// because [playerFormFactorOf] is a plain function with no `ref` to read a
/// provider through.
final ValueNotifier<bool> fullScreenModeActive = ValueNotifier<bool>(false);

/// The orientation policy a device wants from the player.
///
/// Derived from [DeviceProfile] rather than [Platform]: an Android TV and an
/// Android phone are both `Platform.isAndroid`, and pinning a television to
/// portrait is nonsense.
enum PlayerFormFactor {
  /// Uses landscape for playback, then returns to portrait on exit.
  phone,

  /// Uses landscape for playback, but is released on exit — a tablet is
  /// browsable either way up.
  tablet,

  /// A fixed landscape panel. Orientation requests are meaningless.
  tv,

  /// A window, not a screen. Orientation requests are meaningless.
  desktop,

  /// The device profile has not resolved yet. Treated as "do not touch": the
  /// player pins nothing, so there is nothing to restore either.
  unknown;

  /// Whether the player is allowed to pin this device to an orientation.
  ///
  /// Doubles as the platform gate for the orientation API: [phone] and
  /// [tablet] are only ever produced from an Android or iOS device profile, so
  /// no separate `Platform` check is needed.
  bool get pinsOrientation =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;

  /// Whether a finger is the only thing that drives this player.
  ///
  /// The gate for anything that defends against accidental contact, the screen
  /// lock above all. A remote has no accidental surface, a mouse has no
  /// pocket, and [unknown] is still "do not touch".
  ///
  /// A second getter rather than a use of [pinsOrientation], which names the
  /// same two members today and means something else entirely.
  bool get isTouch =>
      this == PlayerFormFactor.phone || this == PlayerFormFactor.tablet;
}

/// Maps the app-wide device profile onto the player's orientation policy.
///
/// Takes the nullable value straight off `deviceProfileProvider.asData`. A
/// profile that has not resolved yet is [PlayerFormFactor.unknown] rather than
/// a guess: guessing "phone" on a television would pin a TV to portrait for
/// the life of the process, and full screen mode is no substitute for a
/// verdict either.
PlayerFormFactor playerFormFactorOf(
  DeviceProfile? profile, {
  TargetPlatform? targetPlatform,
}) {
  if (kIsWeb) return PlayerFormFactor.unknown;
  final platform = targetPlatform ?? defaultTargetPlatform;
  if (profile == null) {
    // Do not leave the first playback in portrait just because device-profile
    // discovery has not completed yet. Mobile is the safe default for this
    // phone-focused app; a later TV profile still takes precedence below.
    return platform == TargetPlatform.android || platform == TargetPlatform.iOS
        ? PlayerFormFactor.phone
        : PlayerFormFactor.unknown;
  }
  // isTv wins: a leanback device also measures wide enough to set isTablet.
  // Full screen mode reaches the same verdict by choice, not by hardware.
  if (profile.isTv || fullScreenModeActive.value) return PlayerFormFactor.tv;
  if (profile.isDesktopOS) return PlayerFormFactor.desktop;
  return profile.isTablet ? PlayerFormFactor.tablet : PlayerFormFactor.phone;
}

/// A transport command issued from the picture-in-picture window's buttons.
///
/// Delivered by `MainActivity`'s broadcast receiver while the app is in PiP
/// and the Flutter UI is not being touched at all.
enum PipAction { play, pause, seekForward, seekBackward }

class PlayerPlatformService {
  PlayerPlatformService({
    Future<void> Function(List<DeviceOrientation>)? setPreferredOrientations,
    TargetPlatform Function()? targetPlatform,
  }) : _setPreferredOrientations =
           setPreferredOrientations ?? SystemChrome.setPreferredOrientations,
       _targetPlatform = targetPlatform ?? (() => defaultTargetPlatform);

  final Future<void> Function(List<DeviceOrientation>)
  _setPreferredOrientations;
  final TargetPlatform Function() _targetPlatform;

  /// System-channel requests can finish after the screen has already changed
  /// shape or closed. Serialize them and skip requests that are no longer the
  /// latest intent so an old landscape request cannot win a race with restore.
  Future<void> _orientationQueue = Future<void>.value();
  int _orientationRequest = 0;

  /// Shared with `MainActivity.CHANNEL`. Traffic runs both ways over it:
  /// `enterPip`/`setPipState` out, transport actions and `pipModeChanged` back.
  static const MethodChannel _pipChannel = MethodChannel(
    'yume.flix.by.nzr/player_pip',
  );

  static const List<DeviceOrientation> _landscape = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// The seek distance the PiP buttons advertise — `ic_replay_10` and
  /// `ic_forward_10` in `MainActivity.createPipActions`. Exposed so the
  /// handler cannot drift from the icons on screen.
  static const Duration pipSeekStep = Duration(seconds: 10);

  /// The orientation this service has requested from the OS, or null if it
  /// has not chosen one yet.
  ///
  /// The value is set before the asynchronous channel call so repeated player
  /// ticks cannot enqueue duplicates. A failed request clears it for retry.
  Orientation? _pinnedOrientation;

  /// Whether landscape was ever asked of the OS by this instance, even if
  /// that request failed at the channel.
  ///
  /// [restoreOrientation] is owed whenever this is true: a failed landscape
  /// request clears [_pinnedOrientation] for retry, but the OS may still
  /// hold the last landscape pin it applied, and gating the restore on the
  /// flag would silently leave the phone in landscape for the rest of the
  /// process.
  bool _landscapeRequested = false;

  /// Whether orientation has been handed back.
  ///
  /// Terminal for this instance: once set, [applyLandscapeOrientation] is a
  /// no-op. The player route stays mounted through the pop transition while
  /// the controller keeps ticking, and a tick that lands after the restore
  /// used to re-pin landscape and drop the queued portrait request as stale
  /// (see [_queueOrientation]) — the whole app then stayed in landscape
  /// with nobody left to restore it. Each player screen owns a fresh
  /// service, so a later playback re-pins through its own instance.
  bool _released = false;

  /// Whether a restore request reached the OS. Once true, further restore
  /// calls are no-ops: the screen calls restore twice (on Back, then from
  /// dispose) and the second call must not queue a duplicate.
  bool _restoreDelivered = false;

  /// Whether the latest restore request failed at the channel. While true,
  /// a further restore call re-queues instead of returning early, so a
  /// restore issued during teardown gets its second chance from dispose.
  bool _restoreFailed = false;

  /// Returns whether the window actually shrank. False covers pre-Oreo, a
  /// device that refuses, and a user who has turned PiP off for this app,
  /// which Android reports as a plain `false`.
  ///
  /// [videoSize] shapes the window; without it Android keeps whatever shape it
  /// used last, so a 2.39:1 film is letterboxed inside an already small
  /// window. Null and zero sizes are not sent at all.
  ///
  /// The platform gate reads [defaultTargetPlatform] rather than
  /// `Platform.isAndroid` because only the former can be overridden by a test.
  Future<bool> enterPip(bool isPlaying, {Size? videoSize}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final entered = await _pipChannel.invokeMethod<bool>('enterPip', {
        'isPlaying': isPlaying,
        ..._videoSizeArgs(videoSize),
      });
      return entered ?? false;
    } catch (e) {
      // Pre-Oreo answers UNSUPPORTED, and a TV or a locked device can refuse
      // outright. Failing to shrink is not worth interrupting playback for.
      if (kDebugMode) debugPrint('PlayerPlatformService.enterPip: $e');
      return false;
    }
  }

  /// The video's shape as MainActivity wants it, or nothing at all.
  ///
  /// Absent rather than zero before the first frame is decoded: Android throws
  /// IllegalArgumentException out of `enterPictureInPictureMode` for an aspect
  /// ratio it does not like.
  static Map<String, int> _videoSizeArgs(Size? size) {
    if (size == null || size.width <= 0 || size.height <= 0) {
      return const <String, int>{};
    }
    return <String, int>{
      'videoWidth': size.width.round(),
      'videoHeight': size.height.round(),
    };
  }

  /// Keeps the PiP window's middle button showing the right play/pause icon.
  ///
  /// Fire-and-forget: it is driven from a playback-state listener, and a
  /// dropped icon refresh is not worth making that listener async. The catch
  /// is load-bearing — without it a missing native handler surfaces as an
  /// unhandled async error far from this call.
  ///
  /// Carries [videoSize] because the next episode can be shaped differently
  /// from the one that opened the window.
  void syncPipState(bool isPlaying, {Size? videoSize}) {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    unawaited(
      _pipChannel
          .invokeMethod<void>('setPipState', {
            'isPlaying': isPlaying,
            ..._videoSizeArgs(videoSize),
          })
          .catchError((Object e) {
            if (kDebugMode) {
              debugPrint('PlayerPlatformService.syncPipState: $e');
            }
          }),
    );
  }

  /// Routes the PiP window's transport buttons and mode changes back to the
  /// screen.
  ///
  /// Callback-based and state-free: this class has no idea what "play" should
  /// do. The screen owns the controller and decides.
  ///
  /// Not gated on Android: a handler on a channel no other platform sends to
  /// is already inert, and a runtime gate would make the routing untestable.
  ///
  /// The handler is keyed by channel name, so it is process-wide and a second
  /// call replaces the first. [detachPipListener] must run on teardown, or the
  /// handler closes over a dead screen while Android tears the PiP window
  /// down.
  void attachPipListener({
    required void Function(PipAction action) onAction,
    required void Function(bool inPip) onModeChanged,
  }) {
    _pipChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'pipModeChanged':
          // `== true` rather than a cast: the argument crosses the channel as
          // a dynamic, and a malformed one should not throw into the engine.
          onModeChanged(call.arguments == true);
        case 'play':
          onAction(PipAction.play);
        case 'pause':
          onAction(PipAction.pause);
        case 'seekForward':
          onAction(PipAction.seekForward);
        case 'seekBackward':
          onAction(PipAction.seekBackward);
        // Anything else is ignored rather than answered with
        // notImplemented(): MainActivity invokes these with no result
        // callback, so the exception would have nowhere to go.
      }
      return null;
    });
  }

  void detachPipListener() => _pipChannel.setMethodCallHandler(null);

  /// Requests landscape for every mobile playback, independent of media
  /// dimensions, rotation tags, track availability, or adaptive-stream swaps.
  ///
  /// Some streams never report a usable display size, and some portrait-encoded
  /// streams report orientation metadata late. The player's stated behavior is
  /// to view every title in landscape, so waiting for those signals can only
  /// leave a phone stuck in portrait. Requests are immediate and idempotent;
  /// repeated playback events retry if the platform channel previously failed.
  /// [restoreOrientation] releases the request when the player closes.
  void applyLandscapeOrientation() {
    // Restore is terminal for this instance: the player is leaving, and a
    // tick that lands during the pop transition must not re-pin landscape
    // over the portrait request already queued. See [_released].
    if (_released) return;
    final platform = _targetPlatform();
    final isMobile =
        platform == TargetPlatform.android || platform == TargetPlatform.iOS;
    if (!isMobile) {
      if (_pinnedOrientation != null) {
        _pinnedOrientation = null;
        _queueOrientation(const []);
      } else {
        // Invalidate a mobile request that has not started yet.
        _orientationRequest++;
      }
      return;
    }
    if (_pinnedOrientation == Orientation.landscape) return;
    _pinnedOrientation = Orientation.landscape;
    _landscapeRequested = true;
    _queueOrientation(_landscape);
  }

  void _queueOrientation(
    List<DeviceOrientation> orientations, {
    bool isRestore = false,
  }) {
    final request = ++_orientationRequest;
    _orientationQueue = _orientationQueue
        .catchError((Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint(
              'PlayerPlatformService orientation request failed: $error',
            );
          }
        })
        .then((_) async {
          if (request != _orientationRequest) return;
          try {
            await _setPreferredOrientations(orientations);
            if (isRestore) {
              _restoreDelivered = true;
              _restoreFailed = false;
            }
          } catch (error) {
            // A failed restore stays retryable: the screen calls restore
            // twice (on Back, then from dispose), and the second call must
            // re-queue rather than return early.
            if (isRestore && request == _orientationRequest) {
              _restoreFailed = true;
              _restoreDelivered = false;
            }
            // Leave the service eligible to retry if the platform channel was
            // temporarily unavailable; never leak an unhandled async error.
            if (request == _orientationRequest) _pinnedOrientation = null;
            if (kDebugMode) {
              debugPrint(
                'PlayerPlatformService orientation request failed: $error',
              );
            }
          }
        });
  }

  /// Hands orientation back to the rest of the app on the way out.
  ///
  /// Phones return to [DeviceOrientation.portraitUp]; anything else is
  /// released with an empty list, meaning "whatever the manifest and
  /// Info.plist already allow". Restoring `DeviceOrientation.values` instead
  /// would unlock rotation app-wide and leave every other screen free to land
  /// sideways.
  ///
  /// Terminal: the first call marks this instance released, so a playback
  /// tick that lands during the pop transition cannot re-pin landscape over
  /// the portrait request. Idempotent once the restore reached the OS, and
  /// re-issued when the previous restore failed at the channel — the screen
  /// calls this on Back and again from dispose, and the second call is the
  /// first one's retry, not a duplicate.
  ///
  /// Owed whenever landscape was ever requested ([_landscapeRequested]),
  /// not only while [_pinnedOrientation] is set: a failed landscape request
  /// clears the pin for retry, and gating on it would skip the restore the
  /// phone still needs. A player closed before anything was pinned sends
  /// nothing, since pinning `portraitUp` on the way out would freeze rotation
  /// for the rest of the process, and nothing else in the app ever calls
  /// `setPreferredOrientations`. The form factor can also have changed
  /// underneath us since the pin.
  ///
  void restoreOrientation(PlayerFormFactor form) {
    if (_restoreDelivered) return;
    if (_released && !_restoreFailed) return;
    _released = true;
    _restoreFailed = false;
    if (!_landscapeRequested && _pinnedOrientation == null) return;
    _pinnedOrientation = null;
    _queueOrientation(
      form == PlayerFormFactor.phone
          ? const [DeviceOrientation.portraitUp]
          : const [],
      isRestore: true,
    );
  }

  /// Leaves full screen, whatever put the window there.
  ///
  /// Not a toggle: the OS window controls can change the state behind us, so
  /// mirrored state would be wrong and leave the viewer stranded in a
  /// chrome-less full-screen window after the video closes. Setting false
  /// unconditionally is a no-op when already windowed.
  Future<void> exitFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.exitFullscreen: $e');
    }
  }

  /// Puts the window into or out of full screen.
  ///
  /// For a caller that already knows which state it wants, where
  /// [toggleFullscreen] would depend on a window state the OS window controls
  /// can change behind its back.
  ///
  /// Returns nothing for the same reason [toggleFullscreen] does not: on macOS
  /// the window is still animating when this completes.
  Future<void> setFullscreen(bool fullscreen) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      await windowManager.setFullScreen(fullscreen);
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.setFullscreen: $e');
    }
  }

  /// Asks the window to change state. It answers by calling back.
  ///
  /// Nothing useful could be returned: F11 and the macOS green button move the
  /// window without coming through here, and macOS animates the transition, so
  /// even a truthful answer would be premature. Callers mirror the state from
  /// [WindowListener.onWindowEnterFullScreen] instead.
  Future<void> toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return;
    try {
      await windowManager.setFullScreen(!await windowManager.isFullScreen());
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.toggleFullscreen: $e');
    }
  }

  /// Whether the window is full screen right now.
  ///
  /// For seeding a mirror on the way in: the window may already have been put
  /// there by F11 or the green button long before the player opened. False
  /// where there is no window at all, which is also the right answer.
  Future<bool> isFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      return await windowManager.isFullScreen();
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.isFullscreen: $e');
      return false;
    }
  }

  /// Subscribes [listener] to the window's own state changes.
  ///
  /// The indirection exists for the platform gate: window_manager's Dart side
  /// happily registers a listener on Android, where nothing will ever call it.
  void addWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.addListener(listener);
  }

  void removeWindowListener(WindowListener listener) {
    if (Platform.isAndroid || Platform.isIOS) return;
    windowManager.removeListener(listener);
  }
}

/// The player screen's orientation contract, in one place.
///
/// The screen used to drive [PlayerPlatformService] from three scattered
/// call sites — a playback tick, a build post-frame callback, and dispose —
/// with no owner for the order they run in. That scattering is what let a
/// tick during the pop transition undo the restore: nothing said "leaving"
/// out loud. This controller is that owner, and the only thing the screen
/// calls for orientation:
///
/// * landscape while the player is up ([onPlaybackTick],
///   [onForegrounded]);
/// * portrait (phones) the moment it leaves, whichever way it leaves
///   ([onBack] before the pop, [dispose] as the second chance).
///
/// It holds no state of its own: the form factor stays the screen's cached
/// `_form`, passed in per call, and the pin/release state lives in the
/// service, where the channel queue can enforce it. It takes no Together
/// input, so popping the player while a room is live follows exactly the
/// same path as popping it alone. TV behaviour is unchanged: the service
/// pins landscape on any Android/iOS device and releases it on exit, and
/// this controller never overrides that.
class PlayerOrientationController {
  PlayerOrientationController(this._platform);

  final PlayerPlatformService _platform;

  /// A playback tick: (re-)assert landscape while the player is up.
  ///
  /// Idempotent while pinned, and a no-op once the player is leaving — a
  /// tick during the pop transition must not re-pin over the restore.
  void onPlaybackTick() => _platform.applyLandscapeOrientation();

  /// The app came back to the foreground with the player still open —
  /// Home-button backgrounding, or a tap back from the PiP window.
  ///
  /// Re-asserts landscape in case the pin was lost while backgrounded. A
  /// no-op when already pinned, and blocked once the player is leaving, so
  /// a foreground event mid-pop cannot resurrect the pin.
  void onForegrounded() => _platform.applyLandscapeOrientation();

  /// Back, from any path: the chrome button, the system back/gesture, the
  /// close buttons on the ended and failed cards.
  ///
  /// Restores before the pop, while the route and its platform channel are
  /// definitely alive — dispose alone left the restore to teardown timing,
  /// with nothing to retry it. The dispose call below is the retry.
  void onBack(PlayerFormFactor form) => _platform.restoreOrientation(form);

  /// Teardown: the second chance for the restore issued by [onBack], and
  /// the only restore when the route leaves without Back (a route
  /// replacement, or the system removing the route).
  void dispose(PlayerFormFactor form) => _platform.restoreOrientation(form);
}
