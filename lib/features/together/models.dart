/// Data carried by a Together room.
///
/// Plain JSON-able values only: everything here crosses the relay as JSON,
/// and the last room is persisted to SharedPreferences as JSON too. No
/// tokens, no URLs the user typed, no message contents are ever logged —
/// these models are data, not diagnostics.
library;

/// How many guests one room holds, besides the host (2.11.0). A 6th
/// joiner is turned away with [kTogetherRoomFullMessage], never a crash.
const int kTogetherMaxGuests = 5;

/// Longest guest display name, in characters (2.11.0). The join dialog
/// enforces it in the field; [normalizeTogetherGuestName] enforces it again
/// at the service boundary, so a long name can never reach the relay.
const int kTogetherGuestNameMaxLength = 20;

/// Short honest line for a joiner turned away by the guest cap.
const String kTogetherRoomFullMessage =
    'This room is full — the host already has 5 guests.';

/// Short honest line when a guest tries to join without a name.
const String kTogetherGuestNameRequiredMessage =
    'Type your name to join the room.';

/// Trims a guest display name and caps it at
/// [kTogetherGuestNameMaxLength]. Empty stays empty (the caller rejects it).
String normalizeTogetherGuestName(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= kTogetherGuestNameMaxLength) return trimmed;
  return trimmed.substring(0, kTogetherGuestNameMaxLength);
}

/// Null when [value] is a usable guest name, otherwise the inline error
/// the join dialog shows (and the join stays disabled).
String? validateTogetherGuestName(String value) {
  if (value.trim().isEmpty) return 'Type your name to join.';
  return null;
}

/// One phone in a Together room, as the room knows it.
///
/// The host is always `HOST 👑` — they never type a name. A guest is their
/// typed name ([displayName]), never a device name or `Guest 1`.
class TogetherMember {
  const TogetherMember({
    required this.clientId,
    required this.role,
    this.displayName,
  });

  /// MQTT client id of the phone.
  final String clientId;

  /// `host` or `guest` — the role that phone has in the room.
  final String role;

  /// The guest's typed name, or null for the host (and for a guest whose
  /// name never arrived — old clients predate names).
  final String? displayName;

  /// True for the room creator.
  bool get isHost => role == 'host';

  /// What the member list and presence show: `HOST 👑` for the host, the
  /// typed name for a guest, `Guest` when no name is known.
  String get displayLabel {
    if (isHost) return 'HOST 👑';
    final name = displayName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return 'Guest';
  }
}

/// What the room is watching — enough for the other phone to find the same
/// title and for the room card to show it, never a stream URL.
///
/// The relay carries identity, not video: each phone resolves its own
/// playable stream for the title through the normal search/details flow.
///
/// 2.11.0 — the identity also carries what the guest needs to open the
/// SAME source the host chose, not just the same title: [provider] (the
/// plugin the host resolved from), [itemUrl] (the provider detail URL) and
/// [episodeUrl] (the episode data URL the host's player handed to
/// `loadStreams`), plus [source] (the stream-source label the host is
/// actually playing, e.g. `Server 1`). All four are optional: a 2.10.0 host
/// publishes none of them, and the guest then falls back to a title search
/// — the fields are read with `as String?`, so an old payload still parses.
/// A local file is never shared as [episodeUrl]: it does not exist on the
/// guest's phone (see `togetherMediaIdentityFor`).
class TogetherMediaIdentity {
  const TogetherMediaIdentity({
    required this.title,
    this.tmdbType,
    this.tmdbId,
    this.posterUrl,
    this.episodeLabel,
    this.season,
    this.episode,
    this.provider,
    this.itemUrl,
    this.episodeUrl,
    this.source,
  });

  /// Display title, e.g. `Dune` or `Breaking Bad · S2 E5`. The `· S{n} E{n}`
  /// suffix appears only for a true series/anime episode with real
  /// numbering; a movie title never carries one.
  final String title;

  /// TMDB media type when known: `movie` or `tv`.
  final String? tmdbType;

