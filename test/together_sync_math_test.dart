import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';

void main() {
  group('decideSync', () {
    test('in sync within the 300 ms jitter band', () {
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

    test('nudges the rate for a 300–1500 ms drift instead of seeking', () {
      final behind = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_800,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(behind.action, SyncAction.nudgeFaster);
      expect(behind.rate, 1.05);
      expect(behind.targetPositionMs, 60_800);

      final ahead = decideSync(
        localPositionMs: 61_000,
        hostPositionMs: 60_200,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(ahead.action, SyncAction.nudgeSlower);
      expect(ahead.rate, 0.95);
    });

    test('seeks when drift is over 1500 ms', () {
      final decision = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 65_000,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 65_000);
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

    test('boundary: exactly 300 ms nudges, exactly 1500 ms does not seek', () {
      final atNudge = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 60_300,
        hostTimestampMs: 1_000_000,
        nowMs: 1_000_000,
        hostPlaying: false,
        durationMs: 600_000,
      );
      expect(atNudge.action, SyncAction.nudgeFaster);

      final atSeekEdge = decideSync(
        localPositionMs: 60_000,
        hostPositionMs: 61_500,
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

    test('chat message round-trip keeps reply and image fields', () {
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
      expect(decoded.isImage, isFalse);
      expect(decoded.quoteText, 'that scene 😮');
    });
  });
}
