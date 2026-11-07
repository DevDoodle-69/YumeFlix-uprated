import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_data.dart';

import 'models.dart';
import 'sync_math.dart';

/// The relay is a public meeting point, not a YumeFlix server: two phones
/// can never find each other with only a 6-digit code and no rendezvous, so
/// the app ships the broker address baked in and the user never types a URL.
///
/// Primary first, public fallback second, both no-auth secure WebSocket.
/// If neither answers, Together says so plainly instead of failing quietly.
class _Broker {
  const _Broker(this.host, this.port);
  final String host;
  final int port;
}

const List<_Broker> _kBrokers = <_Broker>[
  _Broker('broker.emqx.io', 8084),
  _Broker('test.mosquitto.org', 8081),
];

/// Room topic for [otp]: `yumeflix/together/v1/<6-digit code>`.
String togetherTopicFor(String otp) => 'yumeflix/together/v1/$otp';

/// What a room is doing, from this phone's point of view.
enum TogetherPhase {
  /// No room. The Together tab offers Create / Join (and a rejoin card).
  idle,

  /// Host created a room and is picking a title; nothing is live yet.
  pendingHost,

  /// Guest joined a room and is waiting for the host to press Start.
  waitingGuest,

  /// The host pressed Start (or a guest joined a live room): the host's
  /// state is flowing and playback is synced.
  live,

  /// The relay could not be reached, or the room could not be joined.
  error,
}

enum TogetherRole { host, guest }

/// Maximum image payload for a chat photo, after downscaling: ~120 KB of
/// base64-able bytes. A photo that is still bigger is refused with a toast
/// rather than breaking the room for the other phone.
const int kTogetherMaxChatImageBytes = 120 * 1024;

/// How often every member reports its own position (heartbeat), and how
/// long a host may go quiet before the guest decides it has left.
const Duration kTogetherHeartbeatInterval = Duration(seconds: 2);
const Duration kTogetherHostSilenceTimeout = Duration(seconds: 8);

/// The user-facing message when the relay cannot be reached. Shown verbatim
/// by the UI — never a silent failure, never a stack trace.
const String kTogetherRelayUnreachableMessage =
    "Couldn't reach the Together relay — check internet and retry.";

/// Owns one Together room: the MQTT relay connection, host/guest state,
/// chat, heartbeats and last-room persistence.
///
/// A [ChangeNotifier]: the Together tab and the player hook watch it and
/// rebuild when the phase, the room state, the chat or the unread badge
/// changes. Heartbeats deliberately do NOT notify — they arrive every two
/// seconds and nothing on screen needs them, except the rejoin-adoption
/// path, which notifies only when it actually sets a seek target.
///
/// Never logs message contents, room codes or payloads: connection events
/// only, and only in debug builds.
class TogetherService extends ChangeNotifier {
  TogetherService({Random? random, SharedPreferences? preferences})
    : _random = random ?? Random.secure(),
      _preferencesOverride = preferences;

  final Random _random;
  final SharedPreferences? _preferencesOverride;

  /// Stable per-install sender id. Random, not the user: there is no account.
  late final String clientId =
      'yumeflix-${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updatesSub;
  Timer? _heartbeatTimer;
  Timer? _hostSilenceTimer;
  Timer? _persistTimer;

  TogetherPhase _phase = TogetherPhase.idle;
  TogetherRole? _role;
  String? _otp;
  TogetherRoomState? _roomState;
  TogetherMediaIdentity? _pendingMedia;
  String? _error;
  bool _hostGone = false;
  bool _chatHasUnread = false;
  bool _chatPanelOpen = false;
  bool _disposed = false;

  /// Last room this device was in, for the "Rejoin room …?" card.
  TogetherLastRoom? _lastRoom;

  final List<TogetherChatMessage> _messages = <TogetherChatMessage>[];

  /// Recent peer heartbeats, keyed by sender id. Only the newest per peer
  /// is kept; entries older than 10 s are ignored by adoption.
  final Map<String, HeartbeatSample> _peerHeartbeats = <String, HeartbeatSample>{};

