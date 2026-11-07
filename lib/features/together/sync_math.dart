import 'dart:math';

/// Pure sync math for Together watch parties.
///
/// Kept free of Flutter, MQTT and the player engine so it can be unit-tested
/// in isolation. Everything here is arithmetic on milliseconds; the caller
/// owns clocks, timers and the engine.
///
/// The sync contract, in one place:
/// * the host is the only clock that matters — a guest never publishes a
///   state of its own, it only chases the host's;
/// * drift under 300 ms is "in sync" (network jitter, not worth touching);
/// * drift of 300–1500 ms is fixed by nudging the playback rate a touch
///   (inaudible, no visible jump);
/// * drift over 1500 ms is fixed by seeking — a jump that far is already
///   noticeable, so landing exactly beats gliding.
/// * when the host is paused there is no clock to chase: the target is the
///   host's frozen position, and only a seek can fix a gap over 1500 ms.

/// Seek when the guest is further than this from where the host is.
const int kSyncSeekThresholdMs = 1500;

/// Nudge the rate when the drift is at least this, but below the seek
/// threshold. Smaller than this is jitter — leave the engine alone.
const int kSyncNudgeThresholdMs = 300;

/// How far the rate moves for a nudge: 5% faster to catch up, 5% slower to
/// fall back. Small enough to be inaudible on dialogue.
const double kSyncNudgeRateDelta = 0.05;

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
/// state; when paused, the target is the frozen host position.
///
/// [durationMs] clamps the target to the media (0 or negative means the
/// duration is unknown and no clamping happens).
SyncDecision decideSync({
  required int localPositionMs,
  required int hostPositionMs,
  required int hostTimestampMs,
  required int nowMs,
  required bool hostPlaying,
  required int durationMs,
}) {
  var target = hostPlaying
      ? hostPositionMs + (nowMs - hostTimestampMs)
      : hostPositionMs;
  if (target < 0) target = 0;
  if (durationMs > 0 && target > durationMs) target = durationMs;

  final driftMs = target - localPositionMs;
  final absDrift = driftMs.abs();

  if (absDrift > kSyncSeekThresholdMs) {
    return SyncDecision(
      action: SyncAction.seek,
      targetPositionMs: target,
      rate: 1.0,
    );
  }
  if (absDrift >= kSyncNudgeThresholdMs) {
    return SyncDecision(
      action: driftMs > 0 ? SyncAction.nudgeFaster : SyncAction.nudgeSlower,
      targetPositionMs: target,
      rate: driftMs > 0 ? 1.0 + kSyncNudgeRateDelta : 1.0 - kSyncNudgeRateDelta,
    );
  }
  return SyncDecision(
    action: SyncAction.inSync,
    targetPositionMs: target,
    rate: 1.0,
  );
}

/// One peer heartbeat: where a room member was, and when they said so.
class HeartbeatSample {
  const HeartbeatSample({
    required this.positionMs,
    required this.receivedAtMs,
  });

  /// Playback position in milliseconds, as reported by the peer.
  final int positionMs;

  /// Wall-clock milliseconds when this device received it.
  final int receivedAtMs;

  /// Where the peer would be now if it kept playing from the heartbeat.
  int advancedTo(int nowMs) => positionMs + (nowMs - receivedAtMs);
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
}) {
  var best = retainedPlaying
      ? retainedPositionMs + (nowMs - retainedTimestampMs)
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
