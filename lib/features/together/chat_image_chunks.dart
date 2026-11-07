import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Chunked Together chat-image transfer (2.8.0).
///
/// The public MQTT relay cannot carry a 5 MB message in one packet, so a
/// chat photo travels as many small chunks on the room topic instead of
/// one giant `chat` message. Pure Dart — no Flutter, no MQTT, no player —
/// so the splitting, reassembly and integrity check unit-test without a
/// broker.
///
/// Wire shape (every chunk is one JSON publish, QoS 1, never retained):
/// ```json
/// {
///   "kind": "chat-image-chunk",
///   "messageId": "yumeflix-ab12-1700000000000-3",
///   "senderId": "yumeflix-ab12cd34",
///   "timestampMs": 1700000000000,
///   "totalChunks": 160,
///   "chunkIndex": 42,
///   "totalBytes": 5242880,
///   "sha256": "<hex of the whole image>",
///   "data": "<base64 of this chunk's raw bytes>",
///   "replyToId": "...",        // only when replying
///   "replyToText": "..."       // only when replying
/// }
/// ```
///
/// * [kTogetherChatChunkBytes] (32 KiB of raw bytes per chunk) keeps every
///   publish far below the broker's packet limit, including the base64
///   expansion (~43 KiB on the wire per chunk) and the JSON envelope.
/// * The receiver reassembles by `chunkIndex` in a map, so chunks may
///   arrive out of order and QoS-1 duplicates are harmless (same index
///   overwrites the same bytes). A message is delivered only when every
///   index 0..totalChunks-1 is present AND the reassembled bytes match
///   `totalBytes` AND their SHA-256 matches `sha256` — a truncated or
///   corrupted transfer is never shown as a photo.
/// * Missing chunks are retried, not the whole image: the receiver
///   publishes `chat-image-request` (`{kind, messageId, missing: [..]}`)
///   and the sender re-publishes just those indices; the receiver sends
///   `chat-image-ack` (`{kind, messageId}`) once the image is complete so
///   the sender can drop its retained copy. The retry/ack bookkeeping
///   lives in [TogetherService]; this file is only the byte math.

/// Raw image bytes per chunk. 32 KiB keeps a publish small on the wire
/// (~43 KiB after base64) while keeping a 5 MB photo to ~160 chunks.
const int kTogetherChatChunkBytes = 32 * 1024;

/// Maximum chat image size, in raw bytes: 5 MB. Images over this are
/// downscaled/compressed on-device until they fit (see
/// [TogetherService.sendChatImage]); only an image that still cannot fit
/// is refused.
const int kTogetherMaxChatImageBytes = 5 * 1024 * 1024;

/// Gap between chunk publishes on the public relay.
///
/// Measured on the live EMQX public broker (2026-11-07, two-process
/// probes with independent sender/receiver processes): 32 chunks sent
/// back-to-back, or 100 ms apart, lost ~40–70% of the burst — a
/// contiguous middle run, identical on both receivers, so the loss is
/// broker-side, not the client (QoS 0 vs 1 made no difference, and
/// neither did smaller 1 KiB chunks). Gaps of 200 ms, 250 ms and 500 ms
/// all delivered 32/32 first-pass. 250 ms keeps a safety margin above
/// the ~200 ms threshold: a 1 MB photo takes ~8 s to send, a 5 MB photo
/// ~40 s, with progress shown throughout. The missing-chunk retry
/// protocol stays as the backstop for the odd lost chunk on a real
/// network.
const Duration kTogetherChatChunkPublishGap = Duration(milliseconds: 250);

/// One chunk of a chat image, ready to publish.
class TogetherImageChunk {
  const TogetherImageChunk({
    required this.messageId,
    required this.senderId,
    required this.timestampMs,
    required this.totalChunks,
    required this.chunkIndex,
    required this.totalBytes,
    required this.sha256Hex,
    required this.dataBase64,
    this.replyToId,
    this.replyToText,
  });

  /// The chat message id this chunk belongs to (`<senderId>-<millis>-<n>`).
  final String messageId;

  /// MQTT client id of the sender.
  final String senderId;

  /// Wall-clock milliseconds when the image was sent.
  final int timestampMs;

  /// How many chunks the whole image was split into.
  final int totalChunks;

  /// This chunk's index, 0-based.
  final int chunkIndex;

  /// Total raw image bytes across all chunks.
  final int totalBytes;

  /// Lowercase hex SHA-256 of the whole image (all chunks concatenated).
  final String sha256Hex;

  /// Base64 of this chunk's raw bytes only.
  final String dataBase64;

  /// Reply target, when the photo replies to a message.
  final String? replyToId;

