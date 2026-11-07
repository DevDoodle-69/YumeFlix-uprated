import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_data.dart';

import 'connection.dart';
import 'models.dart';
import 'sync_math.dart';

/// The relay is a public meeting point, not a YumeFlix server: two phones
/// can never find each other with only a 6-digit code and no rendezvous, so
/// the app ships the broker address baked in and the user never types a URL.
///
/// Relays live in [kTogetherRelays] (see `connection.dart`): EMQX first,
/// Mosquitto second, both no-auth secure WebSocket. The client
/// construction there is the one `mqtt_client` requires for wss — a
/// `wss://…/mqtt` URL with `useWebSocket = true` and the `secure` flag
/// left alone (it is TCP-only; setting it together with `useWebSocket`
/// silently turned the websocket back off and made 2.6.0 fail on every
/// network). If neither relay answers, Together says which relays it
/// tried and what actually failed, instead of blaming the user's internet.

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

/// How long a waiting guest gives the host to show any sign of life
/// (status, heartbeat, presence or retained state) after joining before
/// the waiting screen says so instead of spinning forever. The host
/// publishes a status the moment the room is created and a heartbeat every
/// 2 s, so 30 s of total silence genuinely means the relay or the host is
/// gone — not that the host is browsing slowly.
const Duration kTogetherWaitingStaleTimeout = Duration(seconds: 30);

/// Reconnect backoff and the attempt cap live in `connection.dart`
/// ([kTogetherReconnectDelaysSeconds], [kTogetherMaxReconnectAttempts])
/// so they are unit-tested alongside the failure classification.

