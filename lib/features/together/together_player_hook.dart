import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/services/discord_presence_service.dart';
import '../../core/utils/app_utils.dart';
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
    required TogetherMediaIdentity media,
  }) : _media = media;

  final TogetherService service;
  final VlcPlayerController controller;

  /// The title this playback is — the room's identity for it. Mutable
  /// because the player re-shares on an episode change without rebuilding
  /// the hook: [retargetMedia] moves it and the room with it.
  TogetherMediaIdentity _media;

  /// The title this playback is, for the room and the guest checks.
  TogetherMediaIdentity get media => _media;

  bool _attached = false;

  /// While true, engine callbacks are the echo of a host state being
  /// applied, not the viewer doing something — so they must not be
  /// reported back to the room as local playback.
  bool _applyingRemote = false;

  /// The rate last applied for a nudge, so a steady nudge is not re-sent
  /// on every tick.
  double _appliedRate = 1.0;

  /// True while this guest is holding a local pause (see
  /// [guestLocallyPaused]). While set, no host state is applied to the
  /// engine at all — not on a tick, not on an incoming state — so the
  /// pause can never be snapped back by the sync that is supposed to
  /// follow the host.
  bool _guestLocallyPaused = false;

  /// Last sync decision handed to the engine, for tests: the decision is
  /// the observable half of applying host state (the engine calls
  /// themselves go to a real controller and cannot be observed in a unit
  /// test). Set in [_maybeApplyHostState] before the decision is applied.
  SyncDecision? _lastAppliedDecision;

  /// Last sync decision applied to the engine, or null before the first
  /// one. Test-only read.
  @visibleForTesting
  SyncDecision? get lastAppliedDecisionForTest => _lastAppliedDecision;

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
  ///
  /// 2.11.0: this lock covers seeks, episode / source / language changes
  /// and the panel — NOT play/pause. Play/pause is the guest's own (see
  /// [guestLocallyPaused]): a guest pause holds only that phone, and
  /// resume jumps to the host's live position. The controls widget reads
  /// this same flag and lets play/pause through while it holds.
  bool get guestControlsLocked =>
      service.role == TogetherRole.guest &&
      service.isLive &&
      !service.hostGone;

  /// True while this guest is holding a LOCAL pause (2.11.0): they pressed
  /// pause while the host was playing, so only their own engine is paused
  /// — the host and every other guest keep watching, nothing is published
  /// to the room, and no host state is applied over the hold. Clears the
  /// moment they press play again, which jumps them to the host's current
  /// live position instead of resuming where they stopped.
  bool get guestLocallyPaused => _guestLocallyPaused;

  /// The brief fallback-source note the auto-open coordinator recorded
  /// after opening this title on a different source than the host's, or
  /// null when the open used the host's exact source. The player screen
  /// shows it as one short pill.
  String? get guestSourceFallbackNotice => service.guestAutoOpenNotice;

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
  /// normalised title (case / surrounding space ignored). A show id alone
  /// is never enough: two episodes of one show share it, so the episode
  /// label must match too whenever either side carries one — otherwise a
  /// guest on S1 E1 is told they are on the same title as a host on S1 E2
  /// and syncs into the wrong episode.
  static bool _sameTitle(TogetherMediaIdentity a, TogetherMediaIdentity b) =>
      togetherSameTitle(a, b);

  /// Re-points this hook at a new title — the episode advance / previous /
  /// pick path in the player screen. The room follows in the same step:
  /// [TogetherService.attachMedia] re-publishes the live state under the
  /// new title at position 0 when live, or updates the pending title when
  /// still browsing. A no-op when the title did not change, so a
  /// re-resolve of the same episode never re-shares and never rewinds.
  void retargetMedia(TogetherMediaIdentity media) {
    if (media == _media) return;
    _media = media;
    service.attachMedia(media);
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

  /// Host: records the stream source the player is actually playing
  /// (2.11.0 — the label of the resolved stream, e.g. `Server 1`) on the
  /// room identity and re-publishes it when live, so every guest learns
  /// the host's source pick at once. A source-only change keeps the
  /// position (see [TogetherService.attachMedia]); only a title change
  /// restarts at 0. A no-op when the source did not change. Called by the
  /// player screen when resolution completes and when the host hand-picks
  /// another source — never on automatic failover, which stays local to
  /// the phone that failed over.
  void updateSource(String sourceLabel) {
    if (sourceLabel.isEmpty) return;
    final updated = _media.withSource(sourceLabel);
    if (updated == _media) return;
    _media = updated;
    service.attachMedia(updated);
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
  ///
  /// 2.11.0 exception — the guest's own play/pause (see
  /// [guestLocallyPaused]): a guest pause while the host is playing holds
  /// ONLY this phone (no publish, no snap-back), and the guest's next play
  /// jumps straight to the host's current live position instead of
  /// resuming where they stopped.
  void onLocalPlayback(VlcPlayerValue value) {
    if (!_attached || _applyingRemote) return;
    service.reportLocalPlayback(
      positionMs: value.position.inMilliseconds,
      durationMs: value.duration.inMilliseconds,
      playing: value.isPlaying,
      // 2.11.0 (Worker B's speed end-to-end): the host's playback speed
      // rides in the live payload, so a 2× host does not leave the guest
      // chasing a 1× target. At 1× this changes nothing.
      playbackSpeed: value.playbackSpeed,
    );
    if (service.role != TogetherRole.guest || !service.isLive) return;
    final hostPlaying = service.roomState?.playing ?? false;
    if (!value.isPlaying &&
        !value.isBuffering &&
        hostPlaying &&
        !service.hostGone) {
      // A paused engine under a playing host is a local hold, not drift:
      // take it, hold it, and apply nothing over it. Deliberately no
      // publish anywhere — the host and the other guests never learn this
      // phone paused, because for them nothing changed. Buffering is not
      // a hold: a stalled engine is still trying to play, and the normal
      // sync below is what pulls it back.
      _guestLocallyPaused = true;
      return;
    }
    if (value.isPlaying && _guestLocallyPaused) {
      // Resume means catch up, not resume-where-stopped: clear the hold
      // and force the host state at once, which seeks to the host's
      // current live position (see [_maybeApplyHostState]).
      _guestLocallyPaused = false;
      _maybeApplyHostState(force: true);
      return;
    }
    if (_guestLocallyPaused) return;
    _maybeApplyHostState(force: _divergedFromHost(value));
  }

  /// True when the guest's engine disagrees with the host's latest state
  /// by more than a nudge: a different transport state, or a position
  /// further than the seek threshold from where the host is now. A
  /// disagreement this big is a guest input (or a fresh join), not drift
  /// — it earns an immediate correction, not a throttled one.
  ///
  /// A guest holding a local pause never counts as diverged: the pause is
  /// theirs to hold, and the correction would undo it.
  bool _divergedFromHost(VlcPlayerValue value) {
    if (_guestLocallyPaused) return false;
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
      // A guest holding a local pause is never snapped back by an
      // incoming host state — not by a play/pause flip, not by a seek,
      // not by a title change. The hold ends only when they press play.
      if (!_guestLocallyPaused) _maybeApplyHostState(force: true);
    }
  }

  void _maybeApplyHostState({bool force = false}) {
    if (_guestLocallyPaused) return;
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
      // 2.11.0 (Worker B's speed end-to-end): the drift correction must
      // aim at where the host is going at the host's speed — at 1× this
      // is the same target as before, at 2× it is twice as far along.
      hostPlaybackSpeed: state.playbackSpeed,
    );
    _lastAppliedDecision = decision;
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

/// Are two room identities the same title — the same movie, or the same
/// episode of the same show?
///
/// TMDB id wins when both sides know it, but a show id alone is never
/// enough: two episodes of one show share it, so the episode label must
/// match too whenever either side carries one. Without ids, the
/// normalised title decides (case / surrounding space ignored) — episode
/// titles embed their `S/E` suffix, so that comparison already separates
/// episodes. Public so tests can pin the episode rule without an engine.
/// The rule itself lives on the identity ([TogetherMediaIdentity.sameTitleAs]);
/// the source/provider/URLs never take part — the same title on a
/// different source is still the same title.
bool togetherSameTitle(TogetherMediaIdentity a, TogetherMediaIdentity b) =>
    a.sameTitleAs(b);

/// Builds the room's media identity from the title the player opened.
///
/// The same composition the Discord presence uses (episode posters first,
/// then the item's poster, then its banner), so the room card and the
/// presence agree about what is playing.
///
/// The title itself reuses the one title rule
/// ([DiscordPresenceService.formatWatchingTitle]): `· S{n} E{n}` only for a
/// true series/anime episode with real numbering. A film never gets a
/// suffix — plugins file a movie as a one-episode show, so the episode the
/// player was opened with is usually a dummy S1 E1, and passing it straight
/// through used to print "Harry Potter … · S1 E1" on the room card (plus a
/// second "S1 E1" line from [TogetherMediaIdentity.episodeLabel]). The
/// player screen already gates its own titles the same way (see its
/// `_currentEpisode`, which is null for films); this hook takes the raw
/// route episode, so the gate has to live here too.
///
/// 2.11.0 — the identity also carries what a guest needs to open the SAME
/// source the host chose: [itemUrl] (the provider detail URL),
/// [episodeUrl] (the episode data URL the player resolves streams from)
/// and the provider, plus the season/episode numbers. [videoUrl] is the
/// URL the player itself was opened with: for a film (where the episode is
/// null) it IS the episode URL, and for a series opened without an explicit
/// episode it names the episode the URL match found. A local file is never
/// shared as [episodeUrl] — it does not exist on the guest's phone — so a
/// downloaded title falls back to the guest resolving it from [itemUrl].
TogetherMediaIdentity togetherMediaIdentityFor({
  required MultimediaItem item,
  Episode? episode,
  String? videoUrl,
}) {
  final isSeries =
      item.contentType == MultimediaContentType.series ||
      item.contentType == MultimediaContentType.anime;
  final title = DiscordPresenceService.formatWatchingTitle(
    title: item.title,
    isSeries: isSeries,
    season: episode?.season,
    episode: episode?.episode,
  );
  final season = episode?.season ?? 0;
  final episodeNumber = episode?.episode ?? 0;
  final episodeLabel = isSeries && season > 0 && episodeNumber > 0
      ? 'S$season E$episodeNumber'
      : null;
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
  // The episode data URL, or the player's own open URL when no episode was
  // passed (a film, or a series resolved by URL match). Never a local
  // file: the guest cannot play a path from this phone's disk.
  final episodeToken = (episode?.url.isNotEmpty ?? false)
      ? episode!.url
      : videoUrl;
  final shareableEpisodeUrl =
      episodeToken != null &&
          episodeToken.isNotEmpty &&
          !AppUtils.isLocalFile(episodeToken)
      ? episodeToken
      : null;
  return TogetherMediaIdentity(
    title: title,
    tmdbType: isSeries ? 'tv' : 'movie',
    tmdbId: item.tmdbId,
    posterUrl: poster,
    episodeLabel: episodeLabel,
    season: isSeries && season > 0 ? season : null,
    episode: isSeries && episodeNumber > 0 ? episodeNumber : null,
    provider: item.provider,
    itemUrl: item.url.isNotEmpty ? item.url : null,
    episodeUrl: shareableEpisodeUrl,
  );
}