  /// TMDB id when known, so the other phone can open the exact title.
  final int? tmdbId;

  /// Poster URL for the room card. May be an extension poster.
  final String? posterUrl;

  /// e.g. `S2 E5`, when the title is an episode. Null for films, and null
  /// whenever [title] already ends with ` · <episodeLabel>` — a card that
  /// prints the title must not print the label again as a second line.
  final String? episodeLabel;

  /// Season number of the episode, when the title is one (2.11.0 — so the
  /// guest picks the episode by number instead of parsing [episodeLabel]).
  /// Null for films.
  final int? season;

  /// Episode number within [season], when the title is an episode.
  /// Null for films.
  final int? episode;

  /// Provider the host resolved the title from (plugin package name, e.g.
  /// the value `MultimediaItem.provider` carries), when known. The guest
  /// asks the same provider first, so the same catalog answers.
  final String? provider;

  /// Provider detail URL for the title, when known. The guest loads details
  /// from this instead of searching, so it lands on the host's exact item.
  final String? itemUrl;

  /// Episode data URL the host is playing — the token the player's stream
  /// resolver hands to `loadStreams` — when known. The guest resolves
  /// streams from this same token, so it gets the host's source list.
  final String? episodeUrl;

  /// Stream-source label the host is actually playing (e.g. `Server 1`),
  /// when known. The guest puts this source first in its own resolved list
  /// and plays the best available one only when this label is absent from
  /// it (see `orderStreamsForHostSource`).
  final String? source;

  /// True when [title] already ends with ` · <episodeLabel>`, so a card
  /// showing the title must not print the label a second time. A series
  /// episode's `S{n} E{n}` then appears exactly once; a film's never does.
  bool get titleCarriesEpisodeLabel =>
      episodeLabel != null && title.endsWith(' · $episodeLabel');

  /// Are these two identities the same title — the same movie, or the same
  /// episode of the same show?
  ///
  /// TMDB id wins when both sides know it, but a show id alone is never
  /// enough: two episodes of one show share it, so the episode label must
  /// match too whenever either side carries one. Without ids, the
  /// normalised title decides (case / surrounding space ignored) — episode
  /// titles embed their `S/E` suffix, so that comparison already separates
  /// episodes. The source/provider/URLs deliberately do NOT take part: the
  /// same title on a different source is still the same title.
  bool sameTitleAs(TogetherMediaIdentity other) {
    if (tmdbId != null && other.tmdbId != null) {
      if (tmdbId != other.tmdbId) return false;
      if (episodeLabel != null || other.episodeLabel != null) {
        return episodeLabel == other.episodeLabel;
      }
      return true;
    }
    return title.trim().toLowerCase() == other.title.trim().toLowerCase();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    if (tmdbType != null) 'tmdbType': tmdbType,
    if (tmdbId != null) 'tmdbId': tmdbId,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (episodeLabel != null) 'episodeLabel': episodeLabel,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    if (provider != null) 'provider': provider,
    if (itemUrl != null) 'itemUrl': itemUrl,
    if (episodeUrl != null) 'episodeUrl': episodeUrl,
    if (source != null) 'source': source,
  };

  factory TogetherMediaIdentity.fromJson(Map<String, dynamic> json) {
    final rawTitle = (json['title'] as String?) ?? 'Unknown title';
    final tmdbType = json['tmdbType'] as String?;
    final season = (json['season'] as num?)?.toInt();
    final episode = (json['episode'] as num?)?.toInt();
    final provider = json['provider'] as String?;
    final itemUrl = json['itemUrl'] as String?;
    final episodeUrl = json['episodeUrl'] as String?;
    final source = json['source'] as String?;
    // A movie never carries a season/episode suffix — but 2.8.0's room
    // identity appended a dummy S1 E1 to film titles, and that poisoned
    // title travels over the relay and sits in the persisted last room.
    // Strip it at the boundary so an old host's payload (or a stale
    // rejoin snapshot) cannot resurrect "Film · S1 E1" on this phone.
    if (tmdbType == 'movie') {
      return TogetherMediaIdentity(
        title: rawTitle.replaceFirst(RegExp(r' · S\d+ E\d+$'), ''),
        tmdbType: tmdbType,
        tmdbId: json['tmdbId'] as int?,
        posterUrl: json['posterUrl'] as String?,
        provider: provider,
        itemUrl: itemUrl,
        episodeUrl: episodeUrl,
        source: source,
      );
    }
    return TogetherMediaIdentity(
      title: rawTitle,
      tmdbType: tmdbType,
      tmdbId: json['tmdbId'] as int?,
      posterUrl: json['posterUrl'] as String?,
      episodeLabel: json['episodeLabel'] as String?,
      season: season,
      episode: episode,
      provider: provider,
      itemUrl: itemUrl,
      episodeUrl: episodeUrl,
      source: source,
    );
  }

