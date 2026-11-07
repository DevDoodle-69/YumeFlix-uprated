import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/chat_image_chunks.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.8.0 chunked chat images: 5 MB photos split into 32 KiB chunks with a
/// SHA-256 integrity check, reassembled out of order and through
/// duplicates, with missing-chunk retry — plus the service-level send /
/// receive flow through the publish sink. No relay, no network (except the
/// fake clock for the retry timer).
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  /// Deterministic pseudo-random bytes (not an image — only the chunk
  /// math cares), [length] bytes long.
  Uint8List noisyBytes(int length, {int seed = 7}) {
    final random = Random(seed);
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  /// A minimal PNG: the real magic bytes plus padding. Enough for the
  /// format check and the "send as-is" path; not a decodable picture.
  Uint8List fakePng(int length) {
    final bytes = noisyBytes(length);
    bytes[0] = 0x89;
    bytes[1] = 0x50;
    bytes[2] = 0x4E;
    bytes[3] = 0x47;
    return bytes;
  }

  List<TogetherImageChunk> chunksFor(
    Uint8List bytes, {
    String messageId = 'peer-1-1700000000000-1',
    String senderId = 'peer-1',
  }) {
    return splitImageIntoChunks(
      bytes: bytes,
      messageId: messageId,
      senderId: senderId,
      timestampMs: 1_700_000_000_000,
    );
  }

  group('chunk publish pacing', () {
    test('gap is 250 ms — the measured live-broker threshold', () {
      // Probes on the live EMQX public broker (2026-11-07): 20 ms and
      // 100 ms gaps lost ~40–70% of a 32-chunk burst (broker-side: two
      // independent receivers lost the identical indices); 200/250/500 ms
      // gaps all delivered 32/32 first-pass. 250 ms keeps margin above
      // the ~200 ms threshold.
      expect(
        kTogetherChatChunkPublishGap,
        const Duration(milliseconds: 250),
      );
    });
  });

  group('splitImageIntoChunks', () {
    test('empty input splits to nothing', () {
      expect(chunksFor(Uint8List(0)), isEmpty);
    });

    test('chunk counts follow the 32 KiB size', () {
      expect(chunksFor(noisyBytes(1)).length, 1);
      expect(chunksFor(noisyBytes(kTogetherChatChunkBytes)).length, 1);
      expect(chunksFor(noisyBytes(kTogetherChatChunkBytes + 1)).length, 2);
      expect(chunksFor(noisyBytes(1024 * 1024)).length, 32);
      expect(chunksFor(noisyBytes(5 * 1024 * 1024)).length, 160);
    });

    test('every chunk is at most 32 KiB on the wire, and the budget is 5 MB', () {
      expect(kTogetherChatChunkBytes, 32 * 1024);
      expect(kTogetherMaxChatImageBytes, 5 * 1024 * 1024);
      final chunks = chunksFor(noisyBytes(100000));
      for (final chunk in chunks) {
        expect(base64Decode(chunk.dataBase64).length,
            lessThanOrEqualTo(kTogetherChatChunkBytes));
      }
      expect(chunks.last.chunkIndex, chunks.length - 1);
    });

    test('chunks carry the message id, order, totals and checksum', () {
      final bytes = noisyBytes(70000);
      final chunks = chunksFor(bytes);
      expect(chunks.length, 3);
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].chunkIndex, i);
        expect(chunks[i].totalChunks, 3);
        expect(chunks[i].totalBytes, 70000);
        expect(chunks[i].sha256Hex, togetherImageChecksum(bytes));
        expect(chunks[i].messageId, 'peer-1-1700000000000-1');
      }
    });

    test('chunk JSON round-trips intact', () {
      final chunk = chunksFor(noisyBytes(1000)).single;
      final decoded = TogetherImageChunk.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(chunk.toJson())) as Map,
        ),
      );
      expect(decoded.messageId, chunk.messageId);
      expect(decoded.chunkIndex, chunk.chunkIndex);
      expect(decoded.totalChunks, chunk.totalChunks);
      expect(decoded.sha256Hex, chunk.sha256Hex);
      expect(decoded.dataBase64, chunk.dataBase64);
    });
  });

  group('togetherImageChecksum', () {
    test('SHA-256 known vector (empty input)', () {
      expect(
        togetherImageChecksum(Uint8List(0)),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('one changed byte changes the checksum', () {
      final a = noisyBytes(1000);
      final b = Uint8List.fromList(a)..[500] = a[500] ^ 0xFF;
      expect(togetherImageChecksum(a), isNot(togetherImageChecksum(b)));
    });
  });

  group('detectImageFormat', () {
    test('reads magic bytes, never extensions', () {
      expect(
        detectImageFormat(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0])),
        TogetherImageFormat.jpeg,
      );
      expect(
        detectImageFormat(Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47])),
        TogetherImageFormat.png,
      );
      expect(
        detectImageFormat(
          Uint8List.fromList('GIF89a'.codeUnits),
        ),
        TogetherImageFormat.gif,
      );
      expect(
        detectImageFormat(
          Uint8List.fromList(<int>[
            0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
            0x57, 0x45, 0x42, 0x50,
          ]),
        ),
        TogetherImageFormat.webp,
      );
      expect(
        detectImageFormat(noisyBytes(64)),
        TogetherImageFormat.unknown,
      );
      expect(detectImageFormat(Uint8List(0)), TogetherImageFormat.unknown);
    });
  });

  group('TogetherImageReassembler', () {
    test('reassembles in order, out of order, and through duplicates', () {
      final bytes = noisyBytes(100000);
      final chunks = chunksFor(bytes);
      for (final order in <List<int>>[
        [0, 1, 2, 3],
        [3, 1, 0, 2],
        [2, 2, 0, 1, 3, 3],
      ]) {
        final reassembler = TogetherImageReassembler(
          messageId: 'peer-1-1700000000000-1',
          totalChunks: chunks.length,
          totalBytes: bytes.length,
          sha256Hex: togetherImageChecksum(bytes),
        );
        for (final index in order) {
          expect(reassembler.addChunk(chunks[index]), isTrue);
        }
        final assembled = reassembler.tryAssemble();
        expect(assembled, isNotNull);
        expect(assembled, bytes);
      }
    });

    test('missing chunks: no delivery, and the missing list is exact', () {
      final bytes = noisyBytes(100000);
      final chunks = chunksFor(bytes);
      final reassembler = TogetherImageReassembler(
        messageId: 'peer-1-1700000000000-1',
        totalChunks: chunks.length,
        totalBytes: bytes.length,
        sha256Hex: togetherImageChecksum(bytes),
      );
      reassembler.addChunk(chunks[0]);
      reassembler.addChunk(chunks[3]);
      expect(reassembler.tryAssemble(), isNull);
      expect(reassembler.missingIndices, <int>[1, 2]);
      expect(reassembler.isComplete, isFalse);
      reassembler.addChunk(chunks[1]);
      expect(reassembler.missingIndices, <int>[2]);
      reassembler.addChunk(chunks[2]);
      expect(reassembler.tryAssemble(), bytes);
    });

    test('a corrupted chunk fails the integrity check — never delivered', () {
      final bytes = noisyBytes(70000);
      final chunks = chunksFor(bytes);
      final reassembler = TogetherImageReassembler(
        messageId: 'peer-1-1700000000000-1',
        totalChunks: chunks.length,
        totalBytes: bytes.length,
        sha256Hex: togetherImageChecksum(bytes),
      );
      for (final chunk in chunks) {
        reassembler.addChunk(chunk);
      }
      // Corrupt one stored chunk's bytes by re-adding a tampered copy.
      final tampered = TogetherImageChunk(
        messageId: chunks[1].messageId,
        senderId: chunks[1].senderId,
        timestampMs: chunks[1].timestampMs,
        totalChunks: chunks[1].totalChunks,
        chunkIndex: 1,
        totalBytes: chunks[1].totalBytes,
        sha256Hex: chunks[1].sha256Hex,
        dataBase64: base64Encode(
          Uint8List.fromList(
            base64Decode(chunks[1].dataBase64)..[0] ^= 0xFF,
          ),
        ),
      );
      reassembler.addChunk(tampered);
      expect(reassembler.tryAssemble(), isNull);
    });

    test('a chunk from another message, or out of range, is dropped', () {
      final bytes = noisyBytes(70000);
      final chunks = chunksFor(bytes);
      final reassembler = TogetherImageReassembler(
        messageId: 'peer-1-1700000000000-1',
        totalChunks: chunks.length,
        totalBytes: bytes.length,
        sha256Hex: togetherImageChecksum(bytes),
      );
      final foreign = TogetherImageChunk(
        messageId: 'someone-else-1',
        senderId: 'peer-2',
        timestampMs: 1,
        totalChunks: 3,
        chunkIndex: 0,
        totalBytes: 70000,
        sha256Hex: chunks[0].sha256Hex,
        dataBase64: chunks[0].dataBase64,
      );
      expect(reassembler.addChunk(foreign), isFalse);
      final outOfRange = TogetherImageChunk(
        messageId: 'peer-1-1700000000000-1',
        senderId: 'peer-1',
        timestampMs: 1,
        totalChunks: 3,
        chunkIndex: 9,
        totalBytes: 70000,
        sha256Hex: chunks[0].sha256Hex,
        dataBase64: chunks[0].dataBase64,
      );
      expect(reassembler.addChunk(outOfRange), isFalse);
      expect(reassembler.receivedCount, 0);
    });

    test('a wrong total length fails even with all chunks present', () {
      final bytes = noisyBytes(70000);
      final chunks = chunksFor(bytes);
      final reassembler = TogetherImageReassembler(
        messageId: 'peer-1-1700000000000-1',
        totalChunks: chunks.length,
        totalBytes: 69999, // lie about the length
        sha256Hex: togetherImageChecksum(bytes),
      );
      for (final chunk in chunks) {
        reassembler.addChunk(chunk);
      }
      expect(reassembler.tryAssemble(), isNull);
    });
  });

  group('service: receiving chunked images', () {
    TogetherService receivingGuest({
      required List<Map<String, dynamic>> published,
    }) {
      final guest = newService();
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      return guest;
    }

    void feedChunks(
      TogetherService service,
      List<TogetherImageChunk> chunks,
    ) {
      for (final chunk in chunks) {
        service.debugReceivePayloadForTest(jsonEncode(chunk.toJson()));
      }
    }

    test('out-of-order + duplicate chunks deliver the exact photo', () {
      final published = <Map<String, dynamic>>[];
      final guest = receivingGuest(published: published);
      addTearDown(guest.dispose);
      final bytes = noisyBytes(100000);
      final chunks = chunksFor(bytes);
      // Reverse order, with a duplicate of chunk 1.
      feedChunks(guest, [chunks[3], chunks[1], chunks[0], chunks[1], chunks[2]]);
      expect(guest.messages.length, 1);
      final message = guest.messages.single;
      expect(message.isImage, isTrue);
      expect(base64Decode(message.imageBase64!), bytes);
      expect(message.senderLabel, 'Friend');
      // Complete: no transfer left in flight, and the sender got its ack.
      expect(guest.imageTransfers, isEmpty);
      expect(
        published.where((p) => p['kind'] == 'chat-image-ack').length,
        1,
      );
      expect(
        published
            .firstWhere((p) => p['kind'] == 'chat-image-ack')['messageId'],
        'peer-1-1700000000000-1',
      );
    });

    test('progress is visible while receiving', () {
      final published = <Map<String, dynamic>>[];
      final guest = receivingGuest(published: published);
      addTearDown(guest.dispose);
      final bytes = noisyBytes(100000);
      final chunks = chunksFor(bytes);
      feedChunks(guest, [chunks[0], chunks[1]]);
      expect(guest.messages, isEmpty);
      final transfers = guest.imageTransfers;
      expect(transfers.length, 1);
      expect(transfers.single.isOutgoing, isFalse);
      expect(transfers.single.receivedChunks, 2);
      expect(transfers.single.totalChunks, 4);
      expect(transfers.single.progress, 0.5);
      feedChunks(guest, [chunks[2], chunks[3]]);
      expect(guest.messages.length, 1);
      expect(guest.imageTransfers, isEmpty);
    });

    test('last chunk with a gap asks for exactly the missing indices', () {
      final published = <Map<String, dynamic>>[];
      final guest = receivingGuest(published: published);
      addTearDown(guest.dispose);
      final bytes = noisyBytes(100000);
      final chunks = chunksFor(bytes);
      // All but chunk 1, last chunk included: the request goes out at once.
      feedChunks(guest, [chunks[0], chunks[2], chunks[3]]);
      expect(guest.messages, isEmpty);
      final requests = published
          .where((p) => p['kind'] == 'chat-image-request')
          .toList();
      expect(requests.length, 1);
      expect(requests.single['missing'], <int>[1]);
      // The missing piece arrives: the photo completes.
      feedChunks(guest, [chunks[1]]);
      expect(guest.messages.length, 1);
      expect(base64Decode(guest.messages.single.imageBase64!), bytes);
    });

    test('three unanswered retry requests end in an honest line, '
        'not a silent hole', () {
      fakeAsync((async) {
        final published = <Map<String, dynamic>>[];
        final guest = receivingGuest(published: published);
        addTearDown(guest.dispose);
        final bytes = noisyBytes(100000);
        final chunks = chunksFor(bytes);
        feedChunks(guest, [chunks[0]]);
        expect(guest.messages, isEmpty);
        // 5 s timer, three requests, then failure (~20 s of fake time).
        async.elapse(const Duration(seconds: 6));
        expect(
          published.where((p) => p['kind'] == 'chat-image-request').length,
          1,
        );
        async.elapse(const Duration(seconds: 5));
        expect(
          published.where((p) => p['kind'] == 'chat-image-request').length,
          2,
        );
        async.elapse(const Duration(seconds: 5));
        expect(
          published.where((p) => p['kind'] == 'chat-image-request').length,
          3,
        );
        async.elapse(const Duration(seconds: 6));
        expect(guest.messages.length, 1);
        expect(
          guest.messages.single.text,
          contains('couldn’t be received completely'),
        );
        expect(guest.imageTransfers, isEmpty);
      });
    });

    test('a chunk over the 5 MB budget is dropped', () {
      final published = <Map<String, dynamic>>[];
      final guest = receivingGuest(published: published);
      addTearDown(guest.dispose);
      final bytes = noisyBytes(70000);
      final chunks = chunksFor(bytes);
      // Lie: claim 6 MB total.
      final lying = TogetherImageChunk(
        messageId: chunks[0].messageId,
        senderId: chunks[0].senderId,
        timestampMs: chunks[0].timestampMs,
        totalChunks: chunks[0].totalChunks,
        chunkIndex: 0,
        totalBytes: 6 * 1024 * 1024,
        sha256Hex: chunks[0].sha256Hex,
        dataBase64: chunks[0].dataBase64,
      );
      guest.debugReceivePayloadForTest(jsonEncode(lying.toJson()));
      expect(guest.messages, isEmpty);
      expect(guest.imageTransfers, isEmpty);
    });
  });

  group('service: sending chunked images', () {
    test('a small photo sends as-is, in chunks, with an ack clearing it',
        () async {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final bytes = fakePng(100000);
      final result = await host.sendChatImage(bytes);
      expect(result, TogetherImageSendResult.sent);
      // Local echo at once, exact bytes.
      expect(host.messages.length, 1);
      expect(base64Decode(host.messages.single.imageBase64!), bytes);
      // 100 000 bytes -> 4 chunks, all published, none retained.
      final chunks = published
          .where((p) => p['kind'] == 'chat-image-chunk')
          .toList();
      expect(chunks.length, 4);
      expect(chunks.map((c) => c['chunkIndex']).toList(), <int>[0, 1, 2, 3]);
      expect(chunks.every((c) => c['sha256'] == togetherImageChecksum(bytes)),
          isTrue);
      expect(host.imageTransfers, isEmpty);

      // The peer acks: the retained copy is dropped, so a later retry
      // request for the same message re-publishes nothing.
      final messageId = host.messages.single.id;
      final before = published.length;
      host.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat-image-ack',
          'messageId': messageId,
          'senderId': 'peer-1',
          'timestampMs': 1_700_000_000_000,
        }),
      );
      host.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat-image-request',
          'messageId': messageId,
          'senderId': 'peer-1',
          'missing': <int>[1],
          'timestampMs': 1_700_000_000_000,
        }),
      );
      expect(published.length, before);
    });

    test('an over-budget real photo is shrunk on-device until it fits',
        () async {
      // A real 2000x1500 noise photo: PNG of noise is ~9 MB, well over
      // budget — so the send must decode and shrink it, not refuse it.
      final pixels = Uint8List(2000 * 1500 * 4);
      final random = Random(99);
      for (var i = 0; i < pixels.length; i++) {
        pixels[i] = random.nextInt(256);
      }
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        2000,
        1500,
        ui.PixelFormat.rgba8888,
        decoded.complete,
        rowBytes: 2000 * 4,
      );
      final image = await decoded.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = png!.buffer.asUint8List();
      expect(bytes.length, greaterThan(kTogetherMaxChatImageBytes));

      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final result = await host.sendChatImage(bytes);
      expect(result, TogetherImageSendResult.sent);
      final sent = base64Decode(host.messages.single.imageBase64!);
      expect(sent.length, lessThanOrEqualTo(kTogetherMaxChatImageBytes));
      // It travelled chunked, like every photo.
      expect(
        published.where((p) => p['kind'] == 'chat-image-chunk').length,
        greaterThan(1),
      );
    });

    test('a retry request re-publishes only the missing chunks', () async {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final bytes = fakePng(100000);
      await host.sendChatImage(bytes);
      final messageId = host.messages.single.id;
      published.clear();
      host.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat-image-request',
          'messageId': messageId,
          'senderId': 'peer-1',
          'missing': <int>[1, 3],
          'timestampMs': 1_700_000_000_000,
        }),
      );
      final republished = published
          .where((p) => p['kind'] == 'chat-image-chunk')
          .toList();
      expect(republished.length, 2);
      expect(
        republished.map((c) => c['chunkIndex']).toList(),
        <int>[1, 3],
      );
    });

    test('not connected -> notConnected, and nothing is sent', () async {
      final host = newService();
      addTearDown(host.dispose);
      // No room at all.
      expect(
        await host.sendChatImage(fakePng(1000)),
        TogetherImageSendResult.notConnected,
      );
      expect(host.messages, isEmpty);
    });

    test('garbage bytes -> unreadable; oversize GIF -> tooLarge', () async {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');

      expect(
        await host.sendChatImage(noisyBytes(1000)),
        TogetherImageSendResult.unreadable,
      );
      expect(host.messages, isEmpty);
      expect(published, isEmpty);

      // A 6 MB "GIF": shrinking would flatten the animation, so it is
      // refused outright instead of being silently destroyed.
      final bigGif = noisyBytes(6 * 1024 * 1024);
      bigGif[0] = 0x47;
      bigGif[1] = 0x49;
      bigGif[2] = 0x46;
      bigGif[3] = 0x38;
      expect(
        await host.sendChatImage(bigGif),
        TogetherImageSendResult.tooLarge,
      );
      expect(host.messages, isEmpty);
      expect(published, isEmpty);
    });
  });
}
