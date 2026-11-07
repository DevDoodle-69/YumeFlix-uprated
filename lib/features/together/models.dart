/// Data carried by a Together room.
///
/// Plain JSON-able values only: everything here crosses the relay as JSON,
/// and the last room is persisted to SharedPreferences as JSON too. No
/// tokens, no URLs the user typed, no message contents are ever logged —
/// these models are data, not diagnostics.
library;

/// What the room is watching — enough for the other phone to find the same
/// title and for the room card to show it, never a stream URL.
///
/// The relay carries identity, not video: each phone resolves its own
/// playable stream for the title through the normal search/details flow.
class TogetherMediaIdentity {
  const TogetherMediaIdentity({
    required this.title,
    this.tmdbType,
    this.tmdbId,
    this.posterUrl,
    this.episodeLabel,
  });

  /// Display title, e.g. `Dune` or `Breaking Bad · S2 E5`.
  final String title;

  /// TMDB media type when known: `movie` or `tv`.
  final String? tmdbType;

  /// TMDB id when known, so the other phone can open the exact title.
  final int? tmdbId;

  /// Poster URL for the room card. May be an extension poster.
  final String? posterUrl;

  /// e.g. `S2 E5`, when the title is an episode.
  final String? episodeLabel;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    if (tmdbType != null) 'tmdbType': tmdbType,
    if (tmdbId != null) 'tmdbId': tmdbId,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (episodeLabel != null) 'episodeLabel': episodeLabel,
  };

  factory TogetherMediaIdentity.fromJson(Map<String, dynamic> json) =>
      TogetherMediaIdentity(
        title: (json['title'] as String?) ?? 'Unknown title',
        tmdbType: json['tmdbType'] as String?,
        tmdbId: json['tmdbId'] as int?,
        posterUrl: json['posterUrl'] as String?,
        episodeLabel: json['episodeLabel'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is TogetherMediaIdentity &&
      other.title == title &&
      other.tmdbType == tmdbType &&
      other.tmdbId == tmdbId &&
      other.posterUrl == posterUrl &&
      other.episodeLabel == episodeLabel;

  @override
  int get hashCode =>
      Object.hash(title, tmdbType, tmdbId, posterUrl, episodeLabel);
}

/// The host's playback state, as published (retained) on the room topic.
///
/// One message, always the latest: a phone that joins late reads this single
/// retained message and knows instantly what is playing and where.
class TogetherRoomState {
  const TogetherRoomState({
    required this.media,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.hostTimestampMs,
    required this.sequence,
    required this.hostId,
  });

  final TogetherMediaIdentity media;

  /// Host's position in milliseconds at [hostTimestampMs].
  final int positionMs;

  /// Media duration in milliseconds (0 when unknown, e.g. a live edge).
  final int durationMs;

  /// Whether the host was playing when the state was stamped.
  final bool playing;

  /// Wall-clock milliseconds when the host stamped this state.
  final int hostTimestampMs;

  /// Monotonic per-room counter: a state with a lower sequence than one
  /// already seen is stale (out-of-order delivery) and must be ignored.
  final int sequence;

  /// The MQTT client id of the host that published this state.
  final String hostId;

  /// Where the host would be now, if it kept playing from this state.
  int targetPositionMs({required int nowMs}) =>
      playing ? positionMs + (nowMs - hostTimestampMs) : positionMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'media': media.toJson(),
    'positionMs': positionMs,
    'durationMs': durationMs,
    'playing': playing,
    'hostTimestampMs': hostTimestampMs,
    'sequence': sequence,
    'hostId': hostId,
  };

  factory TogetherRoomState.fromJson(Map<String, dynamic> json) =>
      TogetherRoomState(
        media: TogetherMediaIdentity.fromJson(
          Map<String, dynamic>.from(json['media'] as Map),
        ),
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        playing: json['playing'] as bool? ?? false,
        hostTimestampMs: (json['hostTimestampMs'] as num?)?.toInt() ?? 0,
        sequence: (json['sequence'] as num?)?.toInt() ?? 0,
        hostId: (json['hostId'] as String?) ?? '',
      );
}

/// One chat message in a Together room.
///
/// Text or a small image, never both; an optional reply quotes the message
/// it answers. Images travel as base64 over the same relay topic, downscaled
/// before sending (see [TogetherService.sendChatImage]).
class TogetherChatMessage {
  const TogetherChatMessage({
    required this.id,
    required this.senderId,
    required this.senderLabel,
    this.text,
    this.imageBase64,
    this.replyToId,
    this.replyToText,
    required this.timestampMs,
  });

  /// Unique per message: `<senderId>-<millis>-<counter>`.
  final String id;

  /// MQTT client id of the sender. Compared with the local client id to
  /// decide whether a message is "mine".
  final String senderId;

  /// Display label: `You` for own messages, `Friend` for the other phone.
  final String senderLabel;

  /// Text body, when this is a text message.
  final String? text;

  /// Base64-encoded downscaled image bytes, when this is an image message.
  final String? imageBase64;

  /// Id of the message this replies to, when replying.
  final String? replyToId;

  /// Quoted text of the message this replies to, for display.
  final String? replyToText;

  /// Wall-clock milliseconds when the message was sent.
  final int timestampMs;

  bool get isImage => imageBase64 != null;

  /// Short quote for a reply: the text, or `Photo` for an image.
  String get quoteText {
    if (text != null && text!.isNotEmpty) return text!;
    if (isImage) return 'Photo';
    return '';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'senderId': senderId,
    'senderLabel': senderLabel,
    if (text != null) 'text': text,
    if (imageBase64 != null) 'imageBase64': imageBase64,
    if (replyToId != null) 'replyToId': replyToId,
    if (replyToText != null) 'replyToText': replyToText,
    'timestampMs': timestampMs,
  };