  /// Same title with the host's source replaced (see
  /// `TogetherPlayerHook.updateSource`): a new identity, so the room can
  /// re-publish it and the guest can follow a host source pick.
  TogetherMediaIdentity withSource(String? source) => TogetherMediaIdentity(
    title: title,
    tmdbType: tmdbType,
    tmdbId: tmdbId,
    posterUrl: posterUrl,
    episodeLabel: episodeLabel,
    season: season,
    episode: episode,
    provider: provider,
    itemUrl: itemUrl,
    episodeUrl: episodeUrl,
    source: source,
  );

  @override
  bool operator ==(Object other) =>
      other is TogetherMediaIdentity &&
      other.title == title &&
      other.tmdbType == tmdbType &&
      other.tmdbId == tmdbId &&
      other.posterUrl == posterUrl &&
      other.episodeLabel == episodeLabel &&
      other.season == season &&
      other.episode == episode &&
      other.provider == provider &&
      other.itemUrl == itemUrl &&
      other.episodeUrl == episodeUrl &&
      other.source == source;

  @override
  int get hashCode => Object.hash(
    title,
    tmdbType,
    tmdbId,
    posterUrl,
    episodeLabel,
    season,
    episode,
    provider,
    itemUrl,
    episodeUrl,
    source,
  );
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
    this.playbackSpeed = 1.0,
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

  /// The host's engine speed when the state was stamped (1.0 normally).
  /// Part of the clock, not a decoration: the target advances at this
  /// speed ([targetPositionMs]), and the guest's in-sync rate IS this
  /// speed — a 2x host whose guest chased a 1x target would fall behind
  /// a second every second and seek forever. 1.0 when absent (a 2.10.0
  /// host never sends one).
  final double playbackSpeed;

  /// Where the host would be now, if it kept playing from this state —
  /// at the host's speed, so a 2x host's target moves twice as fast as
  /// the wall clock.
  int targetPositionMs({required int nowMs}) => playing
      ? positionMs + ((nowMs - hostTimestampMs) * playbackSpeed).round()
      : positionMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'media': media.toJson(),
    'positionMs': positionMs,
    'durationMs': durationMs,
    'playing': playing,
    'hostTimestampMs': hostTimestampMs,
    'sequence': sequence,
    'hostId': hostId,
    'playbackSpeed': playbackSpeed,
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
        playbackSpeed: (json['playbackSpeed'] as num?)?.toDouble() ?? 1.0,
      );
}

/// One chat message in a Together room.
///
/// Text or an image, never both; an optional reply quotes the message
/// it answers. Images travel CHUNKED over the same relay topic (see
/// `chat_image_chunks.dart`): up to 5 MB, split into 32 KiB pieces with
/// a SHA-256 check on reassembly — never one giant message. By the time
/// a message with [imageBase64] exists in a list, its bytes are complete
/// and verified; a transfer still missing pieces is not a message yet
/// (see [TogetherService.imageTransfers]).
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
    this.senderName,
    this.senderRole,
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

  /// The sender's typed guest name, when the sender is a guest (2.11.0).
  /// Null for the host (who is `HOST 👑`) and for messages from clients
  /// that predate names.
  final String? senderName;

  /// `host` or `guest` — the sender's role in the room, when known. Null
  /// for messages from clients that predate names; the panel then falls
  /// back to [senderLabel].
  final String? senderRole;

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
    if (senderName != null) 'senderName': senderName,
    if (senderRole != null) 'senderRole': senderRole,
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
        senderName: json['senderName'] as String?,
        senderRole: json['senderRole'] as String?,
      );
}

