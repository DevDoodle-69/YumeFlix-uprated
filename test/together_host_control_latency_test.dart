import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:yumeflix/features/together/connection.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';
import 'package:yumeflix/features/together/together_player_hook.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.8.0 host control + no-latency: every host action publishes its
/// state immediately (never waiting for the heartbeat), the guest applies
/// play / pause / seek / title change in order, and the room's latency
/// figures are real measurements, never guesses.
///
/// The host side is verified through the service's publish sink
/// ([TogetherService.debugPublishSinkForTest]): what the host would put
/// on the wire, captured without a broker. The guest side is fed the
/// exact JSON the relay would deliver, through
/// [TogetherService.debugReceivePayloadForTest]. No relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const mediaA = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
  );
  const mediaB = TogetherMediaIdentity(
    title: 'Interstellar',
    tmdbType: 'movie',
    tmdbId: 157336,
    posterUrl: 'https://example.invalid/interstellar.jpg',
  );

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  /// Host in a live room with the publish sink attached, so every publish
  /// is captured. Returns the (host, captured-publishes) pair.
  ///
  /// 2.13.0: `goLive` HELDS playback until the first guest reports
  /// ready, so the helper feeds a ready guest straight away — the room
  /// under test is live and playing, as before.
  (TogetherService, List<Map<String, dynamic>>) liveHostWithSink() {
    final host = newService();
    final published = <Map<String, dynamic>>[];
    host.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    host.attachMedia(mediaA);
    host.goLive(positionMs: 0, durationMs: 600000, playing: true);
    host.debugReceivePayloadForTest(
      jsonEncode(
        TogetherGuestReadyMessage(
          ready: true,
          senderId: 'guest-1',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          displayName: 'sonali',
          titleKey: togetherTitleKey(mediaA),
        ).toJson(),
      ),
    );
    published.clear(); // goLive's own publish is not under test here
    return (host, published);
  }

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    int? hostTimestampMs,
    String hostId = 'host-1',
  }) {
    // Default stamp is "now": the seek-jump math compares where the
    // previous state said the host would be *now*, so a stamp from the
    // distant past would make ordinary playback look like a jump.
    final stamp =
        hostTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 600000,
        playing: playing,
        hostTimestampMs: stamp,
        sequence: sequence,
        hostId: hostId,
      ).toJson(),
    });
  }

  group('host publishes immediately on every action', () {
    test('play/pause flip publishes a state at once', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);
      // A flip publishes a state AND a status (the guest's live line
      // follows the flip too) — the state is what this test counts.
      List<Map<String, dynamic>> states() =>
          published.where((p) => p['kind'] == 'state').toList();

      host.reportLocalPlayback(
        positionMs: 1000,
        durationMs: 600000,
        playing: false, // pause
      );
      expect(states().length, 1);
      expect(states().single['kind'], 'state');
      expect(states().single['playing'], isFalse);
      expect(states().single['positionMs'], 1000);
      expect(states().single['_retain'], isTrue);

      host.reportLocalPlayback(
        positionMs: 1000,
        durationMs: 600000,
        playing: true, // play again, same position
      );
      expect(states().length, 2);
      expect(states().last['playing'], isTrue);
    });

    test('seek publishes a state at once — forward, backward, '
        'and while paused', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);
      List<Map<String, dynamic>> states() =>
          published.where((p) => p['kind'] == 'state').toList();

      // Forward seek: 1 s -> 120 s.
      host.reportLocalPlayback(
        positionMs: 120000,
        durationMs: 600000,
        playing: true,
      );
      expect(states().length, 1);
      expect(states().single['positionMs'], 120000);

      // Backward seek: 120 s -> 30 s.
      host.reportLocalPlayback(
        positionMs: 30000,
        durationMs: 600000,
        playing: true,
      );
      expect(states().length, 2);
      expect(states().last['positionMs'], 30000);

      // Paused seek: a small move while paused is still a seek, and it
      // still publishes (2.7.0 needed a >2 s jump to publish at all).
      host.reportLocalPlayback(
        positionMs: 30000,
        durationMs: 600000,
        playing: false,
      );
      expect(states().length, 3);
      host.reportLocalPlayback(
        positionMs: 31500,
        durationMs: 600000,
        playing: false,
      );
      expect(states().length, 4);
      expect(states().last['positionMs'], 31500);
      expect(states().last['playing'], isFalse);
    });

    test('ordinary playback does not spam: steady ticks publish at '
        'most once a second', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      // goLive already published the state at position 0 a moment ago,
      // so rapid ticks — no flip, no seek, 1 s interval not elapsed —
      // publish nothing at all.
      host.reportLocalPlayback(
        positionMs: 250,
        durationMs: 600000,
        playing: true,
      );
      host.reportLocalPlayback(
        positionMs: 500,
        durationMs: 600000,
        playing: true,
      );
      host.reportLocalPlayback(
        positionMs: 750,
        durationMs: 600000,
        playing: true,
      );
      expect(published, isEmpty);
    });

    test('title change while live publishes the new title at 0 at once', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      host.attachMedia(mediaB);
      expect(published.length, 1);
      expect(published.single['kind'], 'state');
      final media = published.single['media'] as Map;
      expect(media['title'], 'Interstellar');
      expect(published.single['positionMs'], 0);
      expect(host.lastLocalPositionMs, 0);
    });

    test('goLive publishes the first retained state immediately', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json, '_retain': retain});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(mediaA);
      host.goLive(positionMs: 42000, durationMs: 600000, playing: true);
      // 2.13.0: Start publishes immediately — but HELD, paused at the
      // start position, until the first guest reports ready. The hold
      // itself is the first retained state (one publish, no heartbeat
      // wait); the guest-ready release is the second, playing at the
      // same position.
      var states = published.where((p) => p['kind'] == 'state').toList();
      expect(states.length, 1);
      expect(states.single['positionMs'], 42000);
      expect(states.single['playing'], isFalse);
      expect(states.single['held'], isTrue);
      expect(states.single['_retain'], isTrue);
      host.debugGuestReadyForTest();
      states = published.where((p) => p['kind'] == 'state').toList();
      expect(states.length, 2);
      expect(states.last['playing'], isTrue);
      expect(states.last['positionMs'], 42000);
      expect(states.last['_retain'], isTrue);
    });
  });

  group('guest applies every host action, in order', () {
    test('play -> pause -> seek -> resume -> steady tick -> '
        'new title -> host left', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');

      var notifications = 0;
      guest.addListener(() => notifications++);

      // Host clock: every stamp below is on the host's timeline, so the
      // seek-jump math (target now vs. previous target now) sees honest
      // advances: +8 s of playback between stamps 1 and 2, a frozen
      // clock while paused, +500 ms between stamps 4 and 5.
      final t0 = DateTime.now().millisecondsSinceEpoch;

      // Host goes live, playing at 12 s.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 1,
          positionMs: 12000,
          playing: true,
          hostTimestampMs: t0,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.roomState?.positionMs, 12000);
      expect(guest.roomState?.playing, isTrue);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      final afterLive = notifications;
      expect(afterLive, greaterThan(0));

      // Host pauses at 20 s: the guest sees the flip immediately.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 2,
          positionMs: 20000,
          playing: false,
          hostTimestampMs: t0 + 8000,
        ),
      );
      expect(guest.roomState?.playing, isFalse);
      expect(guest.roomStatus, TogetherRoomStatus.hostPaused);

      // Host seeks to 90 s while paused: a seek-sized jump notifies, so
      // the guest hook applies it at once instead of at the next tick.
      notifications = 0;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 3,
          positionMs: 90000,
          playing: false,
          hostTimestampMs: t0 + 8000,
        ),
      );
      expect(guest.roomState?.positionMs, 90000);
      expect(notifications, greaterThan(0));

      // Host resumes playing at 90 s: a flip, so it notifies too.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 4,
          positionMs: 90000,
          playing: true,
          hostTimestampMs: t0 + 8000,
        ),
      );
      expect(guest.roomState?.playing, isTrue);

      // A steady-state tick (same title, same transport, +500 ms of
      // playback in +500 ms of wall time) does NOT notify: the player
      // screen must not rebuild every second.
      notifications = 0;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 5,
          positionMs: 90500,
          playing: true,
          hostTimestampMs: t0 + 8500,
        ),
      );
      expect(guest.roomState?.positionMs, 90500);
      expect(notifications, 0);

      // Host starts a different title: the guest's title, position and
      // transport all follow, cleanly, from the old title's position.
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaB, sequence: 6, positionMs: 0, playing: true),
      );
      expect(guest.currentMedia, mediaB);
      expect(guest.roomState?.positionMs, 0);
      expect(guest.roomState?.playing, isTrue);

      // Host left: the guest is told and keeps the last synced state.
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(guest.currentMedia, mediaB);
    });

    test('a stale (out-of-order) state is ignored, never applied', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 5, positionMs: 60000, playing: true),
      );
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 4, positionMs: 1000, playing: false),
      );
      expect(guest.roomState?.sequence, 5);
      expect(guest.roomState?.positionMs, 60000);
      expect(guest.roomState?.playing, isTrue);
    });

    test('the guest hook decision follows each host action exactly', () {
      // decideSync is what the hook applies: a pause freezes the target,
      // a seek jumps, small drift nudges.
      const now = 1_700_000_000_000;
      // Host paused at 20 s; guest at 20.4 s: 400 ms over the frozen
      // target — nudge, not seek (2.8.0 thresholds: nudge >= 150 ms).
      final paused = decideSync(
        localPositionMs: 20400,
        hostPositionMs: 20000,
        hostTimestampMs: now,
        nowMs: now,
        hostPlaying: false,
        durationMs: 600000,
      );
      expect(paused.action, SyncAction.nudgeSlower);
      // Host seeked to 90 s; guest still at 20 s: seek at once.
      final seeked = decideSync(
        localPositionMs: 20000,
        hostPositionMs: 90000,
        hostTimestampMs: now,
        nowMs: now,
        hostPlaying: false,
        durationMs: 600000,
      );
      expect(seeked.action, SyncAction.seek);
      expect(seeked.targetPositionMs, 90000);
      // Host playing at 12 s, guest at 12.05 s a moment later: in sync.
      final inSync = decideSync(
        localPositionMs: 12050,
        hostPositionMs: 12000,
        hostTimestampMs: now,
        nowMs: now + 100,
        hostPlaying: true,
        durationMs: 600000,
      );
      expect(inSync.action, SyncAction.inSync);
    });
  });

  group('rejoin / resync is fast and exact', () {
    test('host answers a guest join with status AND a retained state '
        'at once', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      host.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'presence',
          'senderId': 'guest-1',
          'role': 'guest',
          'joined': true,
          'timestampMs': 1_700_000_000_000,
        }),
      );
      final kinds = published.map((p) => p['kind'] as String).toList();
      expect(kinds, contains('status'));
      expect(kinds, contains('state'));
      final state = published.firstWhere((p) => p['kind'] == 'state');
      expect(state['_retain'], isTrue);
      expect((state['media'] as Map)['title'], 'Dune');
    });

    test('a late guest learns everything from the retained state alone', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 7, positionMs: 45000, playing: true),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia, mediaA);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });
  });

  group('TogetherPlayerHook: host-only guest controls', () {
    test('guest controls lock exactly while live with the host present',
        () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final controller = VlcPlayerController();
      final hook = TogetherPlayerHook(
        service: guest,
        controller: controller,
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);

      // Waiting: not live yet, the guest's own player is theirs.
      expect(hook.guestControlsLocked, isFalse);
      expect(hook.isSessionActive, isTrue);

      // Host goes live: locked, and the lock is what the player chrome
      // renders disabled with the "Host controls playback" hint.
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 1, positionMs: 12000, playing: true),
      );
      expect(guest.isLive, isTrue);
      expect(hook.guestControlsLocked, isTrue);

      // Host leaves: the lock opens and playback carries on locally.
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(hook.guestControlsLocked, isFalse);
    });

    test('host is never locked; a guest on the wrong title is told so', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final hostHook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hostHook.attach();
      addTearDown(hostHook.dispose);
      expect(hostHook.guestControlsLocked, isFalse);

      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final wrongTitleHook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaB,
      );
      wrongTitleHook.attach();
      addTearDown(wrongTitleHook.dispose);
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 1, positionMs: 12000, playing: true),
      );
      expect(guest.isLive, isTrue);
      expect(wrongTitleHook.hostStartedMedia, mediaA);
      expect(wrongTitleHook.guestNeedsSameTitle, isTrue);
      expect(
        wrongTitleHook.guestJoinHint,
        'Host started Dune — open the same title to join playback',
      );

      final rightTitleHook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      expect(rightTitleHook.guestNeedsSameTitle, isFalse);
      expect(rightTitleHook.guestJoinHint, isNull);
    });

    test('hook goLive goes live from the engine state; attach/dispose '
        'own the orb Start action', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      expect(host.orbStartAction, isNull);
      hook.attach();
      expect(host.orbStartAction, isNotNull);
      expect(host.pendingMedia, mediaA);
      hook.goLive();
      expect(host.phase, TogetherPhase.live);
      expect(host.isLive, isTrue);
      hook.dispose();
      expect(host.orbStartAction, isNull);
    });

    test('hook showStartButton mirrors the service state machine', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      expect(hook.showStartButton, isFalse);
      expect(hook.showOrbStart, isFalse);
      host.reportLocalPlayback(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
      );
      expect(hook.showStartButton, isTrue);
      expect(hook.showOrbStart, isTrue);
      hook.goLive();
      expect(hook.showStartButton, isFalse);
    });
  });

  group('latency is measured, never guessed', () {
    test('heartbeat is 1 s while a room is open', () {
      expect(kTogetherHeartbeatInterval, const Duration(seconds: 1));
    });

    test('own heartbeat echo measures the real MQTT round-trip', () {
      final service = newService();
      addTearDown(service.dispose);
      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      expect(service.roundTripMs, isNull);
      final now = DateTime.now().millisecondsSinceEpoch;
      service.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'heartbeat',
          'senderId': service.clientId,
          'positionMs': 0,
          'timestampMs': now - 120,
        }),
      );
      final rtt = service.roundTripMs;
      expect(rtt, isNotNull);
      // ~120 ms, with scheduling slack on either side.
      expect(rtt!, inInclusiveRange(100, 500));
    });

    test('the status pill shows the measured latency, not a guess', () {
      final label = togetherConnectionStatusLabel(
        connected: true,
        reconnecting: false,
        connecting: false,
        relayLabel: 'EMQX',
        roundTripMs: 120,
      );
      expect(label, 'Connected via EMQX · 120 ms');
      // Before the first echo there is no latency to show — and none is
      // invented.
      expect(
        togetherConnectionStatusLabel(
          connected: true,
          reconnecting: false,
          connecting: false,
          relayLabel: 'EMQX',
        ),
        'Connected via EMQX',
      );
    });

    test('reconnect backoff is 1 s, 2 s, 4 s, 8 s, 15 s, then it stops', () {
      expect(kTogetherReconnectDelaysSeconds, <int>[1, 2, 4, 8, 15]);
      expect(kTogetherMaxReconnectAttempts, 5);
      expect(togetherReconnectDelay(0), const Duration(seconds: 1));
      expect(togetherReconnectDelay(4), const Duration(seconds: 15));
      // Past the end reuses the last delay instead of failing.
      expect(togetherReconnectDelay(99), const Duration(seconds: 15));
    });
  });

  group('non-ASCII survives the wire (2.8.0 UTF-8 regression)', () {
    // Found by tools/live_check.dart: the re-shared title
    // 'Dexter: Resurrection · S2 Premiere' never arrived — every
    // non-ASCII payload decoded to '' on receipt. The app publishes
    // with utf8.encode (correct); the trap is mqtt_client's
    // MqttClientPayloadBuilder.addString, which encodes UTF-16-ish
    // (Latin-1 bytes <= 255, raw half-words above), NOT UTF-8 — so
    // '·', 'é' and emoji all fail utf8.decode and are silently lost.
    // These tests pin the rule: titles and chat cross the relay as
    // UTF-8, and only addUTF8String round-trips.
    const dexterMedia = TogetherMediaIdentity(
      title: 'Dexter: Resurrection · S1 E1',
      tmdbType: 'tv',
      tmdbId: 427049,
      posterUrl: 'https://example.invalid/dexter.jpg',
    );

    test('a series title with · publishes and applies intact', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(dexterMedia);
      host.goLive(positionMs: 14000, durationMs: 3084000, playing: true);
      host.debugGuestReadyForTest();
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states.length, 2);
      final media = states.last['media'] as Map<String, dynamic>;
      expect(media['title'], 'Dexter: Resurrection · S1 E1');

      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(jsonEncode(states.last));
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia?.title, 'Dexter: Resurrection · S1 E1');
      expect(guest.roomState?.positionMs, 14000);
      expect(guest.roomState?.playing, isTrue);
    });

    test('chat text with emoji and accents reaches the guest intact', () {
      const text = 'That twist! 🎬 Amélie vibes — café scene…';
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat',
          'id': 'msg-1',
          'senderId': 'host-1',
          'senderName': 'Host',
          'text': text,
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      expect(guest.messages.length, 1);
      expect(guest.messages.single.text, text);
    });

    test('only addUTF8String round-trips non-ASCII through mqtt_client', () {
      const json =
          '{"kind":"state","media":{"title":"Dexter: Resurrection · S1 E1 🎬 Amélie"}}';
      final utf8Builder = MqttClientPayloadBuilder()..addUTF8String(json);
      expect(utf8.decode(utf8Builder.payload!.toList()), json);
      // addString is UTF-16-ish, not UTF-8: the same JSON loses bytes
      // and utf8.decode throws — which is why bytesToStringAsString
      // returns '' and the message vanishes on receipt.
      final stringBuilder = MqttClientPayloadBuilder()..addString(json);
      expect(
        () => utf8.decode(stringBuilder.payload!.toList()),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