  int _sequence = 0;
  int _messageCounter = 0;
  int _lastSeenSequence = -1;

  /// Last local playback position, whatever the role: the rejoin snapshot
  /// and the host's Start position both come from here.
  int _lastLocalPositionMs = 0;
  int _lastLocalDurationMs = 0;
  bool _lastLocalPlaying = false;

  /// Last host state this device published, for change detection.
  int _lastPublishedPositionMs = -1;
  bool _lastPublishedPlaying = false;
  DateTime? _lastPublishedAt;

  /// Set while a rejoining host is waiting on peer heartbeats to decide
  /// where the room has got to. The player hook consumes it once.
  int? _pendingAdoptedSeekMs;
  bool _adoptingRejoin = false;

  /// What [retry] should redo: 'create' or 'join'.
  String? _lastAction;

  // ---- Read state (what the UI and the player hook observe) ----

  TogetherPhase get phase => _phase;
  TogetherRole? get role => _role;
  String? get otp => _otp;
  TogetherRoomState? get roomState => _roomState;
  TogetherMediaIdentity? get pendingMedia => _pendingMedia;
  String? get error => _error;
  bool get hostGone => _hostGone;
  bool get chatHasUnread => _chatHasUnread;
  TogetherLastRoom? get lastRoom => _lastRoom;
  List<TogetherChatMessage> get messages => List.unmodifiable(_messages);

  /// True once a room exists in any form — creating, waiting or live.
  bool get isSessionActive =>
      _phase != TogetherPhase.idle && _phase != TogetherPhase.error;

  /// True once the host has pressed Start (or a guest joined a live room).
  bool get isLive => _phase == TogetherPhase.live;

  bool get isConnected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  /// The media the room is about: the live state wins, otherwise the title
  /// the host picked while the room was still pending.
  TogetherMediaIdentity? get currentMedia =>
      _roomState?.media ?? _pendingMedia;

  int get lastLocalPositionMs => _lastLocalPositionMs;

  /// One-shot seek target a rejoining host adopted from the room. Returns
  /// null (and clears) when there is nothing to adopt.
  int? consumeAdoptedSeek() {
    final target = _pendingAdoptedSeekMs;
    _pendingAdoptedSeekMs = null;
    return target;
  }

  // ---- Lifecycle ----

