import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:typed_data/typed_data.dart';

import 'chat_image_chunks.dart';
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

/// What the Together Start button is doing right now — the single decision
/// point for every Start surface (the floating orb, the player hook, the
/// Together tab). Decided here, in the service, from room facts only, so
/// the orb, the hook and the tab can never disagree.
///
/// * [hidden] — no room: nothing Start-related renders at all.
/// * [browsing] — a room is open but the host is not in a position to go
///   live: still browsing/searching, no title picked, no player open, or
///   the movie is paused/stopped. The orb is just its small neutral pill
///   ("Enjoy Together") — never a start prompt.
/// * [ready] — the host has picked a title, a player is open, and the
///   movie is actually playing. Only now does the compact Start run
///   button appear.
/// * [live] — the room is live AND the shared title is actually playing
///   in an open player right now (see [TogetherService.isShowingLive]):
///   the Start button is gone for good, the floating orb hides entirely,
///   and the Live status lives only in the player control panel. A live
///   room whose playback is paused, whose player is closed, or whose host
///   has left is `browsing` here, not `live` — the phase stays live (the
///   session survives a pause), but nothing on screen claims it is live.
enum TogetherStartState { hidden, browsing, ready, live }

/// Health of a live Together session, for the Live indicator in the
/// player control panel (see [TogetherService.liveHealth]).
///
/// Green ([healthy]) while the relay round-trip, the guest's drift from
/// the host's clock and the heartbeat are all inside their budgets;
/// orange ([degraded]) the moment any one of them is not. The indicator
/// renders nothing at all when the session is not showing live — health
/// is only ever read alongside [TogetherService.isShowingLive].
enum TogetherLiveHealth { healthy, degraded }

/// What sending a chat photo can end in. The chat panel turns each one
/// into an honest line — never a silent drop, never a generic failure.
enum TogetherImageSendResult {
  /// The photo fit (after shrinking, if it needed it) and its chunks are
  /// on the wire.
  sent,

  /// No room, or the relay is not connected right now.
  notConnected,

  /// The bytes are not a readable JPEG / PNG / WebP / GIF.
  unreadable,

  /// Even after downscaling to the smallest step the photo is still over
  /// the 5 MB budget. (An animated GIF over budget lands here too: the
  /// only way to shrink it would destroy the animation.)
  tooLarge,
}

/// Maximum chat image size: 5 MB of raw bytes (2.8.0 — was ~120 KB),
/// defined in `chat_image_chunks.dart` as [kTogetherMaxChatImageBytes].
/// A photo travels chunked (see that file): the relay cannot carry a
/// 5 MB message in one packet, so the bytes are split into 32 KiB chunks
/// with a SHA-256 integrity check on reassembly. A photo over the budget
/// is downscaled on-device until it fits; only one that still cannot fit
/// is refused.

/// How often every member reports its own position (heartbeat), and how
/// long a host may go quiet before the guest decides it has left.
///
/// 1 s while a room is open (2.8.0 — was 2 s): the heartbeat is the
/// backstop that keeps the guest's waiting screen, presence and RTT
/// measurement live, and a 1 s beat means a lost status push is repaired
/// within a second. It never carries playback itself — play/pause/seek/
/// title changes publish their own state immediately (see
/// [reportLocalPlayback]), so the heartbeat staying cheap matters more
/// than its exact rate.
const Duration kTogetherHeartbeatInterval = Duration(seconds: 1);
const Duration kTogetherHostSilenceTimeout = Duration(seconds: 8);

/// How long a waiting guest gives the host to show any sign of life
/// (status, heartbeat, presence or retained state) after joining before
/// the waiting screen says so instead of spinning forever. The host
/// publishes a status the moment the room is created and a heartbeat every
/// 1 s, so 30 s of total silence genuinely means the relay or the host is
/// gone — not that the host is browsing slowly.
const Duration kTogetherWaitingStaleTimeout = Duration(seconds: 30);

