import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.11.0 guest names + HOST: a guest types their name to join (required,
/// remembered, pre-filled next time), chat shows the typed name, and the
/// room creator is HOST everywhere — icon + label, never colour alone.
///
/// Offline through the service's test seams (name validation, the join
/// gate, inbound chat payloads, presence/member state) — no relay, no
/// network. The join dialog itself is widget-level; what is pinned here
/// is the contract it enforces.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService([int seed = 42]) =>
      TogetherService(random: Random(seed), preferences: null);

  group('name validation', () {
    test('empty and whitespace-only names are rejected', () {
      expect(validateTogetherGuestName(''), isNotNull);
      expect(validateTogetherGuestName('   '), isNotNull);
      // The dialog's inline line (shorter than the service error the
      // join gate reports — see below).
      expect(
        validateTogetherGuestName(''),
        'Type your name to join.',
      );
    });

    test('a real name passes; surrounding space is trimmed', () {
      expect(validateTogetherGuestName('Aisha'), isNull);
      expect(validateTogetherGuestName('  Aisha  '), isNull);
      expect(normalizeTogetherGuestName('  Aisha  '), 'Aisha');
    });

    test('names cap at 20 characters', () {
      const long = 'A very long name indeed';
      expect(normalizeTogetherGuestName(long), 'A very long name ind');
      expect(normalizeTogetherGuestName(long).length, kTogetherGuestNameMaxLength);
      expect(validateTogetherGuestName(long), isNull);
    });
  });

  group('last name is remembered and pre-filled', () {
    // This group runs before the join-flow group on purpose: the first
    // SharedPreferences access in this file must see the seeded values,
    // before any join attempt caches a prefs instance.
    test('loadLastGuestName reads the saved name, trimmed and capped', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'together.last_guest_name': '  Aisha  ',
      });
      final guest = newService();
      addTearDown(guest.dispose);
      await guest.loadLastGuestName();
      expect(guest.lastGuestName, 'Aisha');
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('no saved name means no pre-fill, not an error', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final guest = newService();
      addTearDown(guest.dispose);
      await guest.loadLastGuestName();
      expect(guest.lastGuestName, isNull);
    });
  });

  group('join flow blocks without a name', () {
    test('joinRoom without a name fails fast with the honest line', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      final ok = await guest.joinRoom('123456');
      expect(ok, isFalse);
      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherGuestNameRequiredMessage);
    });

    test('joinRoom with a whitespace-only name fails the same way', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      final ok = await guest.joinRoom('123456', displayName: '   ');
      expect(ok, isFalse);
      expect(guest.error, kTogetherGuestNameRequiredMessage);
    });

    test('joinRoom with a name passes the gate (then fails on the relay)', () async {
      // No relay in a unit test, so the connect itself fails — but the
      // name gate is what this pins: the name is accepted, trimmed and
      // remembered before any network is attempted, and the phase reaches
      // waitingGuest on the way.
      final guest = newService();
      addTearDown(guest.dispose);
      final joining = guest.joinRoom('123456', displayName: '  Aisha  ');
      expect(guest.ownDisplayName, 'Aisha');
      expect(guest.phase, TogetherPhase.waitingGuest);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(guest.lastGuestName, 'Aisha');
      await joining.timeout(const Duration(seconds: 30));
      expect(guest.error, isNot(kTogetherGuestNameRequiredMessage));
    });

    test('a bad code still fails before the name gate', () async {
      final guest = newService();
      addTearDown(guest.dispose);
      final ok = await guest.joinRoom('12');
      expect(ok, isFalse);
      expect(guest.error, 'Enter the 6-digit room code from the host.');
    });
  });

  group('chat shows names', () {
    String chatPayload({
      required String senderId,
      required String senderLabel,
      String? senderName,
      String? senderRole,
      String text = 'hello',
    }) => jsonEncode(<String, dynamic>{
      'kind': 'chat',
      'id': '$senderId-1',
      'senderId': senderId,
      'senderLabel': senderLabel,
      'text': text,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
      if (senderName != null) 'senderName': senderName,
      if (senderRole != null) 'senderRole': senderRole,
    });

    test('a guest message renders the typed name', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        chatPayload(
          senderId: 'guest-a',
          senderLabel: 'Friend',
          senderName: 'Aisha',
          senderRole: 'guest',
          text: 'this scene!',
        ),
      );
      expect(guest.messages, hasLength(1));
      final message = guest.messages.single;
      expect(message.senderName, 'Aisha');
      expect(message.senderRole, 'guest');
      expect(
        togetherChatSenderDisplayName(message, mine: false),
        'Aisha',
      );
    });

    test('a host message renders HOST (crown + label)', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        chatPayload(
          senderId: 'host-1',
          senderLabel: 'Friend',
          senderRole: 'host',
          text: 'welcome in',
        ),
      );
      expect(guest.messages, hasLength(1));
      expect(
        togetherChatSenderDisplayName(guest.messages.single, mine: false),
        'HOST',
      );
    });

    test('an old client without a name falls back to the old label', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        chatPayload(senderId: 'guest-old', senderLabel: 'Friend'),
      );
      expect(
        togetherChatSenderDisplayName(guest.messages.single, mine: false),
        'Friend',
      );
    });

    test('own messages still render as You', () {
      const mine = TogetherChatMessage(
        id: 'me-1',
        senderId: 'me',
        senderLabel: 'You',
        text: 'hi',
        timestampMs: 0,
        senderName: 'Aisha',
        senderRole: 'guest',
      );
      expect(togetherChatSenderDisplayName(mine, mine: true), 'You');
    });
  });

  group('member display labels', () {
    test('host is HOST, guests are their typed names', () {
      const host = TogetherMember(clientId: 'host-1', role: 'host');
      const guest = TogetherMember(
        clientId: 'guest-a',
        role: 'guest',
        displayName: 'Aisha',
      );
      const nameless = TogetherMember(clientId: 'guest-b', role: 'guest');
      expect(host.displayLabel, 'HOST');
      expect(host.isHost, isTrue);
      expect(guest.displayLabel, 'Aisha');
      expect(guest.isHost, isFalse);
      expect(nameless.displayLabel, 'Guest');
    });

    test('presence carries the typed name into the member list', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(jsonEncode(<String, dynamic>{
        'kind': 'presence',
        'senderId': 'host-1',
        'role': 'host',
        'joined': true,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      }));
      guest.debugReceivePayloadForTest(jsonEncode(<String, dynamic>{
        'kind': 'presence',
        'senderId': 'guest-a',
        'role': 'guest',
        'joined': true,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
        'displayName': 'Aisha',
      }));
      expect(
        guest.members.map((m) => m.displayLabel),
        ['HOST', 'Aisha'],
      );
    });
  });
}
