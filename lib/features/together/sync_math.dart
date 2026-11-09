import 'dart:math';

/// Pure sync math for Together watch parties.
///
/// Kept free of Flutter, MQTT and the player engine so it can be unit-tested
/// in isolation. Everything here is arithmetic on milliseconds; the caller
/// owns clocks, timers and the engine.
///
/// The sync contract, in one place (2.8.0 — tightened: a 1.5 s seek
/// threshold let the guest sit visibly out of sync for over a second, and
/// a 300 ms nudge band ignored drift the viewer could already feel;
/// 2.11.0 — verified, not just tightened: see [kSyncSeekThresholdMs]):
/// * the host is the only clock that matters — a guest never publishes a
///   state of its own, it only chases the host's;
/// * drift under 150 ms is "in sync" (network jitter, not worth touching);
/// * drift of 150–750 ms is fixed by nudging the playback rate a touch
///   (inaudible, no visible jump);
/// * drift over 750 ms is fixed by seeking — a jump that far is already
///   noticeable, so landing exactly beats gliding.
/// * when the host is paused there is no clock to chase: the target is the
///   host's frozen position, and only a seek can fix a gap over 750 ms.
/// * a guest that RESUMES from a local pause ([decideResumeSync]) does not
///   nudge back: any gap over 150 ms is a seek straight to the host's
///   current live position — resuming is a jump to live, not a glide.
/// * the host's playback speed is part of the clock: the target advances
///   at the host's speed ([liveTargetMs]), and the guest's in-sync rate
///   IS the host's speed, with nudges relative to it — a host at 2x whose
///   guest chased a 1x target would fall behind by a second every second
///   and seek forever.
///
/// 2.13.0 — ladder vs the published open-source ladders (research):
/// SyncStream uses <100 ms ignore / 100–500 ms nudge at 0.98×/1.02× /
/// >500 ms seek, RMHTube uses ≤500 ms settled / ±5% nudge / >2 s seek
/// with a 1.5 s seek cooldown, PeerMates uses ≤500 ms settled / ±8%
/// nudge to 3 s / one debounced seek above that. This app KEEPS
/// 150 ms / 750 ms / ±5%: tighter than the web ladders, because the room
/// is 2–6 phones on VLC (not 500 browser viewers) and a 500 ms dead band
/// is a visible lip-sync error on a phone held close — while the 750 ms
/// seek threshold (vs SyncStream's 500 ms) still keeps ordinary
/// 300–500 ms round-trips from seeking on every state. What IS adopted
/// from the research: the 1.5 s post-seek cooldown (RMHTube — never seek
/// twice into one slow seek), never seeking into a stall ([hostStalled]
/// freezes the target, RMHTube §6), and at most one correction per
/// evaluation tick (every implementation agrees).
///
/// Latency honesty (2.11.0): nothing here is zero-latency. A host action
/// reaches a guest in one relay round-trip (EMQX measured ~200 ms in the
/// 2.10.0 live test), and the numbers above are the correction budgets
/// once it arrives — the guest feels in step because actions publish on
/// the action, not on a timer, and the correction is immediate, not
/// because the network takes no time.

/// Seek when the guest is further than this from where the host is.
const int kSyncSeekThresholdMs = 750;

/// Nudge the rate when the drift is at least this, but below the seek
/// threshold. Smaller than this is jitter — leave the engine alone.
const int kSyncNudgeThresholdMs = 150;

/// How far the rate moves for a nudge: 5% faster to catch up, 5% slower to
/// fall back. Small enough to be inaudible on dialogue.
const double kSyncNudgeRateDelta = 0.05;

/// A host target that moved by at least this is a host action worth waking
/// the guest for — not a steady tick. Same value as [kSyncNudgeThresholdMs]
/// by design: a move smaller than the nudge band is jitter the guest's
/// next evaluation absorbs anyway, and a move at or above it is a seek or
/// a transport flip the guest must apply on receipt, not at its next
/// throttled evaluation. (2.11.0: was the 750 ms seek threshold — a host
/// seek of 200–750 ms then waited up to half a second for the guest's next
/// evaluation, which is a visible lag on a deliberate seek.)
const int kSyncNotifyThresholdMs = kSyncNudgeThresholdMs;

/// How far a position may jump past what the wall clock explains before it
/// counts as a seek. The host's engine ticks ~4x/s, so at 1x a tick advances
/// ~250 ms in ~250 ms of wall time and the excess is ~0; at 2x the excess
/// is ~250 ms a tick. A 400 ms excess is past both, and past tick jitter —
/// so a real seek (even a small forward one) is caught at once instead of
/// waiting up to a second for the next steady-state publish, while ordinary
/// playback (and a false positive, which only costs one extra publish of
/// the correct position) stays quiet. Needs the host's speed to be exact
/// (see [decideSync]'s `hostPlaybackSpeed`); without it, a 2x host with a
/// missed tick can exceed it and publish once more than needed — harmless.
const int kSyncSeekExcessMs = 400;

