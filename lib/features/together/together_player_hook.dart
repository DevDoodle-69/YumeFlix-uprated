import 'dart:async';

import 'package:vlc_player/vlc_player.dart';

import '../../core/domain/entity/multimedia_item.dart';
import 'models.dart';
import 'sync_math.dart';
import 'together_service.dart';

/// The one small seam between Together and the VLC player.
///
/// The player screen owns the engine; this hook owns the translation between
/// the engine and the room, and nothing else:
///
/// * it tells the service what title this playback is, so the room knows
///   what it is about ([TogetherService.attachMedia]);
/// * it reports every engine tick to the service, so the host publishes on
///   play/pause/seek and once a second while playing;
/// * for a guest it turns the host's latest state into engine calls —
///   play/pause/seek, or a small rate nudge — via [decideSync];
/// * it exposes the two facts the chrome needs: whether the guest's
///   transport is locked, and whether the host still has to press Start.
///
/// It never rebuilds the player and never touches the engine except through
/// the controller it is handed. The screen creates it in `initState` and
/// disposes it in `dispose`; while no room exists it is a cheap no-op.
class TogetherPlayerHook {
  TogetherPlayerHook({
    required this.service,
    required this.controller,
    required this.media,
  });

  final TogetherService service;
  final VlcPlayerController controller;
  final TogetherMediaIdentity media;

  bool _attached = false;

  /// While true, engine callbacks are the echo of a host state being
  /// applied, not the viewer doing something — so they must not be
  /// reported back to the room as local playback.
  bool _applyingRemote = false;

  /// The rate last applied for a nudge, so a steady nudge is not re-sent
  /// on every tick.
  double _appliedRate = 1.0;

  /// Last time the guest evaluated the host state (throttled: the engine
  /// ticks four times a second and the decision only changes slowly —
  /// 500 ms between evaluations, 250 ms for a forced one).
  DateTime? _lastGuestEvalAt;

  /// True while a room exists in any form — creating, waiting or live.
  bool get isSessionActive => service.isSessionActive;

  /// True when this phone is a guest in a live room whose host is still
  /// there: the transport is the host's, and the controls render disabled
  /// with a "Host controls playback" hint. False when the host has left —
  /// the guest keeps watching locally, under its own control.
  bool get guestControlsLocked =>
      service.role == TogetherRole.guest &&
      service.isLive &&
      !service.hostGone;

  /// True when the host may go live right now: the room is pending, a
  /// title is picked, this player is open, and the movie is actually
  /// playing. Decided by the service ([TogetherService.startState]) —
  /// the hook never keeps its own copy of the conditions, so the player
  /// and the orb can never disagree. Pausing, or leaving the player,
  /// hides the button again until playback resumes.
  bool get showStartButton => service.showStartButton;

  /// Same condition as [showStartButton], for the floating orb: the orb's
  /// Start action goes live from wherever the host is watching, not only
  /// from the player screen's own button. The orb renders the compact
  /// Start run button only in this state, and only while it holds.
  bool get showOrbStart => service.showStartButton;

  /// The title the host started, when this phone is a guest in a live room.
  /// The player screen shows this when the guest has not opened the same
  /// title yet — a real room fact, never a guess.
  TogetherMediaIdentity? get hostStartedMedia =>
      service.role == TogetherRole.guest && service.isLive
      ? service.roomState?.media
      : null;

  /// True when this guest is live in a room but the title open in this
  /// player is NOT the title the host started. The guest is then watching
  /// the wrong thing: sync must not pretend otherwise — the player shows
  /// "Host started X — open the same title to join playback" instead.
  bool get guestNeedsSameTitle {
    final started = hostStartedMedia;
    if (started == null) return false;
    return !_sameTitle(media, started);
  }

  /// Plain-language hint for [guestNeedsSameTitle], or null when the guest
  /// is on the right title (or is not a guest in a live room).
  String? get guestJoinHint {
    final started = hostStartedMedia;
    if (started == null || !guestNeedsSameTitle) return null;
    return 'Host started ${started.title} — open the same title to join playback';
  }

  /// Same title? TMDB id wins when both sides know it; otherwise the
  /// normalised title (case / surrounding space ignored).
  static bool _sameTitle(TogetherMediaIdentity a, TogetherMediaIdentity b) {
    if (a.tmdbId != null && b.tmdbId != null) return a.tmdbId == b.tmdbId;
    return a.title.trim().toLowerCase() == b.title.trim().toLowerCase();
  }

  void attach() {
    if (_attached) return;
    _attached = true;
    service.addListener(_onServiceChanged);
    service.attachMedia(media);
    // The single root-mounted orb reads its Start action from the service:
    // while this player is open, Start on the orb goes live from this
    // engine. Cleared in [dispose] so a stale engine is never started.
    service.registerOrbStartAction(goLive);
    _onServiceChanged();
  }

  /// Host: goes live at the engine's current position and transport state.
  void goLive() {
    final value = controller.value;
    service.goLive(
      positionMs: value.position.inMilliseconds,
      durationMs: value.duration.inMilliseconds,
      playing: value.isPlaying,
    );
  }

