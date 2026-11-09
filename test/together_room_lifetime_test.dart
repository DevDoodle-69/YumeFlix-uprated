import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.12.0 room lifetime + auto-close.
///
/// A room lives 45 minutes from the host's creation stamp. After that
/// it ends for everyone in it (local playback untouched) and no one can
/// join it any more; a room that becomes empty (host gone, last guest
/// out) closes itself. The clock is injectable, so every threshold is
/// pinned here by moving time, not by waiting. Offline through the
/// service's test seams — no relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // The fake clock: tests move `now` and the service's lifetime
  // decisions move with it.
  var now = DateTime(2026, 11, 9, 10, 0);
  final int t0 = DateTime(2026, 11, 9, 10, 0).millisecondsSinceEpoch;

  setUp(() {
    now = DateTime(2026, 11, 9, 10, 0);
  });

  TogetherService newService([int seed = 42]) => TogetherService(
    random: Random(seed),
    preferences: null,
    clock: () => now,
  );

  const movieMedia = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/dune',
    source: 'Server 1',
  );

  String presencePayload({
    required String senderId,
    required String role,
    String? displayName,
    bool joined = true,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'presence',
    'senderId': senderId,
    'role': role,
    'joined': joined,
    'timestampMs': now.millisecondsSinceEpoch,
    if (displayName != null) 'displayName': displayName,
  });

  String heartbeatPayload({
    required String senderId,
    required String role,
    int positionMs = 12000,
    int? createdAtMs,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'heartbeat',
    'senderId': senderId,
    'role': role,
    'positionMs': positionMs,
    'playbackSpeed': 1.0,
    'timestampMs': now.millisecondsSinceEpoch,
    if (createdAtMs != null) 'createdAtMs': createdAtMs,
  });

  String statePayload({
    required int sequence,
    required int positionMs,
    required bool playing,
    int? createdAtMs,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'state',
    ...TogetherRoomState(
      media: movieMedia,
      positionMs: positionMs,
      durationMs: 600000,
      playing: playing,
      hostTimestampMs: now.millisecondsSinceEpoch,
      sequence: sequence,
      hostId: 'host-1',
      createdAtMs: createdAtMs ?? 0,
    ).toJson(),
  });

  group('lifetime constants', () {
    test('the room lives exactly 45 minutes', () {
      expect(kTogetherRoomLifetime, const Duration(minutes: 45));
    });

    test('the expiry messages are the agreed lines', () {
      expect(
        kTogetherRoomExpiredMessage,
        'This room has expired — ask the host to create a new room.',
      );
      expect(
        kTogetherRoomEndedMessage,
        'Room ended — the 45 minute limit was reached.',
      );
    });
  });

  group('remaining time', () {
    test('counts down from 45 minutes from the creation stamp', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs: t0,
      );
      expect(host.roomEndsAtMs, t0 + 45 * 60 * 1000);
      expect(host.remainingTime, const Duration(minutes: 45));
      expect(host.roomExpired(), isFalse);

      now = now.add(const Duration(minutes: 10));
      expect(host.remainingTime, const Duration(minutes: 35));

      now = now.add(const Duration(minutes: 34, seconds: 59));
      expect(host.remainingTime, const Duration(seconds: 1));
      expect(host.roomExpired(), isFalse);

      now = now.add(const Duration(seconds: 1));
      expect(host.remainingTime, Duration.zero);
      expect(host.roomExpired(), isTrue);
    });

    test('unknown creation time means no countdown and never expired', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.roomEndsAtMs, isNull);
      expect(guest.remainingTime, Duration.zero);
      expect(guest.roomExpired(), isFalse);
    });

    test('the heartbeat tick notifies once per second of countdown', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs: t0,
      );
      var notifies = 0;
      host.addListener(() => notifies++);
      host.debugTickLifetimeForTest();
      expect(notifies, greaterThan(0));
      final afterFirstTick = notifies;
      // Same second again: nothing changed, no rebuild.
      host.debugTickLifetimeForTest();
      expect(notifies, afterFirstTick);
      // One second later: the countdown moved, one notify.
      now = now.add(const Duration(seconds: 1));
      host.debugTickLifetimeForTest();
      expect(notifies, afterFirstTick + 1);
    });
  });

  group('room ends at 45 minutes', () {
    test('a live guest ends with the ended line, playback kept', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs: t0,
      );
      guest.debugReceivePayloadForTest(
        statePayload(sequence: 1, positionMs: 120000, playing: true),
      );
      expect(guest.phase, TogetherPhase.live);

      now = now.add(const Duration(minutes: 45));
      guest.debugTickLifetimeForTest();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherRoomEndedMessage);
      expect(guest.isSessionActive, isFalse);
      expect(guest.remainingTime, Duration.zero);
      // Local playback survives the ending: the coordinator must not
      // pop the player's movie for this.
      expect(guest.keepLocalPlaybackAfterSessionEnd, isTrue);
      // The code dies with the room: no rejoin card for it.
      expect(guest.lastRoom, isNull);
      expect(guest.otp, isNull);
    });

    test('the host ends its own room at 45 minutes too', () async {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs: t0,
      );
      now = now.add(const Duration(minutes: 45));
      host.debugTickLifetimeForTest();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(host.phase, TogetherPhase.error);
      expect(host.error, kTogetherRoomEndedMessage);
      expect(host.isSessionActive, isFalse);
      expect(host.keepLocalPlaybackAfterSessionEnd, isTrue);
      expect(host.lastRoom, isNull);
    });

    test('a room one minute short of expiry does not end', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs: t0,
      );
      guest.debugReceivePayloadForTest(
        statePayload(sequence: 1, positionMs: 120000, playing: true),
      );
      now = now.add(const Duration(minutes: 44));
      guest.debugTickLifetimeForTest();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guest.phase, TogetherPhase.live);
      expect(guest.error, isNull);
    });
  });

  group('joins after expiry are refused', () {
    test('host turns a late joiner away with the expired line', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs: t0,
      );
      now = now.add(const Duration(minutes: 46));
      host.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-late',
          role: 'guest',
          displayName: 'Late',
        ),
      );
      final rejections = published
          .where((p) => p['kind'] == 'room-full')
          .toList();
      expect(rejections, hasLength(1));
      expect(rejections.single['targetId'], 'guest-late');
      expect(rejections.single['message'], kTogetherRoomExpiredMessage);
      // The joiner never shows in the room.
      expect(host.members.any((m) => m.clientId == 'guest-late'), isFalse);
    });

    test('the heartbeat path refuses a late joiner too', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs: t0,
      );
      now = now.add(const Duration(minutes: 46));
      host.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'guest-late', role: 'guest'),
      );
      final rejections = published
          .where((p) => p['kind'] == 'room-full')
          .toList();
      expect(rejections, hasLength(1));
      expect(rejections.single['message'], kTogetherRoomExpiredMessage);
    });

    test('a late joiner sees the expired line, not room-full', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': guest.clientId,
          'senderId': 'host-1',
          'timestampMs': now.millisecondsSinceEpoch,
          'message': kTogetherRoomExpiredMessage,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherRoomExpiredMessage);
    });

    test(
      'a joiner learning an expired room from retained state is refused',
      () async {
        final guest = newService(7);
        addTearDown(guest.dispose);
        guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
        // The room was created 46 minutes ago (host's stamp, carried in
        // the retained state) — the guest's own clock only measures the
        // gap against that stamp, it never supplies the creation time.
        now = now.add(const Duration(minutes: 46));
        guest.debugReceivePayloadForTest(
          statePayload(
            sequence: 1,
            positionMs: 120000,
            playing: true,
            createdAtMs: t0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(guest.phase, TogetherPhase.error);
        expect(guest.error, kTogetherRoomExpiredMessage);
        expect(guest.isSessionActive, isFalse);
      },
    );

    test('a joiner learns the creation time from the host heartbeat', () {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.roomEndsAtMs, isNull);
      guest.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'host-1', role: 'host', createdAtMs: t0),
      );
      expect(guest.roomEndsAtMs, t0 + 45 * 60 * 1000);
      expect(guest.remainingTime, const Duration(minutes: 45));
    });

    test('rejoining an expired room is refused before connecting', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'together.last_room',
        jsonEncode(
          TogetherLastRoom(
            otp: '123456',
            role: 'guest',
            createdAtMs: t0,
          ).toJson(),
        ),
      );
      final guest = newService(7);
      addTearDown(guest.dispose);
      await guest.loadLastRoom();
      expect(guest.lastRoom?.otp, '123456');
      now = now.add(const Duration(minutes: 46));
      final ok = await guest.joinRoom('123456', displayName: 'Aisha');
      expect(ok, isFalse);
      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherRoomExpiredMessage);
    });

    test('a host does not resurrect an expired room by rejoining', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'together.last_room',
        jsonEncode(
          TogetherLastRoom(
            otp: '123456',
            role: 'host',
            createdAtMs: t0,
          ).toJson(),
        ),
      );
      final host = newService();
      addTearDown(host.dispose);
      await host.loadLastRoom();
      now = now.add(const Duration(minutes: 46));
      final ok = await host.rejoinLastRoom();
      expect(ok, isFalse);
      expect(host.error, kTogetherRoomExpiredMessage);
    });
  });

  group('auto-close when empty', () {
    test('host gone + last guest out closes the room, playback kept', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs: t0,
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-2',
          role: 'guest',
          displayName: 'Arjun',
        ),
      );
      guest.debugReceivePayloadForTest(
        statePayload(sequence: 1, positionMs: 120000, playing: true),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.isSessionActive, isTrue);

      // The host leaves: the room is not empty yet (Arjun is still in
      // it), so nothing closes — the guest keeps the host-left state.
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: false),
      );
      expect(guest.hostGone, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guest.isSessionActive, isTrue);

      // The last guest leaves: the room is empty now, and it closes
      // itself — publishing stops, the heartbeat stops, the code is
      // released, and local playback is kept.
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-2', role: 'guest', joined: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.isSessionActive, isFalse);
      expect(guest.phase, TogetherPhase.idle);
      expect(guest.otp, isNull);
      expect(guest.lastRoom, isNull);
      expect(guest.keepLocalPlaybackAfterSessionEnd, isTrue);
    });

    test('host bye with no one else left closes the room', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs: t0,
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        statePayload(sequence: 1, positionMs: 120000, playing: true),
      );
      expect(guest.phase, TogetherPhase.live);
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.isSessionActive, isFalse);
      expect(guest.phase, TogetherPhase.idle);
      expect(guest.keepLocalPlaybackAfterSessionEnd, isTrue);
    });

    test(
      'a waiting guest keeps the host-left screen instead of auto-closing',
      () async {
        final guest = newService(7);
        addTearDown(guest.dispose);
        guest.debugEnterRoomForTest(
          role: TogetherRole.guest,
          otp: '123456',
          createdAtMs: t0,
        );
        guest.debugReceivePayloadForTest(
          presencePayload(senderId: 'host-1', role: 'host'),
        );
        expect(guest.phase, TogetherPhase.waitingGuest);
        guest.debugReceivePayloadForTest(
          presencePayload(senderId: 'host-1', role: 'host', joined: false),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // Host gone, no one else here — but the guest never got live, so
        // the room stays open on the host-left screen (2.11.0 behaviour)
        // instead of auto-closing out from under it.
        expect(guest.hostGone, isTrue);
        expect(guest.isSessionActive, isTrue);
        expect(guest.phase, TogetherPhase.waitingGuest);
      },
    );

    test('a brief host blip does not close a room with guests in it', () async {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs: t0,
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(
          senderId: 'guest-2',
          role: 'guest',
          displayName: 'Arjun',
        ),
      );
      // The host goes quiet — but Arjun is still a member, so the room
      // stays open (and the 8 s silence decision itself has not fired:
      // nothing here declares the host gone on a single missed beat).
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host', joined: false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guest.isSessionActive, isTrue);
      expect(guest.members.any((m) => m.clientId == 'guest-2'), isTrue);
    });

    test(
      'a briefly reconnecting guest is still a member; a truly gone one is not',
      () {
        final host = newService();
        addTearDown(host.dispose);
        host.debugEnterRoomForTest(
          role: TogetherRole.host,
          otp: '123456',
          createdAtMs: t0,
        );
        host.debugReceivePayloadForTest(
          presencePayload(
            senderId: 'guest-1',
            role: 'guest',
            displayName: 'Aisha',
          ),
        );
        host.debugReceivePayloadForTest(
          presencePayload(
            senderId: 'guest-2',
            role: 'guest',
            displayName: 'Arjun',
          ),
        );
        host.debugReceivePayloadForTest(
          heartbeatPayload(senderId: 'guest-1', role: 'guest'),
        );
        host.debugReceivePayloadForTest(
          heartbeatPayload(senderId: 'guest-2', role: 'guest'),
        );
        expect(host.members.any((m) => m.clientId == 'guest-1'), isTrue);
        // 5 s without a beat — a blip, not a departure: still counted.
        now = now.add(const Duration(seconds: 5));
        host.debugPruneStaleMembersForTest();
        expect(host.members.any((m) => m.clientId == 'guest-1'), isTrue);
        // 11 s without a beat — past the 10 s stale window: gone.
        now = now.add(const Duration(seconds: 6));
        host.debugPruneStaleMembersForTest();
        expect(host.members.any((m) => m.clientId == 'guest-1'), isFalse);
      },
    );
  });
}