/// Where the host is right now, from its last stamped state.
///
/// Playing: the stamped position advanced by the time since the stamp, at
/// the host's playback speed. Paused: the frozen stamped position. Clamped
/// to the media (0 or negative [durationMs] means the duration is unknown
/// and no clamping happens). The one place the target math lives:
/// [decideSync], [decideResumeSync] and the service's resume target all
/// read it, so they can never disagree about where "live" is.
///
/// [hostStalled] (2.13.0): the host's engine is buffering — the target
/// freezes at the stamped position instead of advancing through the
/// stall (RMHTube §6: projecting through a stall runs the room ahead
/// and rubber-bands it back).
int liveTargetMs({
  required int hostPositionMs,
  required int hostTimestampMs,
  required int nowMs,
  required bool hostPlaying,
  double hostPlaybackSpeed = 1.0,
  required int durationMs,
  bool hostStalled = false,
}) {
  var target = hostPlaying && !hostStalled
      ? hostPositionMs +
            ((nowMs - hostTimestampMs) * hostPlaybackSpeed).round()
      : hostPositionMs;
  if (target < 0) target = 0;
  if (durationMs > 0 && target > durationMs) target = durationMs;
  return target;
}

/// What the guest should do about its current position.
enum SyncAction {
  /// Close enough — leave the engine alone.
  inSync,

  /// Slightly behind: play a touch faster until the gap closes.
  nudgeFaster,

  /// Slightly ahead: play a touch slower until the gap closes.
  nudgeSlower,

  /// Too far out: jump straight to the target.
  seek,
}

/// The outcome of one sync evaluation.
class SyncDecision {
  const SyncDecision({
    required this.action,
    required this.targetPositionMs,
    required this.rate,
  });

  /// What to do.
  final SyncAction action;

  /// Where playback should be, in milliseconds from the start of the media.
  final int targetPositionMs;

  /// The playback rate to run at: 1.0 normally, 1.05 / 0.95 while nudging.
  final double rate;

  @override
  bool operator ==(Object other) =>
      other is SyncDecision &&
      other.action == action &&
      other.targetPositionMs == targetPositionMs &&
      other.rate == rate;

  @override
  int get hashCode => Object.hash(action, targetPositionMs, rate);

  @override
  String toString() =>
      'SyncDecision($action, target=${targetPositionMs}ms, rate=$rate)';
}

/// Decides what a guest should do given the latest host state.
///
/// [hostPositionMs] is where the host was at [hostTimestampMs] (both
/// wall-clock milliseconds). [nowMs] is the guest's wall clock now, and
/// [localPositionMs] is where the guest's engine currently is. When the host
/// is playing, the target advances by the time since the host stamped the
/// state, at the host's speed; when paused, the target is the frozen host
/// position.
///
/// [durationMs] clamps the target to the media (0 or negative means the
/// duration is unknown and no clamping happens).
///
/// [hostPlaybackSpeed] is the host's engine speed (1.0 normally): the
/// guest's in-sync rate IS the host's speed, and nudges are relative to it
/// (1.05x / 0.95x of the host's speed, not of 1.0) — otherwise a guest
/// chasing a 2x host would play at 1x, fall behind a second every second,
/// and seek forever. Defaults to 1.0 for callers that do not know the
/// speed yet (the pre-2.11.0 behaviour).
SyncDecision decideSync({
  required int localPositionMs,
  required int hostPositionMs,
  required int hostTimestampMs,
  required int nowMs,
  required bool hostPlaying,
  required int durationMs,
  double hostPlaybackSpeed = 1.0,
  bool hostStalled = false,
}) {
  final target = liveTargetMs(
    hostPositionMs: hostPositionMs,
    hostTimestampMs: hostTimestampMs,
    nowMs: nowMs,
    hostPlaying: hostPlaying,
    hostPlaybackSpeed: hostPlaybackSpeed,
    durationMs: durationMs,
    hostStalled: hostStalled,
  );

  final driftMs = target - localPositionMs;
  final absDrift = driftMs.abs();

  if (absDrift > kSyncSeekThresholdMs) {
    return SyncDecision(
      action: SyncAction.seek,
      targetPositionMs: target,
      rate: hostPlaybackSpeed,
    );
  }
  if (absDrift >= kSyncNudgeThresholdMs) {
    final nudge = driftMs > 0
        ? hostPlaybackSpeed * (1.0 + kSyncNudgeRateDelta)
        : hostPlaybackSpeed * (1.0 - kSyncNudgeRateDelta);
    return SyncDecision(
      action: driftMs > 0 ? SyncAction.nudgeFaster : SyncAction.nudgeSlower,
      targetPositionMs: target,
      rate: nudge,
    );
  }
  return SyncDecision(
    action: SyncAction.inSync,
    targetPositionMs: target,
    rate: hostPlaybackSpeed,
  );
}