  /// Quoted text of the message replied to, for display.
  final String? replyToText;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'chat-image-chunk',
    'messageId': messageId,
    'senderId': senderId,
    'timestampMs': timestampMs,
    'totalChunks': totalChunks,
    'chunkIndex': chunkIndex,
    'totalBytes': totalBytes,
    'sha256': sha256Hex,
    'data': dataBase64,
    if (replyToId != null) 'replyToId': replyToId,
    if (replyToText != null) 'replyToText': replyToText,
  };

  factory TogetherImageChunk.fromJson(Map<String, dynamic> json) =>
      TogetherImageChunk(
        messageId: (json['messageId'] as String?) ?? '',
        senderId: (json['senderId'] as String?) ?? '',
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
        totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 0,
        chunkIndex: (json['chunkIndex'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        sha256Hex: (json['sha256'] as String?) ?? '',
        dataBase64: (json['data'] as String?) ?? '',
        replyToId: json['replyToId'] as String?,
        replyToText: json['replyToText'] as String?,
      );
}

/// SHA-256 of [bytes] as lowercase hex — the integrity check for a
/// reassembled image.
String togetherImageChecksum(Uint8List bytes) =>
    sha256.convert(bytes).toString();

/// Splits [bytes] into chunks of at most [kTogetherChatChunkBytes].
///
/// Returns an empty list for empty input (callers treat that as
/// "nothing to send", never as a zero-chunk image).
List<TogetherImageChunk> splitImageIntoChunks({
  required Uint8List bytes,
  required String messageId,
  required String senderId,
  required int timestampMs,
  String? replyToId,
  String? replyToText,
}) {
  if (bytes.isEmpty) return const <TogetherImageChunk>[];
  final totalChunks =
      (bytes.length + kTogetherChatChunkBytes - 1) ~/ kTogetherChatChunkBytes;
  final checksum = togetherImageChecksum(bytes);
  final chunks = <TogetherImageChunk>[];
  for (var i = 0; i < totalChunks; i++) {
    final start = i * kTogetherChatChunkBytes;
    var end = start + kTogetherChatChunkBytes;
    if (end > bytes.length) end = bytes.length;
    chunks.add(
      TogetherImageChunk(
        messageId: messageId,
        senderId: senderId,
        timestampMs: timestampMs,
        totalChunks: totalChunks,
        chunkIndex: i,
        totalBytes: bytes.length,
        sha256Hex: checksum,
        dataBase64: base64Encode(bytes.sublist(start, end)),
        replyToId: replyToId,
        replyToText: replyToText,
      ),
    );
  }
  return chunks;
}

/// Detected image format, from magic bytes — never from a file extension
/// or a MIME claim, both of which the picker cannot be trusted for.
enum TogetherImageFormat { jpeg, png, webp, gif, unknown }

/// Reads the format off the first bytes: JPEG `FF D8 FF`, PNG
/// `89 50 4E 47`, GIF `GIF8`, WebP `RIFF....WEBP`.
TogetherImageFormat detectImageFormat(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return TogetherImageFormat.jpeg;
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return TogetherImageFormat.png;
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return TogetherImageFormat.gif;
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return TogetherImageFormat.webp;
  }
  return TogetherImageFormat.unknown;
}

/// One image transfer in flight, for the progress UI.
///
/// The service exposes the live set of these (sending and receiving);
/// the chat panel renders a progress row for each incomplete one. A
/// transfer disappears from the set the moment it completes or fails —
/// the completed photo is a normal chat message by then.
class TogetherImageTransfer {
  const TogetherImageTransfer({
    required this.messageId,
    required this.isOutgoing,
    required this.receivedChunks,
    required this.totalChunks,
  });

  /// The chat message id the transfer belongs to.
  final String messageId;

  /// True while this phone is sending, false while receiving.
  final bool isOutgoing;

  /// Chunks sent / received so far.
  final int receivedChunks;

  /// Chunks in total (0 until the first chunk announces it).
  final int totalChunks;

  /// 0..1 fraction, for a progress bar. 0 when the total is unknown.
  double get progress =>
      totalChunks <= 0 ? 0 : receivedChunks / totalChunks;

  /// True once every chunk is in.
  bool get isComplete =>
      totalChunks > 0 && receivedChunks >= totalChunks;
}

/// Reassembles one incoming image from its chunks.
///
/// Chunks may arrive in any order and twice (QoS 1); each index is kept
/// once, and [tryAssemble] returns the image bytes only when every index
/// is present, the length matches, and the SHA-256 matches. Anything
/// else returns null — a partial or corrupt transfer is never delivered.
class TogetherImageReassembler {
  TogetherImageReassembler({
    required this.messageId,
    required this.totalChunks,
    required this.totalBytes,
    required this.sha256Hex,
  });

  /// The chat message id being reassembled.
  final String messageId;

  /// Total chunks expected (from the first chunk seen).
  final int totalChunks;

  /// Total raw bytes expected.
  final int totalBytes;

  /// Expected SHA-256 of the whole image, lowercase hex.
  final String sha256Hex;

  final Map<int, Uint8List> _chunks = <int, Uint8List>{};

  /// Indices received so far.
  int get receivedCount => _chunks.length;

  /// Indices still missing, in order.
  List<int> get missingIndices {
    final missing = <int>[];
    for (var i = 0; i < totalChunks; i++) {
      if (!_chunks.containsKey(i)) missing.add(i);
    }
    return missing;
  }

  /// True once every index has arrived (before the integrity check).
  bool get isComplete => receivedCount >= totalChunks;

  /// Records [chunk]'s bytes. Returns false when the chunk does not
  /// belong to this transfer (wrong message id) or its index is out of
  /// range — such a chunk is dropped, never stored.
  bool addChunk(TogetherImageChunk chunk) {
    if (chunk.messageId != messageId) return false;
    if (chunk.chunkIndex < 0 || chunk.chunkIndex >= totalChunks) {
      return false;
    }
    // A duplicate (QoS-1 re-delivery) overwrites identical bytes.
    _chunks[chunk.chunkIndex] = base64Decode(chunk.dataBase64);
    return true;
  }

  /// The reassembled image bytes, or null when incomplete or failing
  /// the integrity check (wrong length or wrong SHA-256).
  Uint8List? tryAssemble() {
    if (!isComplete) return null;
    final out = BytesBuilder();
    for (var i = 0; i < totalChunks; i++) {
      final bytes = _chunks[i];
      if (bytes == null) return null;
      out.add(bytes);
    }
    final assembled = out.takeBytes();
    if (assembled.length != totalBytes) return null;
    if (togetherImageChecksum(assembled) != sha256Hex) return null;
    return assembled;
  }
}