  factory TogetherChatMessage.fromJson(Map<String, dynamic> json) =>
      TogetherChatMessage(
        id: (json['id'] as String?) ?? '',
        senderId: (json['senderId'] as String?) ?? '',
        senderLabel: (json['senderLabel'] as String?) ?? 'Friend',
        text: json['text'] as String?,
        imageBase64: json['imageBase64'] as String?,
        replyToId: json['replyToId'] as String?,
        replyToText: json['replyToText'] as String?,
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
      );
}

/// Live room status, pushed by the host over MQTT.
///
/// The host is the only publisher: browsing / picked / playing / paused are
/// facts about the host's phone, and the guest renders them — never guesses
/// them. Published NON-retained (see [TogetherRoomStatusMessage]): the room
/// topic holds exactly one retained message and that slot belongs to the
/// playback state, so a late guest learns the status from the host's
/// re-publish (triggered by the guest's presence `joined`) and from the
/// host's heartbeats, which carry the current status too.
enum TogetherRoomStatus {
  /// Host created the room and has not picked a title yet.
  hostBrowsing,

  /// Host picked a title but has not pressed Start yet.
  hostPickedTitle,

  /// Host pressed Start and playback is running.
  hostPlaying,

  /// Host pressed Start and playback is paused.
  hostPaused;

  /// Wire value: the enum name, e.g. `hostBrowsing`.
  String get wireValue => name;

  static TogetherRoomStatus? fromWire(String? value) {
    if (value == null) return null;
    for (final status in TogetherRoomStatus.values) {
      if (status.name == value) return status;
    }
    return null;
  }

  /// What the guest's waiting / live screen shows for this status.
  String get label => switch (this) {
    TogetherRoomStatus.hostBrowsing => 'Host is still finding a movie…',
    TogetherRoomStatus.hostPickedTitle => 'Host picked a title',
    TogetherRoomStatus.hostPlaying => 'Host is playing',
    TogetherRoomStatus.hostPaused => 'Host paused',
  };
}

/// One live room-status push from the host.
///
/// Non-retained, sent on every status change, re-sent when a guest joins
/// (presence `joined`), and repeated inside the host's heartbeats — so a
/// guest that joins late or loses a packet still learns the status within
/// one heartbeat (2 s) without ever touching the retained state slot.
class TogetherRoomStatusMessage {
  const TogetherRoomStatusMessage({
    required this.status,
    this.media,
    required this.senderId,
    required this.timestampMs,
  });

  final TogetherRoomStatus status;

  /// The picked / playing title, when the host has one.
  final TogetherMediaIdentity? media;

  /// MQTT client id of the host that published this status.
  final String senderId;

  /// Wall-clock milliseconds when the status was published.
  final int timestampMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'status',
    'status': status.wireValue,
    if (media != null) 'media': media!.toJson(),
    'senderId': senderId,
    'timestampMs': timestampMs,
  };

  factory TogetherRoomStatusMessage.fromJson(Map<String, dynamic> json) {
    final status = TogetherRoomStatus.fromWire(json['status'] as String?);
    if (status == null) {
      throw const FormatException('unknown Together room status');
    }
    return TogetherRoomStatusMessage(
      status: status,
      media: json['media'] != null
          ? TogetherMediaIdentity.fromJson(
              Map<String, dynamic>.from(json['media'] as Map),
            )
          : null,
      senderId: (json['senderId'] as String?) ?? '',
      timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One presence event: a phone entering or leaving the room.
///
/// Published (non-retained) by every member right after subscribing and
/// again on leaving. The host answers a guest's `joined` with a fresh
/// status publish, which is how a late guest learns what the host is doing
/// without a retained status message.
class TogetherPresenceEvent {
  const TogetherPresenceEvent({
    required this.senderId,
    required this.role,
    required this.joined,
    required this.timestampMs,
  });

  /// MQTT client id of the phone entering / leaving.
  final String senderId;

  /// `host` or `guest` — the role that phone has in the room.
  final String role;

  /// True on join, false on leave.
  final bool joined;

  /// Wall-clock milliseconds when the event was published.
  final int timestampMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'presence',
    'senderId': senderId,
    'role': role,
    'joined': joined,
    'timestampMs': timestampMs,
  };

  factory TogetherPresenceEvent.fromJson(Map<String, dynamic> json) =>
      TogetherPresenceEvent(
        senderId: (json['senderId'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'guest',
        joined: json['joined'] as bool? ?? true,
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
      );
}

/// The last room this device was in, persisted so the app can offer a
/// rejoin after the app restarts or the viewer leaves and comes back.
class TogetherLastRoom {
  const TogetherLastRoom({
    required this.otp,
    required this.role,
    this.media,
    this.positionMs = 0,
    this.savedAtMs = 0,
  });

  /// The 6-digit room code.
  final String otp;

  /// `host` or `guest` — the role this device had in the room.
  final String role;

  final TogetherMediaIdentity? media;

  /// Last known local position in milliseconds.
  final int positionMs;

  /// Wall-clock milliseconds when this snapshot was saved.
  final int savedAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'otp': otp,
    'role': role,
    if (media != null) 'media': media!.toJson(),
    'positionMs': positionMs,
    'savedAtMs': savedAtMs,
  };

  factory TogetherLastRoom.fromJson(Map<String, dynamic> json) =>
      TogetherLastRoom(
        otp: (json['otp'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'guest',
        media: json['media'] != null
            ? TogetherMediaIdentity.fromJson(
                Map<String, dynamic>.from(json['media'] as Map),
              )
            : null,
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        savedAtMs: (json['savedAtMs'] as num?)?.toInt() ?? 0,
      );
}