/// What a chat bubble shows above the text: `You` for own messages,
/// `HOST 👑` (crown + label, never colour alone) for the room creator,
/// the typed name for a guest, and the old `Friend` label for messages
/// from clients that predate names.
String togetherChatSenderDisplayName(
  TogetherChatMessage message, {
  required bool mine,
}) {
  if (mine) return 'You';
  if (message.senderRole == 'host') return 'HOST 👑';
  final name = message.senderName?.trim();
  if (name != null && name.isNotEmpty) return name;
  return message.senderLabel;
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
  hostPaused,

  /// The host left the room (or went silent) — set LOCALLY by the guest
  /// when it learns the host is gone (`bye`, presence `left`, 8 s of
  /// silence, member prune). Never published by the host, and never a
  /// guess about the transport: a stale `hostPlaying`/`hostPaused` after
  /// the host left is how a waiting screen keeps saying "Host is playing"
  /// to an empty room. Cleared the moment fresh host traffic arrives.
  hostLeft;

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
    TogetherRoomStatus.hostLeft => 'Host left the room',
  };
}

/// One live room-status push from the host.
///
/// Non-retained, sent on every status change, re-sent when a guest joins
/// (presence `joined`), and repeated inside the host's heartbeats — so a
/// guest that joins late or loses a packet still learns the status within
/// one heartbeat (1 s) without ever touching the retained state slot.
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
    this.displayName,
  });

  /// MQTT client id of the phone entering / leaving.
  final String senderId;

  /// `host` or `guest` — the role that phone has in the room.
  final String role;

  /// True on join, false on leave.
  final bool joined;

  /// Wall-clock milliseconds when the event was published.
  final int timestampMs;

  /// The guest's typed name, when the sender is a guest (2.11.0). Null
  /// for the host, who is `HOST 👑` without typing a name.
  final String? displayName;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'presence',
    'senderId': senderId,
    'role': role,
    'joined': joined,
    'timestampMs': timestampMs,
    if (displayName != null) 'displayName': displayName,
  };

  factory TogetherPresenceEvent.fromJson(Map<String, dynamic> json) =>
      TogetherPresenceEvent(
        senderId: (json['senderId'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'guest',
        joined: json['joined'] as bool? ?? true,
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
        displayName: json['displayName'] as String?,
      );
}

/// The host turning a joiner away: the room already has
/// [kTogetherMaxGuests] guests. Carries the rejected phone's client id so
/// only that phone acts on it — every other phone ignores it.
class TogetherRoomFullEvent {
  const TogetherRoomFullEvent({
    required this.targetId,
    required this.senderId,
    required this.timestampMs,
    this.message = kTogetherRoomFullMessage,
  });

  /// Client id of the guest being turned away.
  final String targetId;

  /// MQTT client id of the host that sent the rejection.
  final String senderId;

  /// Wall-clock milliseconds when the rejection was published.
  final int timestampMs;

  /// The short honest line the rejected phone shows. Carried on the wire
  /// so any client — including one that predates the constant — can show
  /// exactly what the host meant; the app's own guest side still sets its
  /// error from [kTogetherRoomFullMessage] directly.
  final String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': 'room-full',
    'targetId': targetId,
    'senderId': senderId,
    'timestampMs': timestampMs,
    'message': message,
  };

  factory TogetherRoomFullEvent.fromJson(Map<String, dynamic> json) =>
      TogetherRoomFullEvent(
        targetId: (json['targetId'] as String?) ?? '',
        senderId: (json['senderId'] as String?) ?? '',
        timestampMs: (json['timestampMs'] as num?)?.toInt() ?? 0,
        message:
            (json['message'] as String?) ?? kTogetherRoomFullMessage,
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