/// Decides what a guest that just RESUMED from a local pause should do.
///
/// A resume is not ordinary drift: the guest was deliberately frozen while
/// the host kept playing, so the gap is a jump back to live, not a glide.
/// Any gap at or above the nudge threshold ([kSyncNudgeThresholdMs]) seeks
/// straight to the host's current live position ([liveTargetMs]) at the
/// host's speed; below it the guest is already on live and plays on.
/// The caller applies the transport from the host state alongside the
/// decision (play when the host plays, stay paused when the host is paused)
/// — this function only answers "where, and how far to jump".
SyncDecision decideResumeSync({
  required int localPositionMs,
  required int hostPositionMs,
  required int hostTimestampMs,
  required int nowMs,
  required bool hostPlaying,
  required int durationMs,
  double hostPlaybackSpeed = 1.0,
  bool hostStalled = false,
}) {
  final target = liveTargetMs(
    hostPositionMs: hostPositionMs,
    hostTimestampMs: hostTimestampMs,
    nowMs: nowMs,
    hostPlaying: hostPlaying,
    hostPlaybackSpeed: hostPlaybackSpeed,
    durationMs: durationMs,
    hostStalled: hostStalled,
  );
  if ((target - localPositionMs).abs() >= kSyncNudgeThresholdMs) {
    return SyncDecision(
      action: SyncAction.seek,
      targetPositionMs: target,
      rate: hostPlaybackSpeed,
    );
  }
  return SyncDecision(
    action: SyncAction.inSync,
    targetPositionMs: target,
    rate: hostPlaybackSpeed,
  );
}

/// One peer heartbeat: where a room member was, and when they said so.
class HeartbeatSample {
  const HeartbeatSample({
    required this.positionMs,
    required this.receivedAtMs,
    this.playbackSpeed = 1.0,
  });

  /// Playback position in milliseconds, as reported by the peer.
  final int positionMs;

  /// Wall-clock milliseconds when this device received it.
  final int receivedAtMs;

  /// That peer's engine speed when it reported (1.0 when unknown, e.g.
  /// from an older client that does not send one): the position advances
  /// at this speed, not at 1x — otherwise a 2x peer's heartbeat
  /// under-advances and the rejoin adoption lands behind.
  final double playbackSpeed;

  /// Where the peer would be now if it kept playing from the heartbeat,
  /// at its own speed.
  int advancedTo(int nowMs) =>
      positionMs + ((nowMs - receivedAtMs) * playbackSpeed).round();
}

/// Where a rejoining host should resume the room.
///
/// The room does not rewind when its host comes back: the position is the
/// furthest any member has reached, advanced by the time since they reported
/// it. [heartbeats] are recent peer heartbeats (older than
/// [maxHeartbeatAgeMs] are ignored as stale); when nobody has reported
/// recently, the retained room state — itself advanced by elapsed time when
/// it was playing — is the answer.
///
/// Returns milliseconds from the start of the media, clamped at 0 and at
/// [durationMs] when the duration is known.
int adoptRejoinPosition({
  required List<HeartbeatSample> heartbeats,
  required int nowMs,
  required int retainedPositionMs,
  required int retainedTimestampMs,
  required bool retainedPlaying,
  required int durationMs,
  int maxHeartbeatAgeMs = 10000,
  double retainedPlaybackSpeed = 1.0,
}) {
  var best = retainedPlaying
      ? retainedPositionMs +
            ((nowMs - retainedTimestampMs) * retainedPlaybackSpeed).round()
      : retainedPositionMs;
  for (final heartbeat in heartbeats) {
    if (nowMs - heartbeat.receivedAtMs > maxHeartbeatAgeMs) continue;
    final advanced = heartbeat.advancedTo(nowMs);
    if (advanced > best) best = advanced;
  }
  if (best < 0) best = 0;
  if (durationMs > 0 && best > durationMs) best = durationMs;
  return best;
}

/// A 6-digit room code, 100000–999999.
///
/// The range is deliberate: a leading zero would be lost the moment the code
/// is read back as a number, so codes never start with one.
String generateOtp(Random random) =>
    (100000 + random.nextInt(900000)).toString();

/// Whether [input] is exactly six digits — the only shape a room code takes.
bool isValidOtp(String input) =>
    input.length == 6 && input.codeUnits.every((c) => c >= 0x30 && c <= 0x39);