  /// Called from the screen's playback-value listener, on every engine tick.
  ///
  /// For a guest in a live room this is also the enforcement point of
  /// host-only control: the player chrome already renders the guest's
  /// controls disabled with a "Host controls playback" hint, but a guest
  /// input that reaches the engine anyway (remote key, double-tap, a
  /// control that slipped through) is snapped back at once — a transport
  /// flip or a seek-sized jump against the host's state applies the host
  /// state immediately instead of waiting for the next throttled
  /// evaluation, so the guest's engine can never fight the host for more
  /// than one tick.
  void onLocalPlayback(VlcPlayerValue value) {
    if (!_attached || _applyingRemote) return;
    service.reportLocalPlayback(
      positionMs: value.position.inMilliseconds,
      durationMs: value.duration.inMilliseconds,
      playing: value.isPlaying,
    );
    if (service.role == TogetherRole.guest && service.isLive) {
      _maybeApplyHostState(force: _divergedFromHost(value));
    }
  }

  /// True when the guest's engine disagrees with the host's latest state
  /// by more than a nudge: a different transport state, or a position
  /// further than the seek threshold from where the host is now. A
  /// disagreement this big is a guest input (or a fresh join), not drift
  /// — it earns an immediate correction, not a throttled one.
  bool _divergedFromHost(VlcPlayerValue value) {
    final state = service.roomState;
    if (state == null || service.hostGone) return false;
    if (value.isPlaying != state.playing) return true;
    final target = state.targetPositionMs(
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    return (value.position.inMilliseconds - target).abs() >
        kSyncSeekThresholdMs;
  }

  void _onServiceChanged() {
    if (!_attached) return;
    // A rejoining host adopted the room's current position: land there
    // once, then let the normal host publishing take over.
    final adopted = service.consumeAdoptedSeek();
    if (adopted != null) {
      _applyingRemote = true;
      controller
          .seekTo(Duration(milliseconds: adopted))
          .whenComplete(() => _applyingRemote = false);
    }
    if (service.role == TogetherRole.guest && service.isLive) {
      _maybeApplyHostState(force: true);
    }
  }

  void _maybeApplyHostState({bool force = false}) {
    final state = service.roomState;
    if (state == null || service.hostGone) return;
    final now = DateTime.now();
    // Evaluations are throttled — 500 ms apart normally (2.8.0, was
    // 1000 ms), so small drift is nudged twice a second instead of once.
    // A forced evaluation (a host action just arrived via
    // [_onServiceChanged], or the guest diverged in [onLocalPlayback])
    // skips the normal wait but still respects a 250 ms floor, so an
    // engine mid-seek is not hammered with a seek on every tick.
    final sinceLastEval = _lastGuestEvalAt == null
        ? null
        : now.difference(_lastGuestEvalAt!).inMilliseconds;
    final minGapMs = force ? 250 : 500;
    if (sinceLastEval != null && sinceLastEval < minGapMs) return;
    _lastGuestEvalAt = now;
    final decision = decideSync(
      localPositionMs: controller.value.position.inMilliseconds,
      hostPositionMs: state.positionMs,
      hostTimestampMs: state.hostTimestampMs,
      nowMs: now.millisecondsSinceEpoch,
      hostPlaying: state.playing,
      durationMs: state.durationMs,
    );
    unawaited(_applyDecision(decision, state));
  }

  Future<void> _applyDecision(
    SyncDecision decision,
    TogetherRoomState state,
  ) async {
    _applyingRemote = true;
    try {
      final value = controller.value;
      // Rate first: a seek at the wrong rate lands right and then drifts
      // again before the next evaluation.
      final targetRate = decision.rate;
      if (targetRate != _appliedRate) {
        await controller.setPlaybackSpeed(targetRate);
        _appliedRate = targetRate;
      }
      if (decision.action == SyncAction.seek) {
        await controller.seekTo(
          Duration(milliseconds: decision.targetPositionMs),
        );
      }
      // Then the transport, to match the host: a guest that is paused
      // while the host plays is a guest that is falling behind.
      if (state.playing && !value.isPlaying) {
        await controller.play();
      } else if (!state.playing && value.isPlaying) {
        await controller.pause();
      }
    } catch (_) {
      // The engine may be mid-failover or tearing down; the next
      // evaluation (half a second away) retries. Never throw out of a sync tick.
    } finally {
      _applyingRemote = false;
    }
  }

  void dispose() {
    if (!_attached) return;
    _attached = false;
    service.removeListener(_onServiceChanged);
    service.registerOrbStartAction(null);
  }
}

/// Builds the room's media identity from the title the player opened.
///
/// The same composition the Discord presence uses (episode posters first,
/// then the item's poster, then its banner), so the room card and the
/// presence agree about what is playing.
TogetherMediaIdentity togetherMediaIdentityFor({
  required MultimediaItem item,
  Episode? episode,
}) {
  final isSeries =
      item.contentType == MultimediaContentType.series ||
      item.contentType == MultimediaContentType.anime;
  final title = episode == null
      ? item.title
      : '${item.title} · S${episode.season} E${episode.episode}';
  String? poster;
  for (final candidate in <String?>[
    episode?.posterUrl,
    item.posterUrl,
    item.bannerUrl,
  ]) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) {
      poster = value;
      break;
    }
  }
  return TogetherMediaIdentity(
    title: title,
    tmdbType: isSeries ? 'tv' : 'movie',
    tmdbId: item.tmdbId,
    posterUrl: poster,
    episodeLabel: episode == null
        ? null
        : 'S${episode.season} E${episode.episode}',
  );
}
