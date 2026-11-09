import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.11.0 guest cap: host + up to 5 guests. The 6th joiner gets a short
/// honest message — never a crash, never a silent hang — and the room
/// state (who is in it) stays correct on every phone.
///
/// Offline through the service's test seams: the host is fed presence
/// and heartbeat payloads as the relay would deliver them, and its
/// room-full publishes are captured on the debug sink. No relay, no
/// network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService([int seed = 42]) =>
      TogetherService(random: Random(seed), preferences: null);

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
    'timestampMs': DateTime.now().millisecondsSinceEpoch,
    if (displayName != null) 'displayName': displayName,
  });

  String heartbeatPayload({
    required String senderId,
    required String role,
    String? displayName,
    int positionMs = 12000,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'heartbeat',
    'senderId': senderId,
    'role': role,
    if (displayName != null) 'displayName': displayName,
    'positionMs': positionMs,
    'playbackSpeed': 1.0,
  });

  /// Host with the publish sink attached; every publish is captured.
  (TogetherService, List<Map<String, dynamic>>) hostWithSink() {
    final host = newService();
    final published = <Map<String, dynamic>>[];
    host.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    return (host, published);
  }

  List<Map<String, dynamic>> roomFullsOf(List<Map<String, dynamic>> published) =>
      published.where((p) => p['kind'] == 'room-full').toList();

  group('5-guest cap, presence path', () {
    test('five guests join fine; the 6th is turned away by name', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      const names = ['Aisha', 'Arjun', 'Mina', 'Rafi', 'Nusrat', 'Tanvir'];
      for (var i = 0; i < 5; i++) {
        host.debugReceivePayloadForTest(
          presencePayload(senderId: 'guest-$i', role: 'guest', displayName: names[i]),
        );
      }
      expect(host.guestCount, 5);
      expect(roomFullsOf(published), isEmpty);
      expect(host.members.map((m) => m.displayLabel), names.sublist(0, 5));

      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-5', role: 'guest', displayName: names[5]),
      );
      expect(host.guestCount, 5);
      expect(host.members.map((m) => m.clientId), isNot(contains('guest-5')));
      final full = roomFullsOf(published);
      expect(full, hasLength(1));
      expect(full.single['targetId'], 'guest-5');
      expect(full.single['message'], kTogetherRoomFullMessage);
    });

    test('a guest leaving frees a seat for the next joiner', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      for (var i = 0; i < 5; i++) {
        host.debugReceivePayloadForTest(
          presencePayload(senderId: 'guest-$i', role: 'guest', displayName: 'Guest $i'),
        );
      }
      expect(host.guestCount, 5);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-0', role: 'guest', joined: false),
      );
      expect(host.guestCount, 4);
      expect(host.members.map((m) => m.clientId), isNot(contains('guest-0')));
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-5', role: 'guest', displayName: 'New'),
      );
      expect(host.guestCount, 5);
      expect(roomFullsOf(published), isEmpty);
    });

    test('the same guest joining twice counts once', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-0', role: 'guest', displayName: 'Aisha'),
      );
      host.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-0', role: 'guest', displayName: 'Aisha'),
      );
      expect(host.guestCount, 1);
      expect(roomFullsOf(published), isEmpty);
    });
  });

  group('5-guest cap, heartbeat path', () {
    test('a 6th guest learned only from heartbeats is turned away too', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      for (var i = 0; i < 6; i++) {
        host.debugReceivePayloadForTest(
          heartbeatPayload(senderId: 'guest-$i', role: 'guest', displayName: 'Guest $i'),
        );
      }
      expect(host.guestCount, 5);
      final full = roomFullsOf(published);
      expect(full, hasLength(1));
      expect(full.single['targetId'], 'guest-5');
    });
  });

  group('room-full, guest side', () {
    test('only the named guest leaves and sees the honest message', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.phase, TogetherPhase.waitingGuest);
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': guest.clientId,
          'senderId': 'host-1',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
          'message': kTogetherRoomFullMessage,
        }),
      );
      // The leave runs async (unawaited in the handler); give it a tick.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherRoomFullMessage);
      // The join context survives the leave, so the error screen's Retry
      // rejoins the same room as the same guest (the code is restored;
      // the typed name is restored with it — see the name tests).
      expect(guest.otp, '123456');
    });

    test('a room-full naming another phone is ignored', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': 'some-other-phone',
          'senderId': 'host-1',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(guest.phase, TogetherPhase.waitingGuest);
      expect(guest.error, isNull);
    });

    test('a room-full naming the host is ignored', () async {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'room-full',
          'targetId': host.clientId,
          'senderId': 'host-1',
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(host.phase, TogetherPhase.pendingHost);
    });
  });

  group('member list + presence label', () {
    test('guest sees HOST + typed guest names, in join order', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      expect(guest.presenceLabel, 'HOST in room');
      expect(guest.members.map((m) => m.displayLabel), ['HOST']);
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-a', role: 'guest', displayName: 'Aisha'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-b', role: 'guest', displayName: 'Arjun'),
      );
      expect(guest.presenceLabel, 'HOST + 2 guests in room');
      expect(
        guest.members.map((m) => m.displayLabel),
        ['HOST', 'Aisha', 'Arjun'],
      );
      expect(guest.members.first.isHost, isTrue);
    });

    test('one guest reads "HOST + Guest in room"', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-a', role: 'guest', displayName: 'Aisha'),
      );
      expect(guest.presenceLabel, 'HOST + Guest in room');
    });

    test('member list updates when a guest leaves', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-a', role: 'guest', displayName: 'Aisha'),
      );
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-b', role: 'guest', displayName: 'Arjun'),
      );
      expect(guest.members, hasLength(3));
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-a', role: 'guest', joined: false),
      );
      expect(guest.members.map((m) => m.displayLabel), ['HOST', 'Arjun']);
      expect(guest.presenceLabel, 'HOST + Guest in room');
    });

    test('heartbeats teach the room who is in it, with names', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'host-1', role: 'host'),
      );
      guest.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'guest-a', role: 'guest', displayName: 'Aisha'),
      );
      expect(
        guest.members.map((m) => m.displayLabel),
        ['HOST', 'Aisha'],
      );
      // A later heartbeat without a name keeps the name it already has.
      guest.debugReceivePayloadForTest(
        heartbeatPayload(senderId: 'guest-a', role: 'guest'),
      );
      expect(guest.members.last.displayLabel, 'Aisha');
    });

    test('a nameless guest still shows, as Guest', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        presencePayload(senderId: 'guest-old', role: 'guest'),
      );
      expect(guest.members.single.displayLabel, 'Guest');
    });
  });
}