/// Live-indicator health budgets (2.10.0, Bug 1). The player control
/// panel shows a blinking green Live dot while every signal is inside
/// budget, and turns it orange the moment any one of them is not:
///
/// * [kTogetherLiveDegradedRttMs] — measured MQTT round-trip over
///   800 ms: the relay is slow enough that a host action takes most of
///   a second to reach the other phone.
/// * [kTogetherLiveDegradedDriftMs] — a guest further than 750 ms from
///   where the host's clock says it should be: the same threshold at
///   which sync stops nudging the rate and seeks instead
///   ([kSyncSeekThresholdMs]), so "orange" and "about to jump" agree.
/// * [kTogetherLiveHeartbeatStaleMs] — a guest that has heard no host
///   heartbeat for 3 s (three missed 1 s beats): the host may still be
///   there, but nothing has proved it recently. Only applies once a host
///   heartbeat has been seen at all — a room with no heartbeat yet is
///   not degraded for having none.
const int kTogetherLiveDegradedRttMs = 800;
const int kTogetherLiveDegradedDriftMs = kSyncSeekThresholdMs;
const int kTogetherLiveHeartbeatStaleMs = 3000;

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
/// changes. Heartbeats deliberately do NOT notify — they arrive every
/// second and nothing on screen needs them, except the rejoin-adoption
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

  /// Chunked images arriving from the other phone, by message id — the
  /// reassembly state for each photo still missing chunks.
  final Map<String, _IncomingImageTransfer> _incomingImages =
      <String, _IncomingImageTransfer>{};

  /// Chunked images this phone sent and the peer has not acked yet, by
  /// message id — the chunk list is kept so a retry request for missing
  /// indices can re-publish just those chunks. Entries expire after
  /// 2 minutes ([_pruneSentImages]).
  final Map<String, _SentImageTransfer> _sentImages =
      <String, _SentImageTransfer>{};

  /// Outgoing image transfers still being published, by message id, for
  /// the sending-progress UI.
  final Map<String, TogetherImageTransfer> _outgoingTransfers =
      <String, TogetherImageTransfer>{};

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
    // The player closed: the movie is not playing anywhere any more, so
    // the ready state must not survive on a stale tick. It comes back
    // only when a player re-opens and reports playing again (see
    // [reportLocalPlayback]) — that is what makes the Start button vanish
    // when the host leaves the player without going live.
    if (action == null) _lastLocalPlaying = false;
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

  /// Image transfers in flight right now — outgoing photos still being
  /// published and incoming photos still missing chunks — for the chat
  /// panel's progress rows. A transfer leaves this list the moment it
  /// completes (the photo is a normal chat message by then) or fails.
  List<TogetherImageTransfer> get imageTransfers {
    return List.unmodifiable(<TogetherImageTransfer>[
      ..._outgoingTransfers.values,
      for (final transfer in _incomingImages.values)
        TogetherImageTransfer(
          messageId: transfer.reassembler.messageId,
          isOutgoing: false,
          receivedChunks: transfer.reassembler.receivedCount,
          totalChunks: transfer.reassembler.totalChunks,
        ),
    ]);
  }

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
  ///
  /// This is the *session* fact, and it is deliberately sticky: pausing,
  /// closing the player or losing the host does not end the session — the
  /// room survives all three, and the guest keeps its last synced state.
  /// Nothing on screen may read this as "show a Live pill": that is
  /// [isShowingLive], which is the only live fact the UI renders.
  bool get isLive => _phase == TogetherPhase.live;

  /// True only while a Live indicator may be shown anywhere — the one
  /// condition the player control panel and the floating orb both read.
  ///
  /// 2.10.0, Bug 1 (the stale "Live" pill on home): `isLive` used to be
  /// the indicator condition, and it is sticky — the phase flips to
  /// `live` on Start and nothing flips it back except [leaveRoom], so a
  /// pill mounted above the router (see `main.dart`) kept saying "Live"
  /// on the home screen, the details screen and in the player long after
  /// the user had left the player, paused, or lost the host. The phase
  /// is the session; this getter is the *playback* fact, and it requires
  /// all of these at once:
  ///
  /// * the phase is live (a session exists and went live);
  /// * the host has not left ([hostGone] — a `bye`, a presence `left`,
  ///   or 8 s of host silence);
  /// * a player is open ([isPlayerOpen] — the hook registers its action
  ///   on attach and clears it on dispose, so leaving the player clears
  ///   this the moment the route pops);
  /// * the shared title is actually playing ([isLocallyPlaying] — the
  ///   hook clears it with the player, and a pause clears it at once);
  /// * the room knows what title it is about ([currentMedia]).
  ///
  /// The moment any one of those stops holding, the indicator vanishes
  /// — no stale pill on home, details, search or anywhere else — while
  /// the session itself survives: resume playback (or re-open the
  /// player on the same title) and the indicator comes back, with no
  /// second Start tap.
  bool get isShowingLive =>
      _phase == TogetherPhase.live &&
      !_hostGone &&
      _orbStartAction != null &&
      _lastLocalPlaying &&
      currentMedia != null;

  /// How far this phone's engine is from where the host's clock says it
  /// should be, in milliseconds — the guest's sync error, straight off
  /// the latest host state. The host is the clock, so its drift is 0 by
  /// definition; a guest with no host state yet has no drift to measure
  /// (null, not a guess). Read by [liveHealth]: over
  /// [kTogetherLiveDegradedDriftMs] the Live dot turns orange.
  int? get liveDriftMs {
    if (_phase != TogetherPhase.live) return null;
    if (_role == TogetherRole.host) return 0;
    final state = _roomState;
    if (state == null) return null;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return (state.targetPositionMs(nowMs: nowMs) - _lastLocalPositionMs)
        .abs();
  }

  /// Health of the live session for the player control panel's Live dot:
  /// green ([TogetherLiveHealth.healthy]) while the relay round-trip,
  /// the guest's drift and the host heartbeat are all inside budget,
  /// orange ([TogetherLiveHealth.degraded]) the moment any one is not —
  /// reconnecting to the relay, a measured round-trip over
  /// [kTogetherLiveDegradedRttMs], drift over
  /// [kTogetherLiveDegradedDriftMs], or (guest only, once a host
  /// heartbeat has been seen) no host heartbeat for
  /// [kTogetherLiveHeartbeatStaleMs]. No signal yet is not a failure:
  /// a null round-trip or an unseen heartbeat reads healthy until a
  /// measurement says otherwise.
  TogetherLiveHealth get liveHealth {
    if (_reconnecting) return TogetherLiveHealth.degraded;
    final rtt = _roundTripMs;
    if (rtt != null && rtt > kTogetherLiveDegradedRttMs) {
      return TogetherLiveHealth.degraded;
    }
    final drift = liveDriftMs;
    if (drift != null && drift > kTogetherLiveDegradedDriftMs) {
      return TogetherLiveHealth.degraded;
    }
    if (_role == TogetherRole.guest && _hostClientId != null) {
      final heartbeat = _peerHeartbeats[_hostClientId];
      if (heartbeat != null &&
          DateTime.now().millisecondsSinceEpoch - heartbeat.receivedAtMs >
              kTogetherLiveHeartbeatStaleMs) {
        return TogetherLiveHealth.degraded;
      }
    }
    return TogetherLiveHealth.healthy;
  }

  /// The engine's actual transport state at the last reported tick: true
  /// only while the movie is really playing in an open player. Cleared
  /// when the player closes ([registerOrbStartAction]) and when the room
  /// is reset, so a stale tick can never conjure a Start button.
  bool get isLocallyPlaying => _lastLocalPlaying;

  /// True while a player is open — i.e. the player hook has registered
  /// its `goLive` on the service. Without a player there is no engine to
  /// go live from, so there is no Start button either.
  bool get isPlayerOpen => _orbStartAction != null;

  /// The Start-button state machine ([TogetherStartState]): the one place
  /// the decision is made. Browsing shows only the neutral orb pill;
  /// `ready` needs all four at once — host, pending room, a picked title,
  /// an open player, and the movie actually playing; `live` needs the
  /// room live AND the shared title playing in an open player right now
  /// ([isShowingLive]) — never the phase alone, which outlives the
  /// player, the pause and the host (see [isShowingLive]). A live room
  /// that is paused, player-less or host-less falls back to `browsing`:
  /// the neutral pill returns, Start stays gone, and the session itself
  /// is untouched — resume and it is live again.
  TogetherStartState get startState {
    if (!isSessionActive) return TogetherStartState.hidden;
    if (isShowingLive) return TogetherStartState.live;
    if (_role == TogetherRole.host &&
        _phase == TogetherPhase.pendingHost &&
        _pendingMedia != null &&
        _orbStartAction != null &&
        _lastLocalPlaying) {
      return TogetherStartState.ready;
    }
    return TogetherStartState.browsing;
  }

  /// True only in [TogetherStartState.ready]: the compact Start run
  /// button may render. Every Start surface reads this, never its own
  /// copy of the conditions.
  bool get showStartButton => startState == TogetherStartState.ready;

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

  /// Test-only transport tap: when set, every JSON publish that would go
  /// to the room topic is also handed to this sink ([_publishToRoom]),
  /// and [_canPublish] is true even with no live relay — so tests can
  /// verify exactly what the host publishes (state on seek/pause, chunk
  /// sequences, retry requests) without a broker. Never set in
  /// production; production publishing is unchanged (sink null means
  /// "connected to the relay" is the only way to publish).
  @visibleForTesting
  void Function(Map<String, dynamic> json, {bool retain})?
  debugPublishSinkForTest;

  /// True when a publish can actually leave this phone: connected to the
  /// relay, or (tests only) the debug sink is attached.
  bool get _canPublish => isConnected || debugPublishSinkForTest != null;

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

  /// Sets the last measured round-trip directly, as if a heartbeat echo
  /// had just measured it. Test-only — production sets it from the echo
  /// in [_handlePayload]. Lets tests pin the Live health rule
  /// ([liveHealth]) at and above [kTogetherLiveDegradedRttMs] without a
  /// broker.
  @visibleForTesting
  void debugSetRoundTripMsForTest(int? rttMs) {
    _roundTripMs = rttMs;
    notifyListeners();
  }

  /// Sets the reconnecting flag directly. Test-only — production sets it
  /// in [_startReconnect]/[_cancelReconnect]. Lets tests pin the Live
  /// health rule ([liveHealth]) while the relay is being retried.
  @visibleForTesting
  void debugSetReconnectingForTest(bool reconnecting) {
    _reconnecting = reconnecting;
    notifyListeners();
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
    // A fresh room starts with nothing playing: a stale tick from the
    // previous room must never make a Start button appear before the new
    // movie actually plays.
    _lastLocalPlaying = false;
    _chatHasUnread = false;
    _chatPanelOpen = false;
    _roomStatus = TogetherRoomStatus.hostBrowsing;
    _hostClientId = null;
    _presentMembers.clear();
    for (final transfer in _incomingImages.values) {
      transfer.retryTimer?.cancel();
    }
    _incomingImages.clear();
    _sentImages.clear();
    _outgoingTransfers.clear();
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

  /// Called by the player hook on every engine tick. The host publishes
  /// IMMEDIATELY on every action — a play/pause flip, a seek, a title
  /// change (see [attachMedia]) — never waiting for the next heartbeat:
  /// the guest's mirror of a host action is one relay round-trip away,
  /// not a heartbeat away. Between actions, a playing host re-publishes
  /// at most once a second as a steady-state tick; a paused host with no
  /// change publishes nothing at all. A guest only records its own
  /// position for the rejoin snapshot.
  void reportLocalPlayback({
    required int positionMs,
    required int durationMs,
    required bool playing,
  }) {
    // A seek is a position jump the clock cannot explain: backwards at
    // all, any move while paused (nothing advances a paused clock), or a
    // forward jump bigger than one engine tick could produce at normal
    // speed (ticks arrive ~4×/s, so ~250 ms per tick at 1×; 1000 ms of
    // slack covers 2× speed and a missed tick without mistaking normal
    // playback for a seek).
    final deltaMs = positionMs - _lastLocalPositionMs;
    final isSeek = !playing
        ? deltaMs != 0
        : deltaMs < 0 || deltaMs > 1000;
    _lastLocalPositionMs = positionMs;
    _lastLocalDurationMs = durationMs;
    final playingFlipped = playing != _lastLocalPlaying;
    _lastLocalPlaying = playing;
    // A play/pause flip is a UI-visible state change in every phase, so
    // the listeners rebuild for it — never silently:
    // * pending host: the Start button appearing / vanishing;
    // * live host or guest: the Live indicator appearing / vanishing
    //   ([isShowingLive] requires playback actually playing, 2.10.0
    //   Bug 1 — without this notify the orb and the player control panel
    //   would keep showing Live after a pause, because the publish path
    //   below does not notify). A flip is a rare user action, never a
    //   per-tick event, so this costs no rebuild storm.
    if (playingFlipped) {
      notifyListeners();
    }
    if (_role != TogetherRole.host || _phase != TogetherPhase.live) return;
    if (!_canPublish) return;
    final now = DateTime.now();
    final due =
        _lastPublishedAt == null ||
        now.difference(_lastPublishedAt!).inMilliseconds >= 1000;
    if (playingFlipped || isSeek || (playing && due)) {
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
    if (media == null || topic == null || !_canPublish) return;
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
    if (_role != TogetherRole.host || !_canPublish) return;
    final status = _deriveHostStatus();
    if (status == _lastPublishedStatus) return;
    _publishStatus(status);
  }

  /// Host: publishes [status] right now, whatever was published before.
  /// Used on create / rejoin, where the guest is waiting on this exact
  /// message, and when answering a guest's presence `joined`.
  void _publishStatusNow() {
    if (_role != TogetherRole.host || !_canPublish) return;
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
  /// is actually new — heartbeats call this every 1 s and must not
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

  /// Sends a photo from the gallery/camera roll — up to 5 MB (2.8.0,
  /// was ~120 KB), JPEG / PNG / WebP / GIF.
  ///
  /// * A photo within budget is sent exactly as picked: no quality loss,
  ///   and a GIF keeps its animation.
  /// * A photo over budget is downscaled on-device (stepwise, re-encoded
  ///   as PNG) until it fits; only one that still cannot fit is refused
  ///   ([TogetherImageSendResult.tooLarge]). An animated GIF over budget
  ///   is refused rather than silently flattened to a still — the only
  ///   way to shrink it would destroy the animation.
  /// * The bytes travel CHUNKED (see `chat_image_chunks.dart`): 32 KiB
  ///   pieces with a SHA-256 integrity check, so the public relay never
  ///   sees a 5 MB packet. The sender's bubble appears at once (local
  ///   echo) with a sending-progress row while the chunks go out; the
  ///   receiver reassembles, verifies, and only then shows the photo.
  Future<TogetherImageSendResult> sendChatImage(
    Uint8List bytes, {
    String? replyToId,
    String? replyToText,
  }) async {
    if (!isSessionActive || !_canPublish) {
      return TogetherImageSendResult.notConnected;
    }
    if (bytes.isEmpty) return TogetherImageSendResult.unreadable;
    final fitted = await _fitImageToBudget(bytes);
    if (fitted == null) {
      // Not an image at all vs. a real image that would not shrink
      // enough: the panel tells the user which one it was.
      return detectImageFormat(bytes) == TogetherImageFormat.unknown
          ? TogetherImageSendResult.unreadable
          : TogetherImageSendResult.tooLarge;
    }
    final message = _buildMessage(
      imageBase64: base64Encode(fitted),
      replyToId: replyToId,
      replyToText: replyToText,
    );
    _messages.add(message);
    notifyListeners();
    await _publishImageChunks(message: message, bytes: fitted);
    return TogetherImageSendResult.sent;
  }

  /// Publishes [bytes] as a chunked image message, keeping the chunk list
  /// so a retry request from the peer can re-publish just the missing
  /// pieces. Progress is exposed through [imageTransfers] while sending.
  Future<void> _publishImageChunks({
    required TogetherChatMessage message,
    required Uint8List bytes,
  }) async {
    final chunks = splitImageIntoChunks(
      bytes: bytes,
      messageId: message.id,
      senderId: clientId,
      timestampMs: message.timestampMs,
      replyToId: message.replyToId,
      replyToText: message.replyToText,
    );
    if (chunks.isEmpty) return;
    _pruneSentImages();
    _sentImages[message.id] = _SentImageTransfer(
      messageId: message.id,
      chunks: chunks,
      sentAt: DateTime.now(),
    );
    _outgoingTransfers[message.id] = TogetherImageTransfer(
      messageId: message.id,
      isOutgoing: true,
      receivedChunks: 0,
      totalChunks: chunks.length,
    );
    notifyListeners();
    for (var i = 0; i < chunks.length; i++) {
      _publishToRoom(chunks[i].toJson());
      // Progress, throttled to 5% steps: a 5 MB photo is ~160 chunks,
      // and the chat must not rebuild 160 times for one send.
      final progress = (i + 1) / chunks.length;
      final shown = _outgoingTransfers[message.id];
      if (shown != null &&
          (progress - shown.progress >= 0.05 || i == chunks.length - 1)) {
        _outgoingTransfers[message.id] = TogetherImageTransfer(
          messageId: message.id,
          isOutgoing: true,
          receivedChunks: i + 1,
          totalChunks: chunks.length,
        );
        notifyListeners();
      }
      // Pace chunk publishes: the public relay drops rapid bursts (see
      // [kTogetherChatChunkPublishGap]) — a 1 MB photo takes ~8 s to send
      // with progress shown, instead of arriving with holes. Skipped for
      // the test sink, which is not a real broker, so unit tests stay fast.
      if (i < chunks.length - 1 && debugPublishSinkForTest == null) {
        await Future<void>.delayed(kTogetherChatChunkPublishGap);
      }
    }
    _outgoingTransfers.remove(message.id);
    notifyListeners();
    // The retained chunk list lives until the peer acks (or 2 minutes
    // pass): a retry request that arrives after the send finished still
    // gets its missing chunks.
  }

  /// Fits [bytes] to the 5 MB budget: within budget and a known format,
  /// the original bytes go untouched; over budget, decode and shrink
  /// stepwise (PNG re-encode) until it fits; null when it cannot be read
  /// as an image at all, or still will not fit at the smallest step.
  Future<Uint8List?> _fitImageToBudget(Uint8List bytes) async {
    final format = detectImageFormat(bytes);
    if (bytes.length <= kTogetherMaxChatImageBytes) {
      if (format != TogetherImageFormat.unknown) return bytes;
      // Small but unrecognised: it may still be a decodable image (e.g.
      // BMP) — fall through to the decode path, which re-encodes as PNG.
    } else if (format == TogetherImageFormat.gif) {
      // Animated GIF over budget: shrinking would flatten it to a still.
      return null;
    }
    // Over budget (or an unknown-but-decodable format): each step roughly
    // quarters the pixel count, so photographic images land well under
    // budget long before the smallest step. PNG is the only compressed
    // re-encode dart:ui offers.
    for (final longSide in const <int>[2048, 1600, 1280, 1024, 800, 640, 480]) {
      final shrunk = await _downscaleImage(bytes, longSide: longSide);
      if (shrunk != null && shrunk.length <= kTogetherMaxChatImageBytes) {
        return shrunk;
      }
    }
    return null;
  }

  /// Drops entries older than 2 minutes from the retained sent-image
  /// store: a peer that slow has long since given up asking.
  void _pruneSentImages() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 120));
    _sentImages.removeWhere((_, sent) => sent.sentAt.isBefore(cutoff));
  }

  /// Downscales [bytes] so its width is at most [longSide] and re-encodes
  /// as PNG. Returns null when the bytes are not a decodable image.
  Future<Uint8List?> _downscaleImage(
    Uint8List bytes, {
    required int longSide,
  }) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: longSide,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
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
    // Test tap: captures the publish even with no live relay (see
    // [debugPublishSinkForTest]). The real publish below still no-ops
    // offline — the sink never replaces the relay. This sits here, not
    // in [_publishToRoom], because the playback state publishes straight
    // through [_publish] and must be captured too.
    debugPublishSinkForTest?.call(json, retain: retain);
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
    // real MQTT round-trip. Measured every heartbeat (1 s), never guessed.
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
      case 'chat-image-chunk':
        _handleImageChunk(json);
      case 'chat-image-request':
        unawaited(_handleImageRequest(json));
      case 'chat-image-ack':
        _handleImageAck(json);
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
  /// measurement or a change of 50 ms or more — heartbeats arrive every
  /// 1 s and must not rebuild the room on every beat for a few ms of jitter.
  void _noteRoundTrip(int rttMs) {
    final previous = _roundTripMs;
    _roundTripMs = rttMs;
    if (previous == null || (rttMs - previous).abs() >= 50) {
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
      // for the next heartbeat or status change — and, when the room is
      // already live, an immediate retained-state publish too, so the
      // guest resyncs to the exact live position at once instead of
      // waiting for the next 1 s state tick.
      if (_role == TogetherRole.host && event.role == TogetherRole.guest.name) {
        _publishStatusNow();
        if (_phase == TogetherPhase.live) _publishState(force: true);
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
    // a play/pause flip, or a SEEK-sized jump — a jump is a host action
    // the guest's hook must apply at once (see TogetherPlayerHook), not at
    // the next throttled evaluation. The position itself ticks once a
    // second and the player hook reads it straight off the service —
    // notifying for it would rebuild the player screen every second for
    // nothing. A jump is measured against where the previous state said
    // the host would be now, so ordinary playback advance (which the
    // target math already accounts for) never counts as a jump.
    final previous = _roomState;
    final mediaChanged = previous?.media != state.media;
    final playingFlipped = previous?.playing != state.playing;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final seekJump =
        previous != null &&
        (state.targetPositionMs(nowMs: nowMs) -
                    previous.targetPositionMs(nowMs: nowMs))
                .abs() >
            kSyncSeekThresholdMs;
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
    if (wasWaiting || mediaChanged || playingFlipped || seekJump) {
      notifyListeners();
    }
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

  // ---- Chunked chat images (receive side) ----

  /// One incoming chunk of a photo. Chunks may arrive out of order and
  /// twice (QoS 1); the reassembler dedupes by index and the photo is
  /// delivered only when every chunk is in AND the SHA-256 matches — a
  /// partial or corrupt transfer is never shown. When the last chunk
  /// arrives with pieces still missing, the missing indices are requested
  /// at once instead of waiting for the retry timer; the timer (5 s after
  /// the last chunk seen) covers the case where the last chunk itself
  /// never arrives.
  void _handleImageChunk(Map<String, dynamic> json) {
    TogetherImageChunk chunk;
    try {
      chunk = TogetherImageChunk.fromJson(json);
    } catch (_) {
      return;
    }
    if (chunk.messageId.isEmpty ||
        chunk.senderId.isEmpty ||
        chunk.senderId == clientId) {
      return;
    }
    if (chunk.totalChunks <= 0 ||
        chunk.totalBytes <= 0 ||
        chunk.totalBytes > kTogetherMaxChatImageBytes ||
        chunk.sha256Hex.isEmpty) {
      return;
    }
    // Already delivered (the sender's retry re-publish racing the ack).
    if (_messages.any((m) => m.id == chunk.messageId)) return;
    var transfer = _incomingImages[chunk.messageId];
    transfer ??= _incomingImages[chunk.messageId] = _IncomingImageTransfer(
      reassembler: TogetherImageReassembler(
        messageId: chunk.messageId,
        totalChunks: chunk.totalChunks,
        totalBytes: chunk.totalBytes,
        sha256Hex: chunk.sha256Hex,
      ),
      senderId: chunk.senderId,
      timestampMs: chunk.timestampMs,
      replyToId: chunk.replyToId,
      replyToText: chunk.replyToText,
    );
    // A chunk that disagrees with the transfer's announced shape is a
    // different send reusing an id — drop it, never mix two photos.
    if (transfer.reassembler.totalChunks != chunk.totalChunks ||
        transfer.reassembler.totalBytes != chunk.totalBytes) {
      return;
    }
    transfer.reassembler.addChunk(chunk);
    _armImageRetryTimer(transfer);
    final assembled = transfer.reassembler.tryAssemble();
    if (assembled != null) {
      _completeIncomingImage(transfer, assembled);
      return;
    }
    // Receiving progress, throttled to 5% steps so a 160-chunk photo
    // does not rebuild the chat panel 160 times.
    final progress =
        transfer.reassembler.receivedCount / transfer.reassembler.totalChunks;
    if (progress - transfer.lastNotifiedProgress >= 0.05) {
      transfer.lastNotifiedProgress = progress;
      notifyListeners();
    }
    if (chunk.chunkIndex == chunk.totalChunks - 1) {
      _requestMissingImageChunks(transfer);
    }
  }

  /// Delivers a fully reassembled, integrity-checked photo as a normal
  /// chat message, and acks it so the sender drops its retained copy.
  void _completeIncomingImage(
    _IncomingImageTransfer transfer,
    Uint8List bytes,
  ) {
    transfer.retryTimer?.cancel();
    _incomingImages.remove(transfer.reassembler.messageId);
    final message = TogetherChatMessage(
      id: transfer.reassembler.messageId,
      senderId: transfer.senderId,
      senderLabel: 'Friend',
      imageBase64: base64Encode(bytes),
      replyToId: transfer.replyToId,
      replyToText: transfer.replyToText,
      timestampMs: transfer.timestampMs,
    );
    _messages.add(message);
    if (!_chatPanelOpen) _chatHasUnread = true;
    _publishToRoom(<String, dynamic>{
      'kind': 'chat-image-ack',
      'messageId': message.id,
      'senderId': clientId,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
    notifyListeners();
  }

  /// Gives up on a photo after 3 unanswered retry requests (~15–20 s):
  /// the transfer is dropped and the room sees an honest line instead of
  /// a photo that never arrives.
  void _failIncomingImage(_IncomingImageTransfer transfer) {
    transfer.retryTimer?.cancel();
    _incomingImages.remove(transfer.reassembler.messageId);
    _messages.add(
      TogetherChatMessage(
        id: '${transfer.reassembler.messageId}-failed',
        senderId: transfer.senderId,
        senderLabel: 'Friend',
        text: 'Photo couldn’t be received completely — please send it again.',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!_chatPanelOpen) _chatHasUnread = true;
    notifyListeners();
  }

  /// Arms (or re-arms) the 5 s retry timer: 5 s after the last chunk seen
  /// with pieces still missing, ask for them. Re-armed on every chunk,
  /// so a slow-but-moving transfer is never asked twice for the same gap.
  void _armImageRetryTimer(_IncomingImageTransfer transfer) {
    transfer.retryTimer?.cancel();
    transfer.retryTimer = Timer(const Duration(seconds: 5), () {
      if (_disposed) return;
      if (!_incomingImages.containsKey(transfer.reassembler.messageId)) {
        return;
      }
      if (transfer.reassembler.isComplete) return;
      _requestMissingImageChunks(transfer);
      if (_incomingImages.containsKey(transfer.reassembler.messageId)) {
        _armImageRetryTimer(transfer);
      }
    });
  }

  /// Asks the sender to re-publish just the missing indices (at most
  /// 3 requests per transfer — after that [_failIncomingImage] ends it).
  void _requestMissingImageChunks(_IncomingImageTransfer transfer) {
    final missing = transfer.reassembler.missingIndices;
    if (missing.isEmpty) return;
    if (transfer.requestsSent >= 3) {
      _failIncomingImage(transfer);
      return;
    }
    transfer.requestsSent += 1;
    _publishToRoom(<String, dynamic>{
      'kind': 'chat-image-request',
      'messageId': transfer.reassembler.messageId,
      'senderId': clientId,
      'missing': missing,
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// The peer is missing pieces of a photo this phone sent: re-publish
  /// exactly those chunks from the retained copy — never the whole image.
  /// Paced like the initial send ([kTogetherChatChunkPublishGap]): a
  /// burst of re-published chunks hits the same relay burst-loss.
  Future<void> _handleImageRequest(Map<String, dynamic> json) async {
    final messageId = json['messageId'] as String?;
    final senderId = json['senderId'] as String?;
    if (messageId == null ||
        messageId.isEmpty ||
        senderId == null ||
        senderId == clientId) {
      return;
    }
    final sent = _sentImages[messageId];
    if (sent == null) return;
    _pruneSentImages();
    final missing =
        (json['missing'] as List?)
            ?.map((e) => (e as num).toInt())
            .where((i) => i >= 0 && i < sent.chunks.length)
            .toList() ??
        const <int>[];
    for (var i = 0; i < missing.length; i++) {
      _publishToRoom(sent.chunks[missing[i]].toJson());
      if (i < missing.length - 1 && debugPublishSinkForTest == null) {
        await Future<void>.delayed(kTogetherChatChunkPublishGap);
      }
    }
  }

  /// The peer finished a photo: drop the retained chunk list.
  void _handleImageAck(Map<String, dynamic> json) {
    final messageId = json['messageId'] as String?;
    if (messageId == null) return;
    _sentImages.remove(messageId);
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
    // host still learns the guest is in the room within 1 s.
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
      // so a guest that missed the status push still learns it within 1 s.
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
    for (final transfer in _incomingImages.values) {
      transfer.retryTimer?.cancel();
    }
    _incomingImages.clear();
    _disconnect();
    super.dispose();
  }
}

/// One photo arriving in chunks: the reassembler plus the bookkeeping
/// around it (who sent it, how many retries have been asked for, the
/// 5 s retry timer, and where the progress bar last stopped so the UI
/// is not rebuilt per chunk).
class _IncomingImageTransfer {
  _IncomingImageTransfer({
    required this.reassembler,
    required this.senderId,
    required this.timestampMs,
    this.replyToId,
    this.replyToText,
  });

  final TogetherImageReassembler reassembler;
  final String senderId;
  final int timestampMs;
  final String? replyToId;
  final String? replyToText;

  /// Retry requests sent so far (max 3, then the transfer fails).
  int requestsSent = 0;

  /// Fires 5 s after the last chunk seen; re-armed on every chunk.
  Timer? retryTimer;

  /// Last progress fraction the UI was told about (5% throttle).
  double lastNotifiedProgress = 0;
}

/// One photo this phone sent: the chunk list, kept until the peer acks
/// (or 2 minutes pass) so missing chunks can be re-published on request.
class _SentImageTransfer {
  _SentImageTransfer({
    required this.messageId,
    required this.chunks,
    required this.sentAt,
  });

  final String messageId;
  final List<TogetherImageChunk> chunks;
  final DateTime sentAt;
}
