import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.13.0 wait-together + Bug 2 + clock sync + high-latency sync, offline
/// through the service's test seams (publish sink + inbound payload
/// feed) — no relay, no network.
///
/// The contract: the host's playback is HELD at the shared start
/// position until the first guest's player reports ready — the host
/// cannot play, resume or seek past the hold, and the moment the first
/// guest is ready everyone starts together from the same position with
/// no extra tap. A guest that never gets ready releases the host after
/// the 20 s bound with a short named notice, and the host starts with a
/// tap; a guest leaving mid-movie never re-freezes the host; a host
/// alone stays held until the 45-minute lifetime ends. The guest's view
/// of host state is fresh (a stale heartbeat or status never overwrites
/// a fresher retained state), and the clock-offset estimate keeps drift
/// correction converging at 300–500 ms RTT.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService([int seed = 42]) =>
      TogetherService(random: Random(seed), preferences: null);

  /// "The Garden of Words" — the live-test title from the 2.12.0
  /// failure, as a movie identity with the host's provider + source.
  const gardenMedia = TogetherMediaIdentity(
    title: 'The Garden of Words',
    tmdbType: 'movie',
    tmdbId: 999001,
    posterUrl: 'https://example.invalid/garden.jpg',
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/garden',
    episodeUrl: 'https://example.invalid/garden-play',
    source: 'Server 1',
  );

  const otherMedia = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/dune',
    episodeUrl: 'https://example.invalid/dune-play',
    source: 'Server 1',
  );

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    int? hostTimestampMs,
    bool held = false,
    bool stalled = false,
    String hostId = 'host-1',
  }) {
    final stamp =
        hostTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 2763000,
        playing: playing,
        hostTimestampMs: stamp,
        sequence: sequence,
        hostId: hostId,
        held: held,
        stalled: stalled,
      ).toJson(),
    });
  }

  String presencePayload({
    required String senderId,
    String role = 'guest',
    bool joined = true,
    String? displayName,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'presence',
    'senderId': senderId,
    'role': role,
    'joined': joined,
    'timestampMs': DateTime.now().millisecondsSinceEpoch,
    'displayName': ?displayName,
  });

  String readyPayload({
    required String senderId,
    required bool ready,
    String? displayName,
    String? titleKey,
    String? note,
  }) => jsonEncode(
    TogetherGuestReadyMessage(
      ready: ready,
      senderId: senderId,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      displayName: displayName,
      titleKey: titleKey,
      note: note,
    ).toJson(),
  );

  String heartbeatPayload({
    String senderId = 'host-1',
    String status = 'hostPlaying',
    int? timestampMs,
    int positionMs = 443000,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'heartbeat',
    'senderId': senderId,
    'role': 'host',
    'positionMs': positionMs,
    'timestampMs':
        timestampMs ?? DateTime.now().millisecondsSinceEpoch,
    'status': status,
    'media': gardenMedia.toJson(),
  });

  String statusPayload({
    String status = 'hostPaused',
    int? timestampMs,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'status',
    'status': status,
    'media': gardenMedia.toJson(),
    'senderId': 'host-1',
    'timestampMs':
        timestampMs ?? DateTime.now().millisecondsSinceEpoch,
  });

  /// Host in a room, held at Start (no guest ready yet), with the
  /// publish sink attached. Returns the (host, captured-publishes) pair.
  (TogetherService, List<Map<String, dynamic>>) heldHostWithSink() {
    final host = newService();
    final published = <Map<String, dynamic>>[];
    host.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    host.attachMedia(gardenMedia);
    host.goLive(positionMs: 0, durationMs: 2763000, playing: true);
    return (host, published);
  }

  List<Map<String, dynamic>> statesOf(List<Map<String, dynamic>> published) =>
      published.where((p) => p['kind'] == 'state').toList();

  group('wait-together hold', () {
    test('host Start holds playback with no guest in the room', () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      expect(host.hostPlaybackHeld, isTrue);
      expect(host.roomStatus, TogetherRoomStatus.hostWaitingGuests);
      expect(
        host.holdWaitingLabel,
        'Waiting for a guest to join…',
      );
      final states = statesOf(published);
      expect(states, isNotEmpty);
      expect(states.last['playing'], isFalse);
      expect(states.last['held'], isTrue);
      expect(states.last['positionMs'], 0);
      expect(states.last['_retain'], isTrue);
    });

    test('host cannot play or seek past the hold', () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      // A play tap while held: the service never publishes playing.
      host.reportLocalPlayback(
        positionMs: 5000,
        durationMs: 2763000,
        playing: true,
      );
      // A seek past the hold position: the position never advances.
      host.reportLocalPlayback(
        positionMs: 30000,
        durationMs: 2763000,
        playing: false,
      );
      final states = statesOf(published);
      expect(states.every((s) => s['playing'] == false), isTrue);
      expect(
        states.every((s) => (s['positionMs'] as int) <= 500),
        isTrue,
      );
      expect(host.hostPlaybackHeld, isTrue);
    });

    test('host alone stays held — no guest, no expiry', () {
      fakeAsync((async) {
        final (host, _) = heldHostWithSink();
        addTearDown(host.dispose);
        // A whole minute with no guest: the bound timer is only armed
        // once a guest is in the room, so a host alone is never
        // released by the clock — the room is for watching together.
        async.elapse(const Duration(minutes: 1));
        expect(host.hostPlaybackHeld, isTrue);
        expect(host.holdExpired, isFalse);
        expect(host.holdNotice, isNull);
      });
    });

    test('first guest joins and reports ready — everyone starts together',
        () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      expect(host.guestCount, 1);
      expect(
        host.holdWaitingLabel,
        'Waiting for sonali to join playback…',
      );
      expect(host.hostPlaybackHeld, isTrue);

      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-1',
          ready: true,
          displayName: 'sonali',
          titleKey: togetherTitleKey(gardenMedia),
        ),
      );
      expect(host.hostPlaybackHeld, isFalse);
      expect(host.holdReleaseWasReady, isTrue);
      expect(host.readyGuestNames, contains('sonali'));
      final states = statesOf(published);
      expect(states.last['playing'], isTrue);
      expect(states.last['held'] != true, isTrue);
      // Released at the hold position — host and guest start from the
      // same point, in sync, with no extra tap from anyone.
      expect(states.last['positionMs'], 0);
    });

    test('guest ready for the wrong title does not release the hold', () {
      final (host, _) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-1',
          ready: true,
          displayName: 'sonali',
          titleKey: togetherTitleKey(otherMedia),
        ),
      );
      expect(host.hostPlaybackHeld, isTrue);
    });

    test('guest joins but never ready — bound expires, host notified, '
        'host can start anyway', () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      expect(host.hostPlaybackHeld, isTrue);
      host.debugExpireHoldForTest();
      expect(host.hostPlaybackHeld, isFalse);
      expect(host.holdExpired, isTrue);
      expect(host.holdReleaseWasReady, isFalse);
      expect(host.holdNotice, contains('sonali'));
      // The host starts with a tap — never auto-played on expiry.
      published.clear();
      host.reportLocalPlayback(
        positionMs: 0,
        durationMs: 2763000,
        playing: true,
      );
      final states = statesOf(published);
      expect(states.last['playing'], isTrue);
      expect(states.last['held'] != true, isTrue);
    });

    test('guest leaving mid-movie does not re-freeze the host', () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-1',
          ready: true,
          titleKey: togetherTitleKey(gardenMedia),
        ),
      );
      expect(host.hostPlaybackHeld, isFalse);
      // The guest leaves mid-movie.
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', joined: false),
      );
      published.clear();
      host.reportLocalPlayback(
        positionMs: 10000,
        durationMs: 2763000,
        playing: true,
      );
      final states = statesOf(published);
      expect(states, isNotEmpty);
      expect(states.last['playing'], isTrue);
      expect(states.last['held'] != true, isTrue);
      expect(host.hostPlaybackHeld, isFalse);
    });

    test('two guests join at once — first ready releases, second '
        'catches up at the live point', () {
      final (host, _) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-2', displayName: 'arjun'),
      );
      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-1',
          ready: true,
          titleKey: togetherTitleKey(gardenMedia),
        ),
      );
      expect(host.hostPlaybackHeld, isFalse);
      // The second guest's readiness changes nothing about the hold.
      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-2',
          ready: true,
          titleKey: togetherTitleKey(gardenMedia),
        ),
      );
      expect(host.hostPlaybackHeld, isFalse);
      expect(host.readyGuestNames, containsAll(['sonali', 'arjun']));
    });
  });

  group('Enter + readiness reporting (service half)', () {
    test('Enter request is a monotonic counter the coordinator watches',
        () {
      final guest = newService();
      addTearDown(guest.dispose);
      expect(guest.guestEnterRequestId, 0);
      guest.requestGuestEnter();
      expect(guest.guestEnterRequestId, 1);
      guest.requestGuestEnter();
      expect(guest.guestEnterRequestId, 2);
    });

    test('progress and diagnostics round-trip to the screen', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.setGuestAutoOpenProgress('Getting the stream…');
      guest.setGuestAutoOpenDiagnostics('Title: The Garden of Words');
      expect(guest.guestAutoOpenProgress, 'Getting the stream…');
      expect(
        guest.guestAutoOpenDiagnostics,
        'Title: The Garden of Words',
      );
      guest.setGuestAutoOpenProgress(null);
      expect(guest.guestAutoOpenProgress, isNull);
    });

    test('guest ready report publishes guest-ready with title + note', () {
      final guest = newService();
      addTearDown(guest.dispose);
      final published = <Map<String, dynamic>>[];
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.reportGuestReady(
        false,
        titleKey: togetherTitleKey(gardenMedia),
        note: 'Couldn’t find this title.',
      );
      final ready =
          published.lastWhere((p) => p['kind'] == 'guest-ready');
      expect(ready['ready'], isFalse);
      expect(ready['titleKey'], togetherTitleKey(gardenMedia));
      expect(ready['note'], 'Couldn’t find this title.');
      // A duplicate report is not re-published.
      published.clear();
      guest.reportGuestReady(
        false,
        titleKey: togetherTitleKey(gardenMedia),
        note: 'Couldn’t find this title.',
      );
      expect(
        published.where((p) => p['kind'] == 'guest-ready'),
        isEmpty,
      );
    });
  });

  group('Bug 2 — stale host state', () {
    test('guest joining a live-playing room sees Host playing + live '
        'position', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      // The live-test moment: host playing at 7:23 / 46:03.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: gardenMedia,
          sequence: 5,
          positionMs: 443000,
          playing: true,
        ),
      );
      expect(guest.isLive, isTrue);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      expect(guest.roomState?.positionMs, 443000);
      final target = guest.hostLiveTargetMs;
      expect(target, isNotNull);
      // Projected forward from the stamp: at least the anchor, never
      // behind it, and within a second of it (just received).
      expect(target! >= 443000, isTrue);
      expect(target - 443000 < 1000, isTrue);
    });

    test('stale heartbeat after a fresher state does not flip the guest',
        () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: gardenMedia,
          sequence: 5,
          positionMs: 443000,
          playing: true,
          hostTimestampMs: stamp,
        ),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      // A heartbeat re-asserting the OLD paused status (stamped before
      // the state the guest already holds) must not pin the guest on
      // "Host paused" — this is the 2.12.0 live-test failure.
      guest.debugReceivePayloadForTest(
        heartbeatPayload(status: 'hostPaused', timestampMs: stamp - 5000),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('stale status after a fresher state does not flip the guest', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: gardenMedia,
          sequence: 5,
          positionMs: 443000,
          playing: true,
          hostTimestampMs: stamp,
        ),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      guest.debugReceivePayloadForTest(
        statusPayload(status: 'hostPaused', timestampMs: stamp - 5000),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('host pause then resume updates the guest at once', () {
      final (host, published) = heldHostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-1', displayName: 'sonali'),
      );
      host.debugReceivePayloadForTest(
        readyPayload(
          senderId: 'guest-1',
          ready: true,
          titleKey: togetherTitleKey(gardenMedia),
        ),
      );
      final guest = newService(43);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      // Wire host -> guest through the captured publishes.
      void deliverLastState() {
        final state = statesOf(published).last;
        guest.debugReceivePayloadForTest(jsonEncode(state));
      }

      // Deliver the release state first (it was published before the
      // clear below): the guest lands on the live, playing room.
      deliverLastState();
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      published.clear();
      host.reportLocalPlayback(
        positionMs: 12000,
        durationMs: 2763000,
        playing: false,
      );
      deliverLastState();
      expect(guest.roomStatus, TogetherRoomStatus.hostPaused);
      expect(guest.roomState?.positionMs, 12000);
      host.reportLocalPlayback(
        positionMs: 12000,
        durationMs: 2763000,
        playing: true,
      );
      deliverLastState();
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('reconnect resync applies the retained state', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final first = statePayload(
        media: gardenMedia,
        sequence: 5,
        positionMs: 443000,
        playing: true,
      );
      guest.debugReceivePayloadForTest(first);
      expect(guest.roomState?.positionMs, 443000);
      // The relay drops and the retained anchor is re-delivered with
      // the SAME sequence: a plain duplicate check would drop it, but
      // the resync flag applies the anchor in full.
      guest.debugSetReconnectingForTest(true);
      guest.debugReceivePayloadForTest(
        statePayload(
          media: gardenMedia,
          sequence: 5,
          positionMs: 500000,
          playing: true,
        ),
      );
      expect(guest.roomState?.positionMs, 500000);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });
  });

  group('clock sync + high-latency sync', () {
    test('clock offset estimated from a host heartbeat', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugSetRoundTripMsForTest(200);
      expect(guest.clockCalibrated, isFalse);
      // Host clock ~1900 ms ahead of the guest's, RTT 200 ms: the
      // sample is (hostTs - receivedAt) + RTT/2 ≈ 2000 ms.
      final now = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        heartbeatPayload(timestampMs: now + 1900),
      );
      expect(guest.clockCalibrated, isTrue);
      expect(guest.clockOffsetMs, isNotNull);
      expect((guest.clockOffsetMs! - 2000).abs() < 150, isTrue);
    });

    test('drift correction converges at 300 ms RTT', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Host state stamped 300 ms ago, host playing from 443000: the
      // live target is ~300 ms ahead of the anchor.
      final decision = decideSync(
        localPositionMs: 440000,
        hostPositionMs: 443000,
        hostTimestampMs: now - 300,
        nowMs: now,
        hostPlaying: true,
        durationMs: 2763000,
      );
      expect(decision.action, SyncAction.seek);
      expect((decision.targetPositionMs - 443300).abs() < 50, isTrue);
    });

    test('drift correction converges at 500 ms RTT without oscillating',
        () {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 500 ms in the past, guest 3 s behind: one hard seek to the
      // projected live position — not a nudge, not two seeks.
      final decision = decideSync(
        localPositionMs: 440000,
        hostPositionMs: 443000,
        hostTimestampMs: now - 500,
        nowMs: now,
        hostPlaying: true,
        durationMs: 2763000,
      );
      expect(decision.action, SyncAction.seek);
      expect((decision.targetPositionMs - 443500).abs() < 50, isTrue);
      // Small drift at the same RTT: a gentle nudge, never a seek.
      final nudge = decideSync(
        localPositionMs: 443300,
        hostPositionMs: 443000,
        hostTimestampMs: now - 500,
        nowMs: now,
        hostPlaying: true,
        durationMs: 2763000,
      );
      expect(nudge.action, SyncAction.nudgeFaster);
      expect(nudge.rate, closeTo(1.05, 0.001));
    });

    test('stalled host freezes the target — never seek into a stall', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final decision = decideSync(
        localPositionMs: 10000,
        hostPositionMs: 10000,
        hostTimestampMs: now - 1000,
        nowMs: now,
        hostPlaying: true,
        durationMs: 2763000,
        hostStalled: true,
      );
      expect(decision.action, SyncAction.inSync);
      expect(decision.targetPositionMs, 10000);
      // Even a guest behind the host seeks only to the FROZEN anchor,
      // never to a projected position that keeps moving.
      final behind = decideSync(
        localPositionMs: 5000,
        hostPositionMs: 10000,
        hostTimestampMs: now - 1000,
        nowMs: now,
        hostPlaying: true,
        durationMs: 2763000,
        hostStalled: true,
      );
      expect(behind.action, SyncAction.seek);
      expect(behind.targetPositionMs, 10000);
    });
  });
}
