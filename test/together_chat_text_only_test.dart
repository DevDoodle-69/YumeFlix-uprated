import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/host_crown_icon.dart';
import 'package:yumeflix/features/together/presentation/together_chat_panel.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.13.0 — image sending was removed from Together chat.
///
/// Text chat, replies and names stay; there is no image attach button,
/// no picker, no chunked photo transfer, and no photo progress UI.
/// Driven offline through the service's test seams
/// ([TogetherService.debugEnterRoomForTest] +
/// [TogetherService.debugReceivePayloadForTest]) — no relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  String chatPayload({
    required String id,
    required String senderId,
    String? text,
    String? replyToId,
    String? replyToText,
    String? senderName,
    String? senderRole,
    Map<String, dynamic>? extra,
  }) {
    final json = <String, dynamic>{
      'kind': 'chat',
      'id': id,
      'senderId': senderId,
      'senderLabel': 'Friend',
      'timestampMs': 1_700_000_000_000,
      ...?extra,
    };
    if (text != null) json['text'] = text;
    if (replyToId != null) json['replyToId'] = replyToId;
    if (replyToText != null) json['replyToText'] = replyToText;
    if (senderName != null) json['senderName'] = senderName;
    if (senderRole != null) json['senderRole'] = senderRole;
    return jsonEncode(json);
  }

  group('text chat still works', () {
    test('inbound text lands in the list with its sender name', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        chatPayload(
          id: 'host-1',
          senderId: 'host-1',
          text: 'that scene!',
          senderRole: 'host',
        ),
      );
      expect(guest.messages, hasLength(1));
      expect(guest.messages.single.text, 'that scene!');
      expect(
        togetherChatSenderDisplayName(guest.messages.single, mine: false),
        'HOST',
      );
    });

    test('a guest reply keeps its quote and the guest name', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.debugReceivePayloadForTest(
        chatPayload(
          id: 'guest-1',
          senderId: 'guest-1',
          text: 'I know, right?',
          replyToId: 'host-1',
          replyToText: 'that scene!',
          senderName: 'Aisha',
          senderRole: 'guest',
        ),
      );
      final message = host.messages.single;
      expect(message.text, 'I know, right?');
      expect(message.replyToId, 'host-1');
      expect(message.replyToText, 'that scene!');
      expect(message.quoteText, 'I know, right?');
      expect(
        togetherChatSenderDisplayName(message, mine: false),
        'Aisha',
      );
    });

    test('a text message round-trips without any image field', () {
      const message = TogetherChatMessage(
        id: 'yumeflix-1-1',
        senderId: 'yumeflix-1',
        senderLabel: 'Friend',
        text: 'hello',
        timestampMs: 1_000_000,
        senderName: 'Aisha',
        senderRole: 'guest',
      );
      final json = message.toJson();
      expect(json.containsKey('imageBase64'), isFalse);
      final decoded = TogetherChatMessage.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(json)) as Map,
        ),
      );
      expect(decoded.text, 'hello');
      expect(decoded.quoteText, 'hello');
    });
  });

  group('legacy image traffic is ignored, not shown', () {
    test('a text-less chat payload (old photo message) never lands', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        chatPayload(
          id: 'host-photo-1',
          senderId: 'host-1',
          senderRole: 'host',
          extra: <String, dynamic>{'imageBase64': 'aGVsbG8='},
        ),
      );
      expect(guest.messages, isEmpty);
    });

    test('a stray imageBase64 key is dropped by the model parser', () {
      final decoded = TogetherChatMessage.fromJson(<String, dynamic>{
        'id': 'old-1',
        'senderId': 'host-1',
        'senderLabel': 'Friend',
        'imageBase64': 'aGVsbG8=',
        'timestampMs': 1_000_000,
      });
      expect(decoded.text, isNull);
      expect(decoded.quoteText, isEmpty);
    });

    test('a legacy chat-image-chunk payload is ignored', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat-image-chunk',
          'messageId': 'host-photo-1',
          'senderId': 'host-1',
          'timestampMs': 1_700_000_000_000,
          'totalChunks': 1,
          'chunkIndex': 0,
          'totalBytes': 5,
          'sha256': 'deadbeef',
          'data': 'aGVsbG8=',
        }),
      );
      expect(guest.messages, isEmpty);
    });

    test('legacy chat-image-request / chat-image-ack payloads are ignored',
        () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      for (final kind in const <String>[
        'chat-image-request',
        'chat-image-ack',
      ]) {
        guest.debugReceivePayloadForTest(
          jsonEncode(<String, dynamic>{
            'kind': kind,
            'messageId': 'host-photo-1',
            'senderId': 'host-1',
            'timestampMs': 1_700_000_000_000,
          }),
        );
      }
      expect(guest.messages, isEmpty);
    });
  });

  group('chat panel has no image UI', () {
    Future<void> pumpPanel(
      WidgetTester tester,
      TogetherService service,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TogetherChatPanel(service: service, onClose: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no attach button, no photo progress, composer stays',
        (tester) async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      await pumpPanel(tester, guest);

      expect(find.byIcon(Icons.image_outlined), findsNothing);
      expect(find.byTooltip('Send a photo'), findsNothing);
      expect(find.textContaining('Sending photo'), findsNothing);
      expect(find.textContaining('Receiving photo'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(find.text('Say hi to start the watch party'), findsOneWidget);
    });

    testWidgets('text renders with the sender name and HOST crown',
        (tester) async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      await pumpPanel(tester, guest);
      guest.debugReceivePayloadForTest(
        chatPayload(
          id: 'host-1',
          senderId: 'host-1',
          text: 'that scene!',
          senderRole: 'host',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('that scene!'), findsOneWidget);
      expect(find.text('HOST'), findsOneWidget);
      expect(find.byType(HostIdentityLabel), findsOneWidget);
    });

    testWidgets('long-press offers a reply and shows the quote',
        (tester) async {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      await pumpPanel(tester, guest);
      guest.debugReceivePayloadForTest(
        chatPayload(
          id: 'host-1',
          senderId: 'host-1',
          text: 'that scene!',
          senderRole: 'host',
        ),
      );
      await tester.pumpAndSettle();

      await tester.longPress(find.text('that scene!'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Replying to HOST'), findsOneWidget);
      expect(find.textContaining('that scene!'), findsWidgets);
    });
  });
}