/// Fallback user-facing message when the relay cannot be reached and no
/// classified failure is available. Shown verbatim by the UI — never a
/// silent failure, never a stack trace, and never a claim about the
/// user's internet: the classified message on [TogetherConnectFailure]
/// is what the service normally sets instead.
const String kTogetherRelayUnreachableMessage =
    "Couldn't reach the Together relay — it didn't answer. Try again in a moment.";

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
  Timer? _reconnectTimer;
  Timer? _waitingStaleTimer;

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

  /// Latest live room status, from the host's own status pushes (or, for a
  /// guest, from the host's heartbeats / retained state). Starts at
  /// `hostBrowsing`: a room is born with the host still finding a movie.
  TogetherRoomStatus _roomStatus = TogetherRoomStatus.hostBrowsing;

  /// Client id of the host, once known (retained state, status, presence
  /// or heartbeat). Used to recognise the host's `bye` even while the guest
  /// is still waiting and no retained state has arrived yet.
  String? _hostClientId;

  /// Who is in the room right now, client id -> role (`host` / `guest`),
  /// including this phone. Built from presence events plus any traffic
  /// from the host; a `bye` / presence `left` removes the sender.
  final Map<String, String> _presentMembers = <String, String>{};

  /// True while a relay drop is being retried in the background. The room
  /// (and its phase) is kept: a reconnect that lands resumes the same room.
  bool _reconnecting = false;
  int _reconnectAttempt = 0;

  /// Relay that answered the current connection, e.g. `EMQX` — null while
  /// not connected. Shown in the room's connection status indicator.
  String? _connectedRelayLabel;

  /// Last measured MQTT round-trip, in milliseconds, or null before the
  /// first heartbeat echo comes back. Measured, never guessed: our own
  /// heartbeat publish is echoed back by the broker (we subscribe to our
  /// own topic), and the echo's timestamp is the send time.
  int? _roundTripMs;

  /// Why the last connection attempt failed, when it failed. The UI shows
  /// its honest message instead of a generic "check internet" line.
  TogetherConnectFailure? _lastFailure;

  /// Relay labels tried by the last connection attempt, in order.
  List<String> _attemptedRelayLabels = const <String>[];

  /// Set while the connection is being (re)established, so a disconnect
  /// callback from a client that never connected cannot start a reconnect
  /// loop of its own.
  bool _connecting = false;

  /// Set before every intentional disconnect (leave / dispose) so
  /// [_onDisconnected] knows the drop was asked for.
  bool _intentionalDisconnect = false;

  /// True once a waiting guest has heard nothing from the host for
  /// [kTogetherWaitingStaleTimeout] after joining. The waiting screen then
  /// shows a "no signal from the host" state with Retry / Leave instead of
  /// spinning forever. Cleared by any host traffic.
  bool _waitingStale = false;

  /// Wall-clock milliseconds when this guest joined (waiting clock).
  int? _waitingSinceMs;

  /// Last host status this device published, for change detection: the
  /// host publishes a status only when it actually changes.
  TogetherRoomStatus? _lastPublishedStatus;

  /// Floating-orb position as a fraction of the screen (0..1 on each axis),
  /// so it survives rotation and different screen sizes. Null until loaded
  /// from SharedPreferences or first dragged.
  ui.Offset? _orbPositionFraction;

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

  /// Player-owned actions for the single root-mounted floating orb.
  ///
  /// The orb lives above the router (see `main.dart`) so it survives every
  /// route push, but only the player knows the engine's live position and
  /// only the player screen owns the chat panel. The player hook registers
  /// its `goLive` here while a player is open and clears it on dispose;
  /// the player screen does the same for opening the chat panel. The orb
  /// reads these and falls back to navigation ("open the title") when no
  /// player is open. These are UI wiring only — no MQTT, no room state.
  VoidCallback? _orbStartAction;
  VoidCallback? _orbOpenChatAction;

  /// The player hook's live Start action, or null while no player is open.
  VoidCallback? get orbStartAction => _orbStartAction;

  /// The player screen's open-chat action, or null while no player is open.
  VoidCallback? get orbOpenChatAction => _orbOpenChatAction;

  void registerOrbStartAction(VoidCallback? action) {
    if (_orbStartAction == action) return;
    _orbStartAction = action;
    notifyListeners();
  }

  void registerOrbOpenChatAction(VoidCallback? action) {
    if (_orbOpenChatAction == action) return;
    _orbOpenChatAction = action;
    notifyListeners();
  }

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

  /// Latest live room status, pushed by the host. The guest's waiting
  /// screen renders this — it is a real MQTT fact, never a local guess.
  TogetherRoomStatus get roomStatus => _roomStatus;

  /// True while a relay drop is being retried in the background.
  bool get reconnecting => _reconnecting;

  /// 0-based reconnect attempt in progress (0 while idle / connected).
  int get reconnectAttempt => _reconnectAttempt;

  /// Relay that answered the current connection (`EMQX`, `Mosquitto`),
  /// or null while not connected.
  String? get connectedRelayLabel => _connectedRelayLabel;

  /// Last measured MQTT round-trip in milliseconds, or null before the
  /// first heartbeat echo. A real measurement, never a guess.
  int? get roundTripMs => _roundTripMs;

  /// Why the last connection attempt failed, when it failed.
  TogetherConnectFailure? get lastFailure => _lastFailure;

  /// Relay labels tried by the last connection attempt, in order.
  List<String> get attemptedRelayLabels =>
      List.unmodifiable(_attemptedRelayLabels);

  /// One-line connection status for the room UI: relay name, reconnecting
  /// state, and latency when it has really been measured.
  String get connectionStatusLabel => togetherConnectionStatusLabel(
    connected: isConnected,
    reconnecting: _reconnecting,
    connecting: _connecting,
    relayLabel: _connectedRelayLabel,
    roundTripMs: _roundTripMs,
    reconnectAttempt: _reconnectAttempt,
    lastTriedRelaysLabel: _attemptedRelayLabels.isEmpty
        ? null
        : _attemptedRelayLabels.join(', '),
  );

  /// True once a waiting guest has heard nothing from the host for
  /// [kTogetherWaitingStaleTimeout] after joining.
  bool get waitingStale => _waitingStale;

  /// Wall-clock milliseconds when this guest joined, for the waiting clock.
  int? get waitingSinceMs => _waitingSinceMs;

  /// True when the host is known to be in the room right now.
  bool get hostPresent =>
      _presentMembers.values.contains(TogetherRole.host.name);

  /// True when a guest is known to be in the room right now.
  bool get guestPresent =>
      _presentMembers.values.contains(TogetherRole.guest.name);

  /// How many phones are in the room, as far as this phone knows.
  int get memberCount => _presentMembers.length;

  /// One-line presence summary, e.g. `Host + Guest` or `Host only`.
  String get presenceLabel {
    if (hostPresent && guestPresent) return 'Host + Guest in room';
    if (hostPresent) return 'Host in room';
    if (guestPresent) return 'Guest in room';
    return 'Waiting for the other phone…';
  }

  /// Floating-orb position as a screen fraction, or null until loaded.
  ui.Offset? get orbPositionFraction => _orbPositionFraction;

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

  // ---- Test seams ----

  /// Enters a room without touching the relay: host lands in
  /// [TogetherPhase.pendingHost], guest in [TogetherPhase.waitingGuest].
  /// Test-only — production entry is [createRoom]/[joinRoom].
  @visibleForTesting
  void debugEnterRoomForTest({
    required TogetherRole role,
    required String otp,
  }) {
    _resetRoomState();
    _role = role;
    _otp = otp;
    _phase = role == TogetherRole.host
        ? TogetherPhase.pendingHost
        : TogetherPhase.waitingGuest;
    if (role == TogetherRole.guest) {
      _waitingSinceMs = DateTime.now().millisecondsSinceEpoch;
    }
    notifyListeners();
  }

  /// Feeds one relay payload through the normal inbound path
  /// ([_handlePayload]), as if it had arrived from the broker. Test-only.
  @visibleForTesting
  void debugReceivePayloadForTest(String json) => _handlePayload(json);

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

  static const String _kOrbXKey = 'together.orb_x';
  static const String _kOrbYKey = 'together.orb_y';

  /// Loads the persisted floating-orb position (screen fraction). Called
  /// by the orb widget on first build; a missing or corrupt value leaves
  /// the default position in place.
  Future<void> loadOrbPosition() async {
    try {
      final prefs = await _prefs();
      final x = prefs.getDouble(_kOrbXKey);
      final y = prefs.getDouble(_kOrbYKey);
      if (x == null || y == null) return;
      if (x < 0 || x > 1 || y < 0 || y > 1) return;
      _orbPositionFraction = ui.Offset(x, y);
      notifyListeners();
    } catch (_) {
      // A missing position is a default position, not a failure.
    }
  }

  /// Remembers the floating-orb position (screen fraction, 0..1) in memory
  /// and in SharedPreferences. Called by the orb widget when a drag ends;
  /// it deliberately does NOT notify — a drag already rebuilds the orb
  /// itself, and every listener rebuilding per drag frame would be waste.
  Future<void> setOrbPosition(ui.Offset fraction) async {
    final clamped = ui.Offset(
      fraction.dx.clamp(0.0, 1.0),
      fraction.dy.clamp(0.0, 1.0),
    );
    _orbPositionFraction = clamped;
    try {
      final prefs = await _prefs();
      await prefs.setDouble(_kOrbXKey, clamped.dx);
      await prefs.setDouble(_kOrbYKey, clamped.dy);
    } catch (_) {
      // Persistence is a convenience; the in-memory position still holds
      // for this session.
    }
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
    final failure = await _connectAndSubscribe();
    if (failure != null) {
      _phase = TogetherPhase.error;
      _error = failure.message;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    _notePeerPresent(clientId, TogetherRole.host.name);
    _publishPresence(joined: true);
    _publishStatusNow();
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
    final failure = await _connectAndSubscribe();
    if (failure != null) {
      _phase = TogetherPhase.error;
      _error = failure.message;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    _armHostSilenceTimer();
    _notePeerPresent(clientId, TogetherRole.guest.name);
    _publishPresence(joined: true);
    // The host answers this presence with a fresh status publish, so the
    // waiting screen learns what the host is doing within a heartbeat.
    _waitingSinceMs = DateTime.now().millisecondsSinceEpoch;
    _armWaitingStaleTimer();
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
    final failure = await _connectAndSubscribe();
    if (failure != null) {
      _phase = TogetherPhase.error;
      _error = failure.message;
      notifyListeners();
      return false;
    }
    await _persistLastRoom();
    _startHeartbeat();
    _notePeerPresent(clientId, TogetherRole.host.name);
    _publishPresence(joined: true);
    _publishStatusNow();
    return true;
  }

  /// Retries whatever [createRoom]/[joinRoom] last attempted.
  Future<bool> retry() async {
    _cancelReconnect();
    if (_lastAction == 'join' && _otp != null) return joinRoom(_otp!);
    return createRoom();
  }

  /// Leaves the room. A host says goodbye first (so the guest's controls
  /// unlock and playback carries on locally) and clears the retained room
  /// state; every member publishes a presence `left` so the other phone's
  /// presence line updates; the last-room snapshot is kept for the rejoin
  /// card.
  Future<void> leaveRoom() async {
    final wasHost = _role == TogetherRole.host;
    final topic = _otp == null ? null : togetherTopicFor(_otp!);
    if (isConnected && topic != null) {
      // Presence first: the other phone learns the room lost a member even
      // if the bye below is lost with it.
      _publish(topic, <String, dynamic>{
        'kind': 'presence',
        'senderId': clientId,
        'role': _role?.name ?? 'guest',
        'joined': false,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      });
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
    _reconnectTimer?.cancel();
    _waitingStaleTimer?.cancel();
    _heartbeatTimer = null;
    _hostSilenceTimer = null;
    _persistTimer = null;
    _reconnectTimer = null;
    _waitingStaleTimer = null;
    _role = null;
    _otp = null;
    _roomState = null;
    _pendingMedia = null;
    _error = null;
    _hostGone = false;
    _chatHasUnread = false;
    _chatPanelOpen = false;
    _roomStatus = TogetherRoomStatus.hostBrowsing;
    _hostClientId = null;
    _presentMembers.clear();
    _reconnecting = false;
    _reconnectAttempt = 0;
    _connectedRelayLabel = null;
    _roundTripMs = null;
    _lastFailure = null;
    _attemptedRelayLabels = const <String>[];
    _waitingStale = false;
    _waitingSinceMs = null;
    _lastPublishedStatus = null;
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
    if (changed) {
      // A new title starts at its own position 0 — never the previous
      // title's. Without this, a host that re-shares a different movie
      // while live publishes the new title at the old title's position
      // and the guest seeks into the wrong place before the first engine
      // tick corrects it. The playing flag is NOT reset: the transport
      // state carries across a title switch and the status line derives
      // from it.
      _pendingMedia = media;
      _lastLocalPositionMs = 0;
      _lastLocalDurationMs = 0;
    }
    if (_role == TogetherRole.host && _phase == TogetherPhase.live) {
      _publishState(force: true);
    } else if (changed) {
      notifyListeners();
    }
    // Picking a title is a status change the guest is waiting on: the room
    // goes from "finding a movie" to "picked a title" right now, not at
    // the next heartbeat.
    if (_role == TogetherRole.host) _maybePublishStatus();
    unawaited(_persistLastRoom());
  }

  /// Host: goes live at [positionMs] and publishes the first retained state.
  /// A rejoining host passes the adopted position (see [rejoinLastRoom]).
  /// [playing] is the engine's actual transport state at the tap (the
  /// player hook passes it); when omitted the last reported tick is used.
  /// Never assume playing: a paused host that publishes `playing: true`
  /// makes the guest play a title the host is not playing.
  void goLive({
    required int positionMs,
    required int durationMs,
    bool? playing,
  }) {
    if (_role != TogetherRole.host || _pendingMedia == null) return;
    _phase = TogetherPhase.live;
    _hostGone = false;
    _lastLocalPositionMs = positionMs;
    _lastLocalDurationMs = durationMs;
    if (playing != null) _lastLocalPlaying = playing;
    _publishState(
      force: true,
      positionMs: positionMs,
      durationMs: durationMs,
      playing: _lastLocalPlaying,
    );
    _maybePublishStatus();
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
    // A play/pause flip is a status change too (playing <-> paused) — the
    // guest's live line follows it without waiting for a heartbeat.
    if (playingFlipped) _maybePublishStatus();
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

  // ---- Room status + presence ----

  /// What the host is doing right now, derived from the phase, the picked
  /// title and the transport. The single source of truth for the status
  /// the host publishes — and for the status the guest renders.
  TogetherRoomStatus _deriveHostStatus() {
    if (_phase == TogetherPhase.live) {
      return _lastLocalPlaying
          ? TogetherRoomStatus.hostPlaying
          : TogetherRoomStatus.hostPaused;
    }
    if (_pendingMedia != null) return TogetherRoomStatus.hostPickedTitle;
    return TogetherRoomStatus.hostBrowsing;
  }

  /// Host: publishes the current status (non-retained) when it changed.
  /// Called on create, on picking a title, on going live and on play/pause
  /// flips — never on a timer, so the wire stays quiet while nothing
  /// changes and the guest still learns every change within a heartbeat.
  void _maybePublishStatus() {
    if (_role != TogetherRole.host || !isConnected) return;
    final status = _deriveHostStatus();
    if (status == _lastPublishedStatus) return;
    _publishStatus(status);
  }

  /// Host: publishes [status] right now, whatever was published before.
  /// Used on create / rejoin, where the guest is waiting on this exact
  /// message, and when answering a guest's presence `joined`.
  void _publishStatusNow() {
    if (_role != TogetherRole.host || !isConnected) return;
    _publishStatus(_deriveHostStatus());
  }

  void _publishStatus(TogetherRoomStatus status) {
    _roomStatus = status;
    _lastPublishedStatus = status;
    final media = currentMedia;
    _publishToRoom(<String, dynamic>{
      'kind': 'status',
      'status': status.wireValue,
      if (media != null) 'media': media.toJson(),
      'senderId': clientId,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Records [senderId] as present in [role] and clears the waiting-stale
  /// flag when the traffic is from the host. Notifies only when a member
  /// is actually new — heartbeats call this every 2 s and must not
  /// rebuild the room on every beat.
  void _notePeerPresent(String senderId, String role) {
    final isNew = _presentMembers[senderId] != role;
    _presentMembers[senderId] = role;
    if (role == TogetherRole.host.name) {
      _hostClientId = senderId;
      _clearWaitingStale();
    }
    if (isNew) notifyListeners();
  }

  /// Publishes this phone's presence (`joined: true` on entering the room).
  /// Non-retained: presence is a moment, not a state a late joiner needs.
  void _publishPresence({required bool joined}) {
    final role = _role;
    if (role == null) return;
    _publishToRoom(<String, dynamic>{
      'kind': 'presence',
      'senderId': clientId,
      'role': role.name,
      'joined': joined,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _clearWaitingStale() {
    if (!_waitingStale) return;
    _waitingStale = false;
    notifyListeners();
  }

  /// Arms the waiting-guest stale timer: 30 s after joining with no sign
  /// of the host, the waiting screen stops spinning and says so.
  void _armWaitingStaleTimer() {
    if (_role != TogetherRole.guest) return;
    _waitingStaleTimer?.cancel();
    _waitingStaleTimer = Timer(kTogetherWaitingStaleTimeout, () {
      if (_disposed || _role != TogetherRole.guest) return;
      if (_phase != TogetherPhase.waitingGuest) return;
      if (_waitingStale) return;
      _waitingStale = true;
      notifyListeners();
    });
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

  /// Tries the relays in [kTogetherRelays] order and subscribes to the
  /// room topic on the first one that answers. Returns null on success,
  /// or the classified failure (which relays were tried, what actually
  /// failed) when every relay fails.
  ///
  /// The client construction is the one `mqtt_client` requires for secure
  /// websockets (see its `mqtt_server_client_websocket_secure.dart`
  /// example): a `wss://<host>/mqtt` URL, `useWebSocket = true`, the
  /// `secure` flag left false — it is TCP-only, and setting it together
  /// with `useWebSocket` silently turns the websocket back off, which is
  /// exactly how 2.6.0 failed on every network. One attempt per relay
  /// (`maxConnectionAttempts: 1`): the service does its own failover, so
  /// a dead relay must not burn three internal retries first. Each
  /// attempt is bounded by [kTogetherConnectTimeoutMs] (TCP + TLS +
  /// websocket upgrade) plus [kTogetherConnAckWaitMs] for the CONNACK, so
  /// the whole failover finishes in seconds, not minutes.
  ///
  /// No connectivity pre-check: the real connection attempt *is* the
  /// check. A pre-check (DNS probe, `connectivity_plus`) can fail while
  /// MQTT would have worked, and can pass while the relay is down — so
  /// nothing here judges the network before trying the relay, and the
  /// failure is classified from the actual exception afterwards.
  Future<TogetherConnectFailure?> _connectAndSubscribe() async {
    final otp = _otp;
    if (otp == null) {
      return const TogetherConnectFailure(
        kind: TogetherConnectFailureKind.relayUnreachable,
        triedRelays: <String>[],
      );
    }
    _connecting = true;
    final attempted = <String>[];
    TogetherConnectFailureKind? worstKind;
    String? worstDetail;
    try {
      for (final relay in kTogetherRelays) {
        attempted.add(relay.label);
        _attemptedRelayLabels = List.unmodifiable(attempted);
        final client = MqttServerClient(
          relay.url,
          clientId,
          maxConnectionAttempts: 1,
        );
        client.useWebSocket = true;
        client.port = relay.port;
        // NEVER client.secure here: secure is for raw TCP MQTT only.
        // The wss:// scheme in [relay.url] is what makes this a secure
        // websocket; setting secure as well disables the websocket.
        client.websocketProtocols =
            MqttClientConstants.protocolsSingleDefault;
        client.keepAlivePeriod = 20;
        client.logging(on: false);
        client.onConnected = _onConnected;
        client.onDisconnected = _onDisconnected;
        client.connectionTimeout = kTogetherConnectTimeoutMs;
        client.connectTimeoutPeriod = kTogetherConnAckWaitMs;
        client.connectionMessage = MqttConnectMessage()
            .withClientIdentifier(clientId)
            .startClean();
        try {
          await client.connect();
        } catch (e) {
          // Classify, remember, move on to the next relay: one dead
          // relay must not hide the error, and must not end the attempt.
          final kind = mapConnectError(e);
          // A timeout outranks a refused connection as the "worst"
          // failure to report when every relay fails: it is the most
          // informative about a blocked/slow network path.
          if (worstKind == null ||
              (worstKind != TogetherConnectFailureKind.relayTimeout &&
                  kind == TogetherConnectFailureKind.relayTimeout)) {
            worstKind = kind;
            worstDetail = e.toString();
          }
          if (kDebugMode) {
            debugPrint('Together: ${relay.label} failed: $e');
          }
          try {
            client.disconnect();
          } catch (_) {}
          continue;
        }
        if (client.connectionStatus?.state != MqttConnectionState.connected) {
          worstKind ??= TogetherConnectFailureKind.relayUnreachable;
          worstDetail ??= 'broker did not confirm the connection';
          try {
            client.disconnect();
          } catch (_) {}
          continue;
        }
        _client = client;
        _connectedRelayLabel = relay.label;
        _lastFailure = null;
        final topic = togetherTopicFor(otp);
        client.subscribe(topic, MqttQos.atLeastOnce);
        unawaited(_updatesSub?.cancel());
        _updatesSub = client.updates?.listen(_onMessages);
        return null;
      }
      final failure = TogetherConnectFailure(
        kind: worstKind ?? TogetherConnectFailureKind.relayUnreachable,
        triedRelays: List.unmodifiable(attempted),
        detail: worstDetail,
      );
      _lastFailure = failure;
      return failure;
    } finally {
      _connecting = false;
    }
  }

  void _onConnected() {
    if (kDebugMode) debugPrint('Together: relay connected');
  }

  void _onDisconnected() {
    if (_disposed) return;
    if (kDebugMode) debugPrint('Together: relay disconnected');
    // A disconnect from a client that never connected, or one we asked to
    // disconnect, is not a dropped room.
    if (_connecting || _intentionalDisconnect) {
      _intentionalDisconnect = false;
      return;
    }
    if (!isSessionActive || _phase == TogetherPhase.error) return;
    // A dropped relay mid-room is retried in the background with backoff
    // (1 s, 2 s, 4 s, 8 s, 15 s) instead of failing the room at once: a
    // brief network blip must not end a watch party. The room's local
    // state is kept throughout, so a reconnect resumes the same room.
    // Only when every attempt fails does the room report the relay
    // unreachable.
    _scheduleReconnect();
  }

  /// Starts (or restarts) the reconnect loop after a mid-room relay drop.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _reconnecting = true;
    _connectedRelayLabel = null;
    _roundTripMs = null;
    notifyListeners();
    _attemptReconnect();
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = false;
    _reconnectAttempt = 0;
  }

  void _attemptReconnect() {
    if (_disposed || !isSessionActive || _intentionalDisconnect) {
      _reconnecting = false;
      return;
    }
    final delay = togetherReconnectDelay(_reconnectAttempt);
    _reconnectTimer = Timer(delay, () async {
      if (_disposed || !isSessionActive) return;
      final failure = await _connectAndSubscribe();
      if (failure == null) {
        _reconnecting = false;
        _reconnectAttempt = 0;
        _error = null;
        _onReconnected();
        notifyListeners();
        return;
      }
      _reconnectAttempt += 1;
      if (_reconnectAttempt >= kTogetherMaxReconnectAttempts) {
        _reconnecting = false;
        _phase = TogetherPhase.error;
        // The classified failure, not a generic line: it names the
        // relays tried and what actually failed.
        _error = failure.message;
        notifyListeners();
        return;
      }
      notifyListeners();
      _attemptReconnect();
    });
  }

  /// Re-asserts this phone in the room after a reconnect: presence,
  /// status, and — for a live host — the retained playback state, so a
  /// peer that kept watching gets the room back instead of a stale one.
  /// The retained state also re-arrives on subscribe, so a guest that was
  /// live resyncs to the host's live position automatically.
  void _onReconnected() {
    _notePeerPresent(clientId, _role?.name ?? 'guest');
    _publishPresence(joined: true);
    if (_role == TogetherRole.host) {
      _publishStatusNow();
      if (_phase == TogetherPhase.live) _publishState(force: true);
    }
    if (_role == TogetherRole.guest) _armHostSilenceTimer();
  }

  void _disconnect() {
    _cancelReconnect();
    _intentionalDisconnect = true;
    _connectedRelayLabel = null;
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
    // Own heartbeat, echoed back by the broker (we subscribe to our own
    // topic): its `timestampMs` is when we sent it, so the gap is the
    // real MQTT round-trip. Measured every heartbeat (2 s), never guessed.
    if (senderId == clientId && kind == 'heartbeat') {
      final sentMs = (json['timestampMs'] as num?)?.toInt();
      if (sentMs != null) {
        final rtt = DateTime.now().millisecondsSinceEpoch - sentMs;
        if (rtt >= 0 && rtt < 30000) _noteRoundTrip(rtt);
      }
      return;
    }
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
      case 'status':
        _handleStatus(json);
      case 'presence':
        _handlePresence(json);
    }
  }

  /// Records a measured round-trip. Notifies only on the first
  /// measurement or a change of 100 ms or more — heartbeats arrive every
  /// 2 s and must not rebuild the room on every beat for a few ms of jitter.
  void _noteRoundTrip(int rttMs) {
    final previous = _roundTripMs;
    _roundTripMs = rttMs;
    if (previous == null || (rttMs - previous).abs() >= 100) {
      notifyListeners();
    }
  }

  /// A live room-status push from the host. The guest renders it directly:
  /// this is the waiting screen's "Host is still finding a movie…" /
  /// "Host picked X" line, and the live screen's playing/paused line.
  void _handleStatus(Map<String, dynamic> json) {
    TogetherRoomStatusMessage message;
    try {
      message = TogetherRoomStatusMessage.fromJson(json);
    } catch (_) {
      return;
    }
    if (message.senderId.isEmpty) return;
    _notePeerPresent(message.senderId, TogetherRole.host.name);
    _roomStatus = message.status;
    if (message.media != null) {
      // The host is the source of truth about the title while the guest is
      // still waiting; once live, the retained state owns the title.
      if (_phase == TogetherPhase.waitingGuest) {
        _pendingMedia = message.media;
      } else {
        _pendingMedia ??= message.media;
      }
    }
    _armHostSilenceTimer();
    notifyListeners();
  }

  /// A presence event from the other phone.
  void _handlePresence(Map<String, dynamic> json) {
    TogetherPresenceEvent event;
    try {
      event = TogetherPresenceEvent.fromJson(json);
    } catch (_) {
      return;
    }
    if (event.senderId.isEmpty || event.senderId == clientId) return;
    if (event.joined) {
      _notePeerPresent(event.senderId, event.role);
      // A guest just joined: answer with a fresh status publish so the
      // guest learns what the host is doing right now instead of waiting
      // for the next heartbeat or status change.
      if (_role == TogetherRole.host && event.role == TogetherRole.guest.name) {
        _publishStatusNow();
      }
    } else {
      _presentMembers.remove(event.senderId);
      // A host that leaves without a `bye` (crashed app, killed network)
      // still ends the shared session for the guest.
      if (event.role == TogetherRole.host.name &&
          _role == TogetherRole.guest) {
        _hostGone = true;
        _hostSilenceTimer?.cancel();
      }
    }
    _armHostSilenceTimer();
    notifyListeners();
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
    _notePeerPresent(state.hostId, TogetherRole.host.name);
    // The retained state is itself a status fact: a guest that missed the
    // status push still learns playing/paused from it.
    _roomStatus = state.playing
        ? TogetherRoomStatus.hostPlaying
        : TogetherRoomStatus.hostPaused;
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
    // A heartbeat is presence too: if the guest's `joined` was lost, the
    // host still learns the guest is in the room within 2 s.
    if (_role == TogetherRole.host) {
      _notePeerPresent(senderId, TogetherRole.guest.name);
    }
    // A rejoining host adopts the room's current position from the first
    // heartbeat that proves someone is further along — then re-asserts
    // host authority at that position.
    if (_role == TogetherRole.host && _adoptingRejoin) {
      _adoptRejoinFromHeartbeats();
    }
    // Any traffic from the host proves it is still there.
    if (_role == TogetherRole.guest) {
      _notePeerPresent(senderId, TogetherRole.host.name);
      // The host's heartbeat repeats its current status (and picked title)
      // so a guest that missed the status push still learns it within 2 s.
      final status = TogetherRoomStatus.fromWire(json['status'] as String?);
      if (status != null && status != _roomStatus) {
        _roomStatus = status;
        notifyListeners();
      }
      if (json['media'] is Map && _phase == TogetherPhase.waitingGuest) {
        try {
          _pendingMedia = TogetherMediaIdentity.fromJson(
            Map<String, dynamic>.from(json['media'] as Map),
          );
        } catch (_) {
          // A malformed media block in a heartbeat is not a room failure.
        }
      }
      _armHostSilenceTimer();
    }
  }

  void _handleBye(Map<String, dynamic> json) {
    final senderId = json['senderId'] as String?;
    // Only the host leaving ends the shared session. A guest leaving
    // changes nothing for the host. The host is recognised by the id
    // learned from state / status / presence — not only by the retained
    // state, which a still-waiting guest may never have received.
    if (senderId == null ||
        (senderId != _hostClientId && senderId != _roomState?.hostId)) {
      return;
    }
    _presentMembers.remove(senderId);
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
      // The host's heartbeat repeats its current status (and picked title):
      // it is the backstop that keeps a guest's waiting screen live even
      // when a status push is lost. A guest heartbeat carries position only.
      final isHost = _role == TogetherRole.host;
      final media = isHost ? currentMedia : null;
      _publishToRoom(<String, dynamic>{
        'kind': 'heartbeat',
        'senderId': clientId,
        'positionMs': _lastLocalPositionMs,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
        if (isHost) 'status': _deriveHostStatus().wireValue,
        if (media != null) 'media': media.toJson(),
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
    _reconnectTimer?.cancel();
    _waitingStaleTimer?.cancel();
    _disconnect();
    super.dispose();
  }
}
