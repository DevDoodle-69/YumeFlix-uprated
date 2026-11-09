import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';

void main() {
  group('decideSync', () {
    test('in sync within the 150 ms jitter band', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_100,
        hostPlaying: true,
        durationMs: 600_000,
      );
      // Host advanced 100 ms since stamping; drift is 100 ms.
      expect(decision.action, SyncAction.inSync);
      expect(decision.rate, 1.0);
    });

    test('nudges the rate for a 150–750 ms drift instead of seeking', () {
      final behind = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_500,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(behind.action, SyncAction.nudgeFaster);
      expect(behind.rate, 1.05);
      expect(behind.targetPositionMs, 60_500);

      final ahead = decideSync(
        localPositionMs: 60_700,
        hostPositionMs: 60_200,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(ahead.action, SyncAction.nudgeSlower);
      expect(ahead.rate, 0.95);
    });

    test('seeks when drift is over 750 ms', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 61_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 61_000);
      expect(decision.rate, 1.0);
    });

    test('advances the target by elapsed time while the host is playing', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_005_000, // 5 s later
        hostPlaying: true,
        durationMs: 600_000,
      );
      // Target is 65_000; local is 60_000 — a 5 s gap means a seek.
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 65_000);
    });

    test('freezes the target while the host is paused', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_005_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.inSync);
      expect(decision.targetPositionMs, 60_000);
    });

    test('clamps the target to the duration and to zero', () {
      final pastEnd = decideSync(
        localPositionMs: 599_000,
        hostPositionMs: 599_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_005_000,
        hostPlaying: true,
        durationMs: 600_000,
      );
      expect(pastEnd.targetPositionMs, 600_000);

      final negative = decideSync(
        localPositionMs: 0,
        hostPositionMs: -500,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(negative.targetPositionMs, 0);
    });

    test('boundary: exactly 150 ms nudges, exactly 750 ms does not seek', () {
      final atNudge = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_150,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(atNudge.action, SyncAction.nudgeFaster);

      final atSeekEdge = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_750,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(atSeekEdge.action, SyncAction.nudgeFaster);
    });
  });

  group('OTP generation', () {
    test('always six digits, never a leading zero', () {
      final random = Random(42);
      for (var i = 0; i < 1000; i++) {
        final otp = generateOtp(random);
        expect(otp.length, 6);
        expect(isValidOtp(otp), isTrue);
        expect(otp.startsWith('0'), isFalse);
        expect(int.parse(otp), inInclusiveRange(100000, 999999));
      }
    });

    test('isValidOtp rejects anything that is not six digits', () {
      expect(isValidOtp('123456'), isTrue);
      expect(isValidOtp('12345'), isFalse);
      expect(isValidOtp('1234567'), isFalse);
      expect(isValidOtp('12345a'), isFalse);
      expect(isValidOtp(''), isFalse);
      expect(isValidOtp(' 12345'), isFalse);
    });
  });

  group('adoptRejoinPosition', () {
    test('adopts the furthest heartbeat advanced by elapsed time', () {
      final adopted = adoptRejoinPosition(
        heartbeats: const [
          // Peer A was at 120 s, 2 s ago: now ~122 s.
          HeartbeatSample(positionMs: 120_000, receivedAtMs: 1_000_000),
          // Peer B was at 90 s, 1 s ago: now ~91 s.
          HeartbeatSample(positionMs: 90_000, receivedAtMs: 1_001_000),
        ],
        nowMs: 1_002_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 999_000,
        retainedPlaying: true,
        durationMs: 600_000,
      );
      expect(adopted, 122_000);
    });

    test('falls back to the retained state advanced by elapsed time', () {
      final adopted = adoptRejoinPosition(
        heartbeats: const [],
        nowMs: 1_005_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 1_000_000,
        retainedPlaying: true,
        durationMs: 600_000,
      );
      expect(adopted, 105_000);
    });

    test('ignores stale heartbeats older than the window', () {
      final adopted = adoptRejoinPosition(
        heartbeats: const [
          // 30 s old: stale, must not drag the room forward.
          HeartbeatSample(positionMs: 500_000, receivedAtMs: 970_000),
        ],
        nowMs: 1_000_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 1_000_000,
        retainedPlaying: false,
        durationMs: 600_000,
      );
      expect(adopted, 100_000);
    });

    test('does not advance a paused retained state, and clamps to duration', () {
      final paused = adoptRejoinPosition(
        heartbeats: const [],
        nowMs: 1_010_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 1_000_000,
        retainedPlaying: false,
        durationMs: 600_000,
      );
      expect(paused, 100_000);

      final clamped = adoptRejoinPosition(
        heartbeats: const [
          HeartbeatSample(positionMs: 599_000, receivedAtMs: 999_000),
        ],
        nowMs: 1_005_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 1_000_000,
        retainedPlaying: true,
        durationMs: 600_000,
      );
      expect(clamped, 600_000);
    });
  });

  group('room status messages', () {
    test('status round-trips with media, and labels are guest-facing', () {
      expect(
        TogetherRoomStatus.hostBrowsing.label,
        'Host is still finding a movie…',
      );
      expect(
        TogetherRoomStatus.hostPickedTitle.label,
        'Host picked a title',
      );
      expect(TogetherRoomStatus.hostPlaying.label, 'Host is playing');
      expect(TogetherRoomStatus.hostPaused.label, 'Host paused');
      expect(
        TogetherRoomStatus.fromWire('hostPickedTitle'),
        TogetherRoomStatus.hostPickedTitle,
      );
      expect(TogetherRoomStatus.fromWire('nope'), isNull);
      expect(TogetherRoomStatus.fromWire(null), isNull);

      const message = TogetherRoomStatusMessage(
        status: TogetherRoomStatus.hostPickedTitle,
        media: TogetherMediaIdentity(
          title: 'Dune',
          tmdbType: 'movie',
          tmdbId: 693134,
        ),
        senderId: 'yumeflix-ab12cd34',
        timestampMs: 1_000_000,
      );
      final decoded = TogetherRoomStatusMessage.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(message.toJson())) as Map,
        ),
      );
      expect(decoded.status, TogetherRoomStatus.hostPickedTitle);
      expect(decoded.media?.title, 'Dune');
      expect(decoded.media?.tmdbId, 693134);
      expect(decoded.senderId, 'yumeflix-ab12cd34');

      const bare = TogetherRoomStatusMessage(
        status: TogetherRoomStatus.hostBrowsing,
        senderId: 'yumeflix-ab12cd34',
        timestampMs: 1_000_000,
      );
      final decodedBare = TogetherRoomStatusMessage.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(bare.toJson())) as Map,
        ),
      );
      expect(decodedBare.status, TogetherRoomStatus.hostBrowsing);
      expect(decodedBare.media, isNull);
    });

    test('an unknown status value throws instead of inventing one', () {
      expect(
        () => TogetherRoomStatusMessage.fromJson(<String, dynamic>{
          'kind': 'status',
          'status': 'hostDancing',
          'senderId': 'yumeflix-1',
          'timestampMs': 1,
        }),
        throwsFormatException,
      );
    });
  });

  group('presence events', () {
    test('join and leave round-trip', () {
      const joined = TogetherPresenceEvent(
        senderId: 'yumeflix-99',
        role: 'guest',
        joined: true,
        timestampMs: 1_000_000,
      );
      final decodedJoined = TogetherPresenceEvent.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(joined.toJson())) as Map,
        ),
      );
      expect(decodedJoined.senderId, 'yumeflix-99');
      expect(decodedJoined.role, 'guest');
      expect(decodedJoined.joined, isTrue);

      const left = TogetherPresenceEvent(
        senderId: 'yumeflix-99',
        role: 'guest',
        joined: false,
        timestampMs: 1_001_000,
      );
      final decodedLeft = TogetherPresenceEvent.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(left.toJson())) as Map,
        ),
      );
      expect(decodedLeft.joined, isFalse);
    });
  });

  group('room state JSON round-trip', () {
    test('a retained state survives encode/decode intact', () {
      const state = TogetherRoomState(
        media: TogetherMediaIdentity(
          title: 'Dune',
          tmdbType: 'movie',
          tmdbId: 693134,
          posterUrl: 'https://example.invalid/poster.jpg',
        ),
        positionMs: 123_456,
        durationMs: 600_000,
        playing: true,
        hostTimestampMs: 1_000_000,
        sequence: 7,
        hostId: 'yumeflix-ab12cd34',
      );
      final decoded = TogetherRoomState.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(state.toJson())) as Map,
        ),
      );
      expect(decoded.media.title, 'Dune');
      expect(decoded.media.tmdbId, 693134);
      expect(decoded.positionMs, 123_456);
      expect(decoded.playing, isTrue);
      expect(decoded.sequence, 7);
      expect(
        decoded.targetPositionMs(nowMs: 1_002_000),
        125_456,
      );
    });

    test('chat message round-trip keeps reply fields', () {
      const message = TogetherChatMessage(
        id: 'yumeflix-1-1',
        senderId: 'yumeflix-1',
        senderLabel: 'Friend',
        text: 'that scene 😮',
        replyToId: 'yumeflix-2-0',
        replyToText: 'here it comes',
        timestampMs: 1_000_000,
      );
      final decoded = TogetherChatMessage.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(message.toJson())) as Map,
        ),
      );
      expect(decoded.text, 'that scene 😮');
      expect(decoded.replyToId, 'yumeflix-2-0');
      expect(decoded.replyToText, 'here it comes');
      expect(decoded.quoteText, 'that scene 😮');
    });
  });

  group('liveTargetMs', () {
    test('advances a playing stamp at the host speed', () {
      expect(
        liveTargetMs(
          hostPositionMs: 60_000,
          hostTimestampMs: 1_000_000,
          nowMs: 1_002_000,
          hostPlaying: true,
          durationMs: 600_000,
        ),
        62_000,
      );
      expect(
        liveTargetMs(
          hostPositionMs: 60_000,
          hostTimestampMs: 1_000_000,
          nowMs: 1_002_000,
          hostPlaying: true,
          hostPlaybackSpeed: 2.0,
          durationMs: 600_000,
        ),
        64_000,
      );
    });

    test('freezes a paused stamp and clamps to the duration', () {
      expect(
        liveTargetMs(
          hostPositionMs: 60_000,
          hostTimestampMs: 1_000_000,
          nowMs: 1_010_000,
          hostPlaying: false,
          durationMs: 600_000,
        ),
        60_000,
      );
      expect(
        liveTargetMs(
          hostPositionMs: 599_000,
          hostTimestampMs: 1_000_000,
          nowMs: 1_005_000,
          hostPlaying: true,
          durationMs: 600_000,
        ),
        600_000,
      );
      expect(
        liveTargetMs(
          hostPositionMs: -100,
          hostTimestampMs: 1_000_000,
          nowMs: 1_000_000,
          hostPlaying: false,
          durationMs: 600_000,
        ),
        0,
      );
    });
  });

  group('decideResumeSync', () {
    test('a resumed guest seeks straight to the live position', () {
      // Guest paused at 60 s; the host played on to 70 s. Resume must
      // land on the host's CURRENT position, not the paused one.
      final decision = decideResumeSync(
        localPositionMs: 60_000,
        hostPositionMs: 65_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_005_000,
        hostPlaying: true,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 70_000);
    });

    test('a resumed guest already at the live position stays in sync', () {
      final decision = decideResumeSync(
        localPositionMs: 65_000,
        hostPositionMs: 65_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: true,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.inSync);
    });

    test('resume to a paused host seeks to the frozen position', () {
      final decision = decideResumeSync(
        localPositionMs: 60_000,
        hostPositionMs: 65_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_010_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 65_000);
    });

    test('resume never nudges — it seeks or stays put', () {
      // 200 ms behind is inside the nudge band for decideSync, but a
      // resume is a jump-cut, not a glide: no half-speed catch-up.
      final decision = decideResumeSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_200,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 60_200);
    });
  });

  group('decideSync at host speed', () {
    test('a 2x host advances the target twice as fast', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_001_000,
        hostPlaying: true,
        hostPlaybackSpeed: 2.0,
        durationMs: 600_000,
      );
      // Target is 62 s; local is 60 s — a 2 s gap means a seek.
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 62_000);
    });

    test('in-sync rate follows the host speed, nudge scales with it', () {
      final inSync = decideSync(
        localPositionMs: 62_000,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_001_000,
        hostPlaying: true,
        hostPlaybackSpeed: 2.0,
        durationMs: 600_000,
      );
      expect(inSync.action, SyncAction.inSync);
      expect(inSync.rate, 2.0);

      final nudge = decideSync(
        localPositionMs: 61_700,
        hostPositionMs: 60_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_001_000,
        hostPlaying: true,
        hostPlaybackSpeed: 2.0,
        durationMs: 600_000,
      );
      // 300 ms behind at 2x: nudge faster at 2.0 x 1.05.
      expect(nudge.action, SyncAction.nudgeFaster);
      expect(nudge.rate, closeTo(2.1, 0.001));
    });
  });

  group('heartbeat speed', () {
    test('a 2x heartbeat advances at twice the rate', () {
      const sample = HeartbeatSample(
        positionMs: 60_000,
        receivedAtMs: 1_000_000,
        playbackSpeed: 2.0,
      );
      expect(sample.advancedTo(1_001_000), 62_000);
      const normal = HeartbeatSample(
        positionMs: 60_000,
        receivedAtMs: 1_000_000,
      );
      expect(normal.advancedTo(1_001_000), 61_000);
    });

    test('adoptRejoinPosition advances a retained 2x state at 2x', () {
      final adopted = adoptRejoinPosition(
        heartbeats: const [],
        nowMs: 1_005_000,
        retainedPositionMs: 100_000,
        retainedTimestampMs: 1_000_000,
        retainedPlaying: true,
        retainedPlaybackSpeed: 2.0,
        durationMs: 600_000,
      );
      expect(adopted, 110_000);
    });
  });

  group('drift-correction convergence (2.11.0 stability evidence)', () {
    // A guest chasing a host that plays at [hostSpeed], fed a freshly
    // stamped state every [stepMs] after a one-way [latencyMs] (plus
    // deterministic jitter), with the guest clock skewed by
    // [clockSkewMs] against the host's. The guest applies [decideSync]
    // exactly as the player hook does: a seek jumps to the stamped
    // target, a nudge runs the player at the returned rate until the
    // next decision. Returns the seek count, whether any two seeks
    // pulled in opposite directions (oscillation), and the worst
    // real drift (guest vs the host's TRUE position) after the first
    // 2 s of settling.
    ({int seeks, bool oscillated, int maxDriftAfterSettleMs, int finalDriftMs})
    simulate({
      required double hostSpeed,
      required int initialGuestMs,
      required int hostStartMs,
      required int latencyMs,
      required int jitterMs,
      required int clockSkewMs,
      int stepMs = 100,
      int steps = 300,
      int durationMs = 600_000,
    }) {
      var guestMs = initialGuestMs;
      var rate = hostSpeed;
      var seeks = 0;
      var lastSeekDirection = 0;
      var oscillated = false;
      var maxDriftAfterSettleMs = 0;
      var finalDriftMs = 0;
      final random = Random(1234);
      for (var step = 0; step < steps; step++) {
        final tRecv = step * stepMs;
        final jitter = random.nextInt(jitterMs * 2 + 1) - jitterMs;
        final tSend = tRecv - latencyMs - jitter;
        final hostTrueAtSend = hostStartMs + (tSend * hostSpeed).round();
        final decision = decideSync(
          localPositionMs: guestMs,
          hostPositionMs: hostTrueAtSend,
          hostTimestampMs: tSend,
          // The guest reads its own (skewed) clock for "now".
          nowMs: tRecv + clockSkewMs,
          hostPlaying: true,
          durationMs: durationMs,
          hostPlaybackSpeed: hostSpeed,
        );
        if (decision.action == SyncAction.seek) {
          final direction = decision.targetPositionMs >= guestMs ? 1 : -1;
          if (lastSeekDirection != 0 && direction != lastSeekDirection) {
            oscillated = true;
          }
          lastSeekDirection = direction;
          seeks++;
          guestMs = decision.targetPositionMs;
        }
        rate = decision.rate;
        // Both players run for one step at their current rates.
        guestMs += (rate * stepMs).round();
        final hostTrueAtEnd =
            hostStartMs + ((tRecv + stepMs) * hostSpeed).round();
        final driftAtEnd = (hostTrueAtEnd - guestMs).abs();
        finalDriftMs = driftAtEnd;
        if (step * stepMs >= 2000) {
          if (driftAtEnd > maxDriftAfterSettleMs) {
            maxDriftAfterSettleMs = driftAtEnd;
          }
        }
      }
      return (
        seeks: seeks,
        oscillated: oscillated,
        maxDriftAfterSettleMs: maxDriftAfterSettleMs,
        finalDriftMs: finalDriftMs,
      );
    }

    test('1x, 5 s behind, realistic latency: one seek, then in step', () {
      final result = simulate(
        hostSpeed: 1.0,
        initialGuestMs: 55_000,
        hostStartMs: 60_000,
        latencyMs: 100,
        jitterMs: 40,
        clockSkewMs: 0,
      );
      expect(result.seeks, 1);
      expect(result.oscillated, isFalse);
      expect(result.maxDriftAfterSettleMs, lessThan(150));
    });

    test('2x host, 5 s behind: one seek, then in step at 2x', () {
      final result = simulate(
        hostSpeed: 2.0,
        initialGuestMs: 55_000,
        hostStartMs: 60_000,
        latencyMs: 100,
        jitterMs: 40,
        clockSkewMs: 0,
      );
      expect(result.seeks, 1);
      expect(result.oscillated, isFalse);
      expect(result.maxDriftAfterSettleMs, lessThan(150));
    });

    test('400 ms behind (nudge band): no seek, glides into step', () {
      // A 400 ms drift closes at 5% of 1x = 50 ms/s, so the glide takes
      // ~5 s (400 -> 150) — the drift after 2 s is still ~300 ms, which
      // is the glide working, not instability. Assert the end state.
      final result = simulate(
        hostSpeed: 1.0,
        initialGuestMs: 59_600,
        hostStartMs: 60_000,
        latencyMs: 100,
        jitterMs: 40,
        clockSkewMs: 0,
      );
      expect(result.seeks, 0);
      expect(result.oscillated, isFalse);
      expect(result.finalDriftMs, lessThan(150));
    });

    test('100 ms clock skew: no seek, drift stays bounded', () {
      // 100 ms of skew is the normal case (phones rarely agree to the
      // millisecond). The guest settles ~100 ms from the host's true
      // position — inside the 150 ms band — without a single seek.
      // This is why the nudge threshold cannot go below ~150 ms: a
      // tighter band would sit inside the skew + jitter noise and the
      // guest would nudge on every tick.
      final result = simulate(
        hostSpeed: 1.0,
        initialGuestMs: 60_000,
        hostStartMs: 60_000,
        latencyMs: 100,
        jitterMs: 40,
        clockSkewMs: 100,
      );
      expect(result.seeks, 0);
      expect(result.oscillated, isFalse);
      expect(result.maxDriftAfterSettleMs, lessThan(250));
    });

    test('160 ms clock skew: still no seek loop, offset stays bounded', () {
      final result = simulate(
        hostSpeed: 1.0,
        initialGuestMs: 60_000,
        hostStartMs: 60_000,
        latencyMs: 100,
        jitterMs: 40,
        clockSkewMs: 160,
      );
      expect(result.seeks, 0);
      expect(result.oscillated, isFalse);
      expect(result.maxDriftAfterSettleMs, lessThan(350));
    });
  });
}
