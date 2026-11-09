import 'dart:convert';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.11.0 live sync: the service-level half of the "zero latency" push.
///
/// The host publishes every action the instant it happens (play, pause,
/// seek, speed, title/server change) and never waits for the 1 s
/// heartbeat; the guest applies what arrives at once, re-syncs on
/// reconnect without a manual step, and never shows a stale room status.
/// The guest's own local actions (pause, seek, title pick) publish
/// nothing at all — the role gate in [_publishState]/[_publishStatusNow]
/// is the only thing standing between a guest pause and the host's
/// player, so these tests pin it.
///
/// Same harness as together_host_control_latency_test.dart: the host side
/// is verified through the publish sink, the guest side is fed the exact
/// JSON the relay would deliver. No relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const mediaA = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
    provider: 'MovieSubLK',
    source: 'Server 1',
    itemUrl: 'https://example.invalid/dune',
  );
  const mediaSeries = TogetherMediaIdentity(
    title: 'Dexter',
    tmdbType: 'tv',
    tmdbId: 427049,
    posterUrl: 'https://example.invalid/dexter.jpg',
    episodeLabel: 'S1 E1',
    season: 1,
    episode: 1,
    provider: 'MovieSubLK',
    source: 'Server 2',
    itemUrl: 'https://example.invalid/dexter',
    episodeUrl: 'https://example.invalid/dexter-s1e1',
  );
  const mediaB = TogetherMediaIdentity(
    title: 'Interstellar',
    tmdbType: 'movie',
    tmdbId: 157336,
    posterUrl: 'https://example.invalid/interstellar.jpg',
  );

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    int? hostTimestampMs,
    double playbackSpeed = 1.0,
    String hostId = 'host-1',
  }) {
    final stamp = hostTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 600000,
        playing: playing,
        playbackSpeed: playbackSpeed,
        hostTimestampMs: stamp,
        sequence: sequence,
        hostId: hostId,
      ).toJson(),
    });
  }

  String presencePayload({
    required String senderId,
    required String role,
    required bool joined,
    String? displayName,
  }) {
    return jsonEncode(<String, dynamic>{
      'kind': 'presence',
      'senderId': senderId,
      'role': role,
      'joined': joined,
      'displayName': ?displayName,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  String heartbeatPayload({
    required String senderId,
    required String role,
    required int positionMs,
    String? status,
    String? displayName,
    double playbackSpeed = 1.0,
  }) {
    return jsonEncode(<String, dynamic>{
      'kind': 'heartbeat',
      'senderId': senderId,
      'role': role,
      'positionMs': positionMs,
      'playbackSpeed': playbackSpeed,
      'status': ?status,
      'displayName': ?displayName,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Host in a live room with the publish sink attached.
  (TogetherService, List<Map<String, dynamic>>) liveHostWithSink({
    TogetherMediaIdentity media = mediaA,
  }) {
    final host = newService();
    final published = <Map<String, dynamic>>[];
    host.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    host.attachMedia(media);
    host.goLive(positionMs: 0, durationMs: 600000, playing: true);
    published.clear();
    return (host, published);
  }

  /// Guest in a room, live on [media] at [positionMs] (playing unless
  /// [playing] is false), with the publish sink attached so any guest
  /// publish is caught.
  (TogetherService, List<Map<String, dynamic>>) liveGuestWithSink({
    TogetherMediaIdentity media = mediaA,
    int positionMs = 12000,
    bool playing = true,
    int sequence = 1,
    String hostId = 'host-1',
    int? hostTimestampMs,
  }) {
    final guest = newService();
    final published = <Map<String, dynamic>>[];
    guest.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
    guest.debugReceivePayloadForTest(
      statePayload(
        media: media,
        sequence: sequence,
        positionMs: positionMs,
        playing: playing,
        hostId: hostId,
        hostTimestampMs: hostTimestampMs,
      ),
    );
    expect(guest.phase, TogetherPhase.live);
    published.clear();
    return (guest, published);
  }

  group('host actions publish immediately (no heartbeat wait)', () {
    test('speed change publishes a state at once, with the new speed', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);
      List<Map<String, dynamic>> states() =>
          published.where((p) => p['kind'] == 'state').toList();

      host.reportLocalPlayback(
        positionMs: 60000,
        durationMs: 600000,
        playing: true,
        playbackSpeed: 2.0,
      );
      expect(states().length, 1);
      expect(states().single['playbackSpeed'], 2.0);
      expect(states().single['positionMs'], 60000);
      expect(states().single['playing'], isTrue);
    });

    test('a small +500 ms forward seek publishes at once', () {
      // The old flat "moved > 1 s" rule missed this: a 500 ms jump
      // forward looks like ordinary playback unless the elapsed time
      // since the last report is counted. Both reports land in the
      // same instant, so the second one is a 500 ms jump in ~0 ms.
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);
      List<Map<String, dynamic>> states() =>
          published.where((p) => p['kind'] == 'state').toList();

      host.reportLocalPlayback(
        positionMs: 60000,
        durationMs: 600000,
        playing: true,
      );
      expect(states().length, 1);
      host.reportLocalPlayback(
        positionMs: 60500,
        durationMs: 600000,
        playing: true,
      );
      expect(states().length, 2);
      expect(states().last['positionMs'], 60500);
    });

    test('server change re-syncs guests to the new source at the '
        'current position — never back to 0', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      host.reportLocalPlayback(
        positionMs: 60000,
        durationMs: 600000,
        playing: true,
      );
      published.clear();

      // The host's player proved Server 2 plays: same title, new
      // source, position kept.
      host.attachMedia(mediaA.withSource('Server 2'));
      expect(published.length, 1);
      expect(published.single['kind'], 'state');
      expect(published.single['positionMs'], 60000);
      final media = published.single['media'] as Map;
      expect(media['title'], 'Dune');
      expect(media['source'], 'Server 2');
      expect(media['provider'], 'MovieSubLK');
    });

    test('title change while live publishes the new title at 0', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      host.attachMedia(mediaB);
      expect(published.length, 1);
      expect(published.single['kind'], 'state');
      expect(published.single['positionMs'], 0);
      expect((published.single['media'] as Map)['title'], 'Interstellar');
    });
  });

  group('guest local actions never publish to the room', () {
    test('guest pause, seek and resume publish nothing', () {
      final (guest, published) = liveGuestWithSink();
      addTearDown(guest.dispose);

      // The guest pauses their own player: local only.
      guest.reportLocalPlayback(
        positionMs: 12000,
        durationMs: 600000,
        playing: false,
      );
      // The guest seeks locally while paused.
      guest.reportLocalPlayback(
        positionMs: 30000,
        durationMs: 600000,
        playing: false,
      );
      // The guest resumes (their own resume — the catch-up seek is
      // applied locally by the hook, never published).
      guest.reportLocalPlayback(
        positionMs: 30000,
        durationMs: 600000,
        playing: true,
        playbackSpeed: 1.5,
      );
      expect(published, isEmpty);
      // And the room state on this phone is untouched: the host is
      // still playing at 12 s.
      expect(guest.roomState?.positionMs, 12000);
      expect(guest.roomState?.playing, isTrue);
    });

    test('guest picking a title locally publishes nothing', () {
      final (guest, published) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.attachMedia(mediaB);
      expect(published, isEmpty);
      expect(guest.roomState?.media.title, 'Dune');
    });
  });

  group('guest resume catches up to the live position', () {
    test('resume target is the host live position, not the paused one', () {
      final (guest, _) = liveGuestWithSink(
        positionMs: 60000,
        playing: true,
        // Stamped 5 s ago: the host has played on to ~65 s since.
        hostTimestampMs: DateTime.now().millisecondsSinceEpoch - 5000,
      );
      addTearDown(guest.dispose);

      final target = guest.hostLiveTargetMs;
      expect(target, isNotNull);
      expect(target!, inInclusiveRange(64500, 65500));

      // The guest paused at 60 s; resume must seek to the live
      // target, not back to 60 s.
      final decision = decideResumeSync(
        localPositionMs: 60000,
        hostPositionMs: 60000,
        hostTimestampMs: DateTime.now().millisecondsSinceEpoch - 5000,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        hostPlaying: true,
        durationMs: 600000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, inInclusiveRange(64500, 65500));
    });

    test('resume to a paused host seeks to the frozen position', () {
      final (guest, _) = liveGuestWithSink(
        positionMs: 65000,
        playing: false,
        hostTimestampMs: DateTime.now().millisecondsSinceEpoch - 5000,
      );
      addTearDown(guest.dispose);

      // Paused 5 s ago: the live position is still 65 s, frozen.
      expect(guest.hostLiveTargetMs, 65000);
      final decision = decideResumeSync(
        localPositionMs: 60000,
        hostPositionMs: 65000,
        hostTimestampMs: DateTime.now().millisecondsSinceEpoch - 5000,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        hostPlaying: false,
        durationMs: 600000,
      );
      expect(decision.action, SyncAction.seek);
      expect(decision.targetPositionMs, 65000);
    });

    test('no live room means no resume target', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.hostLiveTargetMs, isNull);
    });
  });

  group('no stale room status', () {
    test('pause then resume: the status follows both flips', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);

      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 2,
          positionMs: 20000,
          playing: false,
        ),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPaused);

      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 3,
          positionMs: 20000,
          playing: true,
        ),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('host leaves, then a fresh state clears host-gone', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(guest.roomStatus, TogetherRoomStatus.hostLeft);

      // A fresh state (host came back) clears it at once.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 2,
          positionMs: 25000,
          playing: true,
        ),
      );
      expect(guest.hostGone, isFalse);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('host presence left sets host-left; host re-join clears it', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: false),
      );
      expect(guest.hostGone, isTrue);
      expect(guest.roomStatus, TogetherRoomStatus.hostLeft);

      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: true),
      );
      expect(guest.hostGone, isFalse);
    });

    test('a host heartbeat clears host-gone too', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);

      guest.debugReceivePayloadForTest(
        heartbeatPayload(
          senderId: 'host-1',
          role: 'host',
          positionMs: 30000,
          status: 'hostPlaying',
        ),
      );
      expect(guest.hostGone, isFalse);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });

    test('host closing the player while playing publishes a paused '
        'state — no ghost "Host is playing"', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);
      host.reportLocalPlayback(
        positionMs: 45000,
        durationMs: 600000,
        playing: true,
      );
      // The hook attached while the player was open (a non-null orb
      // action), then the player closed: the null registration is what
      // triggers the publish. Registering null with nothing registered
      // is a no-op by design.
      host.registerOrbStartAction(() {});
      published.clear();

      // The orb Start action fires with null when the player closes:
      // the host was playing, so it publishes a paused state at the
      // frozen position at once.
      host.registerOrbStartAction(null);
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states.length, 1);
      expect(states.single['playing'], isFalse);
      expect(states.single['positionMs'], 45000);
    });
  });

  group('connection drop and reconnect', () {
    test('retained state re-delivered on reconnect re-syncs the guest', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);
      var notifications = 0;
      guest.addListener(() => notifications++);

      // The relay drops mid-room.
      guest.debugSetReconnectingForTest(true);
      expect(guest.reconnecting, isTrue);

      // The relay answers and re-delivers the retained state — same
      // sequence the guest already saw. It is a re-sync trigger, not
      // a duplicate to drop: the guest re-applies it.
      notifications = 0;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.roomState?.positionMs, 12000);
      expect(notifications, greaterThan(0));

      // The flag is consumed: a second identical delivery is a plain
      // duplicate again and notifies nothing.
      notifications = 0;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      expect(notifications, 0);

      guest.debugSetReconnectingForTest(false);
      expect(guest.reconnecting, isFalse);
    });

    test('reconnect re-syncs to a host seek that happened while dark', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.debugSetReconnectingForTest(true);
      // While the guest was dark the host seeked to 90 s; the retained
      // state carries it, and the guest applies it at once.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 2,
          positionMs: 90000,
          playing: true,
        ),
      );
      expect(guest.roomState?.positionMs, 90000);
      expect(guest.roomState?.playing, isTrue);
      guest.debugSetReconnectingForTest(false);
    });

    test('re-sync never switches the guest to a different source', () {
      final (guest, _) = liveGuestWithSink(media: mediaSeries);
      addTearDown(guest.dispose);
      expect(guest.currentMedia?.source, 'Server 2');
      expect(guest.currentMedia?.provider, 'MovieSubLK');
      expect(
        guest.currentMedia?.episodeUrl,
        'https://example.invalid/dexter-s1e1',
      );

      guest.debugSetReconnectingForTest(true);
      // The retained state re-delivered on subscribe carries the same
      // source identity — provider, item and episode URLs included.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaSeries,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      expect(guest.currentMedia?.source, 'Server 2');
      expect(guest.currentMedia?.provider, 'MovieSubLK');
      expect(
        guest.currentMedia?.episodeUrl,
        'https://example.invalid/dexter-s1e1',
      );
      expect(guest.currentMedia?.title, 'Dexter');
      guest.debugSetReconnectingForTest(false);
    });

    test('a restarted host (new id, sequence 1) is accepted, not '
        'dropped as stale', () {
      final (guest, _) = liveGuestWithSink();
      addTearDown(guest.dispose);

      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);

      // The host's app restarted: new client id, sequence back at 1,
      // new title. The sequence space resets with the host id, so the
      // state applies instead of being dropped as out-of-order.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaB,
          sequence: 1,
          positionMs: 0,
          playing: true,
          hostId: 'host-2',
        ),
      );
      expect(guest.hostGone, isFalse);
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia, mediaB);
      expect(guest.roomState?.positionMs, 0);
    });

    test('the silence timer does not call "host left" while '
        'reconnecting', () {
      FakeAsync().run((async) {
        final guest = newService();
        addTearDown(guest.dispose);
        guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
        guest.debugReceivePayloadForTest(
          statePayload(
            media: mediaA,
            sequence: 1,
            positionMs: 12000,
            playing: true,
          ),
        );
        expect(guest.hostGone, isFalse);

        guest.debugSetReconnectingForTest(true);
        async.elapse(const Duration(seconds: 9));
        // 8 s of silence while the relay is being retried is expected,
        // not a departure.
        expect(guest.hostGone, isFalse);
        expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      });
    });

    test('8 s of silence with no reconnect means the host is gone — '
        'and fresh traffic clears it', () {
      FakeAsync().run((async) {
        final guest = newService();
        addTearDown(guest.dispose);
        guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
        guest.debugReceivePayloadForTest(
          statePayload(
            media: mediaA,
            sequence: 1,
            positionMs: 12000,
            playing: true,
          ),
        );

        async.elapse(const Duration(seconds: 9));
        expect(guest.hostGone, isTrue);
        expect(guest.roomStatus, TogetherRoomStatus.hostLeft);

        guest.debugReceivePayloadForTest(
          statePayload(
            media: mediaA,
            sequence: 2,
            positionMs: 21000,
            playing: true,
          ),
        );
        expect(guest.hostGone, isFalse);
        expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      });
    });
  });

  group('membership, names and the 5-guest cap', () {
    test('member list shows HOST crown + each guest typed name', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');

      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: true),
      );
      expect(guest.hostPresent, isTrue);
      expect(guest.presenceLabel, 'HOST in room');
      expect(guest.members.map((m) => m.displayLabel).toList(), ['HOST']);

      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-2',
          role: 'guest',
          joined: true,
          displayName: 'Arefin',
        ),
      );
      expect(guest.memberCount, 2);
      expect(guest.presenceLabel, 'HOST + Guest in room');
      expect(guest.members.map((m) => m.displayLabel).toList(), [
        'HOST',
        'Arefin',
      ]);

      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-3',
          role: 'guest',
          joined: true,
          displayName: 'Mim',
        ),
      );
      expect(guest.presenceLabel, 'HOST + 2 guests in room');
      expect(guest.members.map((m) => m.displayLabel).toList(), [
        'HOST',
        'Arefin',
        'Mim',
      ]);
    });

    test('a nameless heartbeat never wipes a known name', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-2',
          role: 'guest',
          joined: true,
          displayName: 'Arefin',
        ),
      );
      expect(
        guest.members.firstWhere((m) => m.clientId == 'guest-2').displayLabel,
        'Arefin',
      );

      // The guest's heartbeat carries no name (older client, or a
      // reconnect before the presence re-publish lands): the known
      // name survives.
      guest.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'guest-2', role: 'guest', positionMs: 5000),
      );
      expect(
        guest.members.firstWhere((m) => m.clientId == 'guest-2').displayLabel,
        'Arefin',
      );
    });

    test('a guest leaving removes them from the member list at once', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: true),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-2',
          role: 'guest',
          joined: true,
          displayName: 'Arefin',
        ),
      );
      expect(guest.memberCount, 2);

      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-2', role: 'guest', joined: false),
      );
      expect(guest.memberCount, 1);
      expect(guest.presenceLabel, 'HOST in room');
      expect(guest.members.map((m) => m.displayLabel).toList(), ['HOST']);
    });

    test('the 6th joiner is turned away and nobody else notices', () {
      final (host, published) = liveHostWithSink();
      addTearDown(host.dispose);

      const names = ['Arefin', 'Mim', 'Rafi', 'Nusrat', 'Tanvir'];
      for (var i = 0; i < 5; i++) {
        host.debugReceivePayloadForTest(
          presencePayload(
            senderId: 'guest-${i + 1}',
            role: 'guest',
            joined: true,
            displayName: names[i],
          ),
        );
      }
      expect(host.guestCount, 5);
      expect(host.members.map((m) => m.displayLabel).toList(), [
        'Arefin',
        'Mim',
        'Rafi',
        'Nusrat',
        'Tanvir',
      ]);
      published.clear();

      // The 6th guest joins: turned away with a targeted room-full,
      // never added to the member list, host state untouched.
      host.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-6',
          role: 'guest',
          joined: true,
          displayName: 'Sixth',
        ),
      );
      expect(host.guestCount, 5);
      expect(host.members.map((m) => m.displayLabel).toList(), [
        'Arefin',
        'Mim',
        'Rafi',
        'Nusrat',
        'Tanvir',
      ]);
      expect(host.phase, TogetherPhase.live);
      expect(host.roomState?.media.title, 'Dune');
      final roomFull = published
          .where((p) => p['kind'] == 'room-full')
          .toList();
      expect(roomFull.length, 1);
      expect(roomFull.single['targetId'], 'guest-6');
      // No status/state spam for a rejected joiner.
      expect(published.where((p) => p['kind'] == 'state').toList(), isEmpty);
    });

    test('a room-full for this guest ends the join with the honest '
        'line; one for another phone is ignored', () async {
      final other = newService();
      addTearDown(other.dispose);
      other.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      other.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': 'someone-else',
          'senderId': 'host-1',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      expect(other.phase, TogetherPhase.waitingGuest);
      expect(other.error, isNull);

      final rejected = newService();
      addTearDown(rejected.dispose);
      rejected.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      rejected.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': rejected.clientId,
          'senderId': 'host-1',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      // _leaveAfterRoomFull runs async (unawaited): let it finish.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(rejected.phase, TogetherPhase.error);
      expect(rejected.error, kTogetherRoomFullMessage);
    });
  });
}