  /// Loads the persisted last room (for the rejoin card). Call once from
  /// the Together tab; safe to call again, it just re-reads.
  Future<void> loadLastRoom() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_kLastRoomKey);
    if (raw == null) return;
    try {
      final room = TogetherLastRoom.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      if (room.otp.isNotEmpty && isValidOtp(room.otp)) {
        _lastRoom = room;
        notifyListeners();
      }
    } catch (_) {
      // A corrupt snapshot is not a room; drop it quietly.
      await prefs.remove(_kLastRoomKey);
    }
  }

  static const String _kLastRoomKey = 'together.last_room';

  Future<SharedPreferences> _prefs() async =>
      _preferencesOverride ?? await SharedPreferences.getInstance();

  Future<void> _persistLastRoom() async {
    final otp = _otp;
    final role = _role;
    if (otp == null || role == null) return;
    final room = TogetherLastRoom(
      otp: otp,
      role: role.name,
      media: currentMedia,
      positionMs: _lastLocalPositionMs,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _lastRoom = room;
    try {
      final prefs = await _prefs();
      await prefs.setString(_kLastRoomKey, jsonEncode(room.toJson()));
    } catch (_) {
      // Persistence is a convenience; a failure must not break the room.
    }
  }

  /// Forgets the persisted last room (the rejoin card's Dismiss).
  Future<void> dismissLastRoom() async {
    _lastRoom = null;
    try {
      final prefs = await _prefs();
      await prefs.remove(_kLastRoomKey);
    } catch (_) {}
    notifyListeners();
  }

  // ---- Creating and joining ----

  /// Host: generates a code, opens the relay and waits for a title to be
  /// picked. Returns false (and sets [error]) when the relay is unreachable.
  Future<bool> createRoom() async {
    _resetRoomState();
    // Set AFTER the reset: the reset clears the last action.
    _lastAction = 'create';
    _role = TogetherRole.host;
    _otp = generateOtp(_random);
    _phase = TogetherPhase.pendingHost;
    notifyListeners();
    final ok = await _connectAndSubscribe();
    if (!ok) {
      _phase = TogetherPhase.error;
      _error = kTogetherRelayUnreachableMessage;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    return true;
  }

  /// Guest: joins [otp] and waits for the host to press Start. A retained
  /// room state arriving means the room is already live.
  Future<bool> joinRoom(String otp) async {
    final code = otp.trim();
    if (!isValidOtp(code)) {
      _error = 'Enter the 6-digit room code from the host.';
      _phase = TogetherPhase.error;
      notifyListeners();
      return false;
    }
    _resetRoomState();
    // Set AFTER the reset: the reset clears the last action.
    _lastAction = 'join';
    _role = TogetherRole.guest;
    _otp = code;
    _phase = TogetherPhase.waitingGuest;
    notifyListeners();
    final ok = await _connectAndSubscribe();
    if (!ok) {
      _phase = TogetherPhase.error;
      _error = kTogetherRelayUnreachableMessage;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    _armHostSilenceTimer();
    return true;
  }

  /// Re-enters the persisted last room, in its old role. A returning host
  /// adopts the room's current position (furthest peer heartbeat, advanced
  /// by elapsed time) instead of rewinding everyone, then re-asserts host
  /// authority.
  Future<bool> rejoinLastRoom() async {
    final last = _lastRoom;
    if (last == null) return false;
    if (last.role == TogetherRole.host.name) {
      // adoptRejoin travels as a parameter: setting the flag here would be
      // wiped by the reset inside createRoomWithCode.
      final ok = await createRoomWithCode(last.otp, adoptRejoin: true);
      if (ok && last.media != null) {
        _pendingMedia = last.media;
        notifyListeners();
      }
      return ok;
    }
    return joinRoom(last.otp);
  }

  /// Like [createRoom] but with a fixed code — used only for a host rejoin.
  /// [adoptRejoin] keeps the host in "adopt the room's current position"
  /// mode until the retained state / first heartbeat answers.
  Future<bool> createRoomWithCode(String otp, {bool adoptRejoin = false}) async {
    _resetRoomState();
    _adoptingRejoin = adoptRejoin;
    // Set AFTER the reset: the reset clears the last action.
    _lastAction = 'create';
    _role = TogetherRole.host;
    _otp = otp;
    _phase = TogetherPhase.pendingHost;
    notifyListeners();
    final ok = await _connectAndSubscribe();
    if (!ok) {
      _phase = TogetherPhase.error;
      _error = kTogetherRelayUnreachableMessage;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    return true;
  }

  /// Retries whatever [createRoom]/[joinRoom] last attempted.
  Future<bool> retry() async {
    if (_lastAction == 'join' && _otp != null) return joinRoom(_otp!);
    return createRoom();
  }

  /// Leaves the room. A host says goodbye first (so the guest's controls
  /// unlock and playback carries on locally) and clears the retained room
  /// state; the last-room snapshot is kept for the rejoin card.
  Future<void> leaveRoom() async {
    final wasHost = _role == TogetherRole.host;
    final topic = _otp == null ? null : togetherTopicFor(_otp!);
    if (isConnected && topic != null) {
      if (wasHost) {
        _publish(topic, <String, dynamic>{
          'kind': 'bye',
          'senderId': clientId,
        });
        // Clear the retained room state so a late joiner does not resurrect
        // a finished room: an empty retained publish deletes it.
        _publishRaw(topic, Uint8List(0), retain: true);
      }
    }
    await _persistLastRoom();
    _resetRoomState();
    _phase = TogetherPhase.idle;
    _disconnect();
    notifyListeners();
  }

  void _resetRoomState() {
    _heartbeatTimer?.cancel();
    _hostSilenceTimer?.cancel();
    _persistTimer?.cancel();
    _heartbeatTimer = null;
    _hostSilenceTimer = null;
    _persistTimer = null;
    _role = null;
    _otp = null;
    _roomState = null;
    _pendingMedia = null;
    _error = null;
    _hostGone = false;
    _chatHasUnread = false;
    _chatPanelOpen = false;
    _messages.clear();
    _peerHeartbeats.clear();
    _sequence = 0;
    _lastSeenSequence = -1;
    _lastPublishedPositionMs = -1;
    _lastPublishedPlaying = false;
    _lastPublishedAt = null;
    _pendingAdoptedSeekMs = null;
    _adoptingRejoin = false;
    _lastAction = null;
  }

  // ---- Media + going live ----

  /// Called by the player hook when playback opens with a Together session
  /// attached. Records the title the room is about; a live host re-publishes
  /// its state under the new media.
  void attachMedia(TogetherMediaIdentity media) {
    if (!isSessionActive) return;
    final changed = _pendingMedia != media;
    _pendingMedia = media;
    if (_role == TogetherRole.host && _phase == TogetherPhase.live) {
      _publishState(force: true);
    } else if (changed) {
      notifyListeners();
    }
    unawaited(_persistLastRoom());
  }

  /// Host: goes live at [positionMs] and publishes the first retained state.
  /// A rejoining host passes the adopted position (see [rejoinLastRoom]).
  void goLive({required int positionMs, required int durationMs}) {
    if (_role != TogetherRole.host || _pendingMedia == null) return;
    _phase = TogetherPhase.live;
    _hostGone = false;
    _publishState(
      force: true,
      positionMs: positionMs,
      durationMs: durationMs,
      playing: true,
    );
    unawaited(_persistLastRoom());
    notifyListeners();
  }

  /// Called by the player hook on every engine tick. The host publishes on
  /// play/pause flips, on seeks, and at most once a second while playing;
  /// a guest only records its own position for the rejoin snapshot.
  void reportLocalPlayback({
    required int positionMs,
    required int durationMs,
    required bool playing,
  }) {
    final positionChanged = (positionMs - _lastLocalPositionMs).abs() > 2000;
    _lastLocalPositionMs = positionMs;
    _lastLocalDurationMs = durationMs;
    final playingFlipped = playing != _lastLocalPlaying;
    _lastLocalPlaying = playing;
    if (_role != TogetherRole.host || _phase != TogetherPhase.live) return;
    if (!isConnected) return;
    final now = DateTime.now();
    final due =
        _lastPublishedAt == null ||
        now.difference(_lastPublishedAt!).inMilliseconds >= 1000;
    if (playingFlipped || positionChanged || (playing && due)) {
      _publishState(force: true);
    }
  }

  void _publishState({
    bool force = false,
    int? positionMs,
    int? durationMs,
    bool? playing,
  }) {
    final media = _pendingMedia ?? _roomState?.media;
    final topic = _otp == null ? null : togetherTopicFor(_otp!);
    if (media == null || topic == null || !isConnected) return;
    final pos = positionMs ?? _lastLocalPositionMs;
    final dur = durationMs ?? _lastLocalDurationMs;
    final isPlaying = playing ?? _lastLocalPlaying;
    if (!force &&
        pos == _lastPublishedPositionMs &&
        isPlaying == _lastPublishedPlaying) {
      return;
    }
    _sequence += 1;
    final state = TogetherRoomState(
      media: media,
      positionMs: pos,
      durationMs: dur,
      playing: isPlaying,
      hostTimestampMs: DateTime.now().millisecondsSinceEpoch,
      sequence: _sequence,
      hostId: clientId,
    );
    _roomState = state;
    _lastPublishedPositionMs = pos;
    _lastPublishedPlaying = isPlaying;
    _lastPublishedAt = DateTime.now();
    _publish(topic, <String, dynamic>{
      'kind': 'state',
      ...state.toJson(),
    }, retain: true);
  }

  // ---- Chat ----

  /// Whether the chat panel is currently open. The player screen sets this
  /// so an incoming message can decide between appearing in the list and
  /// lighting the unread badge.
  void setChatPanelOpen(bool open) {
    _chatPanelOpen = open;
    if (open) _chatHasUnread = false;
  }

  void markChatRead() {
    if (!_chatHasUnread) return;
    _chatHasUnread = false;
    notifyListeners();
  }

  Future<void> sendChatText(
    String text, {
    String? replyToId,
    String? replyToText,
  }) async {
    final body = text.trim();
    if (body.isEmpty || !isSessionActive || !isConnected) return;
    final message = _buildMessage(text: body, replyToId: replyToId, replyToText: replyToText);
    _messages.add(message);
    notifyListeners();
    _publishToRoom(<String, dynamic>{
      'kind': 'chat',
      ...message.toJson(),
    });
  }

  /// Sends a photo from the gallery/camera roll. Downscales to a small
  /// image first; returns false (and sends nothing) when the photo is still
  /// over the ~120 KB budget — the UI then tells the viewer to pick a
  /// smaller photo instead of breaking the room.
  Future<bool> sendChatImage(Uint8List bytes) async {
    if (!isSessionActive || !isConnected) return false;
    final shrunk = await _downscaleImage(bytes);
    if (shrunk == null || shrunk.length > kTogetherMaxChatImageBytes) {
      return false;
    }
    final message = _buildMessage(imageBase64: base64Encode(shrunk));
    _messages.add(message);
    notifyListeners();
    _publishToRoom(<String, dynamic>{
      'kind': 'chat',
      ...message.toJson(),
    });
    return true;
  }

  TogetherChatMessage _buildMessage({
    String? text,
    String? imageBase64,
    String? replyToId,
    String? replyToText,
  }) {
    _messageCounter += 1;
    return TogetherChatMessage(
      id: '$clientId-${DateTime.now().millisecondsSinceEpoch}-$_messageCounter',
      senderId: clientId,
      senderLabel: 'You',
      text: text,
      imageBase64: imageBase64,
      replyToId: replyToId,
      replyToText: replyToText,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Downscales [bytes] to at most 640 px on the long side and re-encodes
  /// as PNG. Returns null when the bytes are not a decodable image.
  Future<Uint8List?> _downscaleImage(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 640,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  // ---- Relay connection ----

  Future<bool> _connectAndSubscribe() async {
    final otp = _otp;
    if (otp == null) return false;
    for (final broker in _kBrokers) {
      final client = MqttServerClient.withPort(broker.host, clientId, broker.port);
      client.useWebSocket = true;
      // Secure WebSocket (wss) on the broker's TLS websocket port.
      client.secure = true;
      client.websocketProtocols = const <String>['mqtt'];
      client.keepAlivePeriod = 20;
      client.logging(on: false);
      client.onConnected = _onConnected;
      client.onDisconnected = _onDisconnected;
      client.connectionMessage = MqttConnectMessage()
          .withClientIdentifier(clientId)
          .startClean();
      try {
        await client.connect();
      } catch (_) {
        try {
          client.disconnect();
        } catch (_) {}
        continue;
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        try {
          client.disconnect();
        } catch (_) {}
        continue;
      }
      _client = client;
      final topic = togetherTopicFor(otp);
      client.subscribe(topic, MqttQos.atLeastOnce);
      unawaited(_updatesSub?.cancel());
      _updatesSub = client.updates?.listen(_onMessages);
      return true;
    }
    return false;
  }

  void _onConnected() {
    if (kDebugMode) debugPrint('Together: relay connected');
  }

  void _onDisconnected() {
    if (_disposed) return;
    if (kDebugMode) debugPrint('Together: relay disconnected');
    if (isSessionActive && _phase != TogetherPhase.error) {
      // A dropped relay mid-room is the same user-facing fact as a relay
      // that never answered: say so, keep the room's local state so a
      // retry can pick it up again.
      _error = kTogetherRelayUnreachableMessage;
      _phase = TogetherPhase.error;
      notifyListeners();
    }
  }

  void _disconnect() {
    _updatesSub?.cancel();
    _updatesSub = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.disconnect();
      } catch (_) {}
    }
  }

  void _publish(String topic, Map<String, dynamic> json, {bool retain = false}) {
    _publishRaw(
      topic,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
      retain: retain,
    );
  }

  void _publishToRoom(Map<String, dynamic> json, {bool retain = false}) {
    final otp = _otp;
    if (otp == null) return;
    _publish(togetherTopicFor(otp), json, retain: retain);
  }

  void _publishRaw(String topic, Uint8List payload, {bool retain = false}) {
    final client = _client;
    if (client == null || !isConnected) return;
    // publishMessage takes a Uint8Buffer, not a Uint8List: the builder's
    // addBuffer has the same type, so build the buffer directly.
    final buffer = Uint8Buffer()..addAll(payload);
    try {
      client.publishMessage(
        topic,
        MqttQos.atLeastOnce,
        buffer,
        retain: retain,
      );
    } catch (_) {
      // A failed publish is a dropped beat, not a crash: the next heartbeat
      // or state publish carries the same facts.
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final payload = event.payload;
      if (payload is! MqttPublishMessage) continue;
      final text = utf8.decode(payload.payload.message, allowMalformed: true);
      _handlePayload(text);
    }
  }

  void _handlePayload(String text) {
    Map<String, dynamic> json;
    try {
      json = Map<String, dynamic>.from(jsonDecode(text) as Map);
    } catch (_) {
      return; // Not ours; ignore rather than fail the room.
    }
    final kind = json['kind'] as String?;
    final senderId = json['senderId'] as String?;
    // Own messages come back from the broker too (we are subscribed to our
    // own topic); the local copy is already in the list.
    if (senderId == clientId && kind != 'state') return;
    switch (kind) {
      case 'state':
        _handleState(json);
      case 'chat':
        _handleChat(json);
      case 'heartbeat':
        _handleHeartbeat(json);
      case 'bye':
        _handleBye(json);
    }
  }

  void _handleState(Map<String, dynamic> json) {
    TogetherRoomState state;
    try {
      state = TogetherRoomState.fromJson(json);
    } catch (_) {
      return;
    }
    // Out-of-order delivery: an older sequence is stale, not an update.
    if (state.sequence <= _lastSeenSequence) return;
    _lastSeenSequence = state.sequence;
    final wasWaiting = _phase == TogetherPhase.waitingGuest;
    // Notify only on something the UI can see: a phase change, a new title,
    // or a play/pause flip. The position itself ticks once a second and the
    // player hook reads it straight off the service — notifying for it
    // would rebuild the player screen every second for nothing.
    final previous = _roomState;
    final mediaChanged = previous?.media != state.media;
    final playingFlipped = previous?.playing != state.playing;
    _roomState = state;
    _pendingMedia ??= state.media;
    if (_role == TogetherRole.guest && _phase == TogetherPhase.waitingGuest) {
      _phase = TogetherPhase.live;
    }
    if (_role == TogetherRole.host && _adoptingRejoin) {
      _adoptRejoinFromState(state);
    }
    _armHostSilenceTimer();
    if (wasWaiting || mediaChanged || playingFlipped) notifyListeners();
  }

  void _handleChat(Map<String, dynamic> json) {
    TogetherChatMessage message;
    try {
      message = TogetherChatMessage.fromJson(json);
    } catch (_) {
      return;
    }
    if (message.id.isEmpty) return;
    if (_messages.any((m) => m.id == message.id)) return;
    // Rendered as "Friend": the other phone has no name, and the label is
    // decided here, not trusted from the wire.
    final inbound = TogetherChatMessage(
      id: message.id,
      senderId: message.senderId,
      senderLabel: 'Friend',
      text: message.text,
      imageBase64: message.imageBase64,
      replyToId: message.replyToId,
      replyToText: message.replyToText,
      timestampMs: message.timestampMs,
    );
    _messages.add(inbound);
    if (!_chatPanelOpen) _chatHasUnread = true;
    notifyListeners();
  }

  void _handleHeartbeat(Map<String, dynamic> json) {
    final senderId = json['senderId'] as String?;
    final positionMs = (json['positionMs'] as num?)?.toInt();
    if (senderId == null || senderId == clientId || positionMs == null) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _peerHeartbeats[senderId] = HeartbeatSample(
      positionMs: positionMs,
      receivedAtMs: now,
    );
    // A rejoining host adopts the room's current position from the first
    // heartbeat that proves someone is further along — then re-asserts
    // host authority at that position.
    if (_role == TogetherRole.host && _adoptingRejoin) {
      _adoptRejoinFromHeartbeats();
    }
    // Any traffic from the host proves it is still there.
    if (_role == TogetherRole.guest) _armHostSilenceTimer();
  }

  void _handleBye(Map<String, dynamic> json) {
    final senderId = json['senderId'] as String?;
    // Only the host leaving ends the shared session. A guest leaving
    // changes nothing for the host.
    if (senderId == null || senderId != _roomState?.hostId) return;
    _hostGone = true;
    _hostSilenceTimer?.cancel();
    notifyListeners();
  }

  /// Rejoin adoption from the retained state alone (no peer has reported
  /// yet): advance it by elapsed time and offer it as a seek target.
  void _adoptRejoinFromState(TogetherRoomState state) {
    // Seed the sequence past the old room's: a rejoining host that restarts
    // at 1 would have every state ignored as stale by a guest that already
    // saw sequence 50.
    _sequence = state.sequence;
    final now = DateTime.now().millisecondsSinceEpoch;
    final adopted = adoptRejoinPosition(
      heartbeats: _peerHeartbeats.values.toList(),
      nowMs: now,
      retainedPositionMs: state.positionMs,
      retainedTimestampMs: state.hostTimestampMs,
      retainedPlaying: state.playing,
      durationMs: state.durationMs,
    );
    _pendingAdoptedSeekMs = adopted;
    _adoptingRejoin = false;
    notifyListeners();
  }

  void _adoptRejoinFromHeartbeats() {
    final state = _roomState;
    if (state == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final adopted = adoptRejoinPosition(
      heartbeats: _peerHeartbeats.values.toList(),
      nowMs: now,
      retainedPositionMs: state.positionMs,
      retainedTimestampMs: state.hostTimestampMs,
      retainedPlaying: state.playing,
      durationMs: state.durationMs,
    );
    // Only adopt when a peer is actually ahead — otherwise the retained
    // state is already the furthest point and there is nothing to adopt.
    if (adopted > state.targetPositionMs(nowMs: now)) {
      _pendingAdoptedSeekMs = adopted;
      _adoptingRejoin = false;
      notifyListeners();
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _persistTimer?.cancel();
    _heartbeatTimer = Timer.periodic(kTogetherHeartbeatInterval, (_) {
      if (!isConnected) return;
      _publishToRoom(<String, dynamic>{
        'kind': 'heartbeat',
        'senderId': clientId,
        'positionMs': _lastLocalPositionMs,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      });
    });
    // The rejoin snapshot only needs a position every so often, not on
    // every tick: every 30 s is plenty for "where was I".
    _persistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (isSessionActive) unawaited(_persistLastRoom());
    });
  }

  /// While a guest, silence from the host means the room has gone quiet:
  /// unlock the guest's controls and let playback carry on locally from
  /// the last synced position instead of freezing on a dead room.
  void _armHostSilenceTimer() {
    if (_role != TogetherRole.guest) return;
    _hostSilenceTimer?.cancel();
    _hostSilenceTimer = Timer(kTogetherHostSilenceTimeout, () {
      if (_disposed || _role != TogetherRole.guest) return;
      if (_phase == TogetherPhase.waitingGuest) return;
      _hostGone = true;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeatTimer?.cancel();
    _hostSilenceTimer?.cancel();
    _persistTimer?.cancel();
    _disconnect();
    super.dispose();
  }
}
