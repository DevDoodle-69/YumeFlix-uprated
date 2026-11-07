import 'dart:async';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';

/// The Together relay connection, as pure data and pure functions.
///
/// Kept free of Flutter, the player engine and [TogetherService] so the
/// failure classification, the relay list and the reconnect math can be
/// unit-tested without a network, a broker or a widget tree.
///
/// ## Why this file exists (2.6.0 post-mortem)
///
/// Together in 2.6.0 could never connect — on any network, with perfect
/// internet — because the MQTT client was built the one way
/// `mqtt_client` 10.14.0 forbids for secure websockets:
///
/// ```dart
/// final client = MqttServerClient.withPort('broker.emqx.io', id, 8084);
/// client.useWebSocket = true;
/// client.secure = true; // <-- the bug
/// ```
///
/// * `secure` is documented "TCP only, do not use for secure websockets
///   (wss)". In `MqttServerClient.connect()` the `if (secure)` block runs
///   *after* the `if (useWebSocket)` block and sets
///   `connectionHandler.useWebSocket = false`, so the client opened a raw
///   secure-TCP MQTT connection to a port that only speaks HTTP/WebSocket.
///   The broker closes that immediately, every time.
/// * The server string was a bare hostname. The websocket path parses it
///   as a URI and requires a `ws://`/`wss://` scheme; the official
///   secure-websocket example builds the client as
///   `MqttServerClient('wss://test.mosquitto.org', '')` with
///   `useWebSocket = true`, `port = 8081`, and explicitly
///   "do not set the secure flag if you are using wss".
///
/// The fix (see [TogetherService]) is the example's construction:
/// `wss://<host>/mqtt` URL, `useWebSocket = true`, `secure` left false,
/// one connection attempt per relay (`maxConnectionAttempts: 1` — the
/// service does its own failover), and a bounded [kTogetherConnectTimeoutMs]
/// so a dead relay fails fast instead of hanging the room.
///
/// Live proof from this machine (2026-11-07, Dart `WebSocket.connect` and
/// a `mqtt_client` probe against the real brokers): the corrected
/// construction connects to EMQX in ~1.5 s and subscribes fine; the
/// 2.6.0 construction fails deterministically. Mosquitto and HiveMQ did
/// not answer from this machine (WS upgrade closed / hung past 25 s), so
/// no third relay was added — HiveMQ is *not* proven reachable and
/// suitable, and an unproven relay is worse than a two-relay list whose
/// failover is bounded and honest about what it tried.

/// One public MQTT relay Together can rendezvous on.
///
/// [url] is the full secure-websocket URL *including* the `/mqtt` path:
/// EMQX and HiveMQ only serve the websocket upgrade on `/mqtt`, and
/// `mqtt_client` never appends a path of its own. [port] is the broker's
/// secure-websocket port, [label] the short name shown in the room UI and
/// in failure text.
class TogetherRelay {
  const TogetherRelay({
    required this.url,
    required this.port,
    required this.label,
  });

  final String url;
  final int port;
  final String label;
}

/// Relays in failover order: EMQX first (proven reachable and fast from
/// a live probe), the public Mosquitto test broker second. No third relay:
/// HiveMQ (`broker.hivemq.com:8884`) never answered a websocket upgrade
/// from this machine, so it is not added on a guess.
const List<TogetherRelay> kTogetherRelays = <TogetherRelay>[
  TogetherRelay(
    url: 'wss://broker.emqx.io/mqtt',
    port: 8084,
    label: 'EMQX',
  ),
  TogetherRelay(
    url: 'wss://test.mosquitto.org/mqtt',
    port: 8081,
    label: 'Mosquitto',
  ),
];

/// How long one relay attempt may take (TCP connect + TLS handshake +
/// websocket upgrade), in milliseconds. `mqtt_client` defaults this to
/// null — no timeout — so a blackholed relay could hold `connect()`
/// forever; 8 s bounds every attempt and therefore the whole failover.
const int kTogetherConnectTimeoutMs = 8000;

/// How long to wait for the broker's CONNACK once the websocket is up, in
/// milliseconds. `mqtt_client` defaults this to 5000; EMQX answers in
/// ~1.5 s end-to-end, so 3 s is plenty and keeps a dead relay cheap.
const int kTogetherConnAckWaitMs = 3000;

/// Reconnect backoff after a mid-room relay drop: 1 s, 2 s, 4 s, 8 s, 15 s.
/// After the fifth failed attempt the room reports the relay unreachable.
const List<int> kTogetherReconnectDelaysSeconds = <int>[1, 2, 4, 8, 15];
const int kTogetherMaxReconnectAttempts = 5;

/// How long the service waits for one relay attempt, as a [Duration].
const Duration kTogetherConnectTimeout = Duration(
  milliseconds: kTogetherConnectTimeoutMs,
);

/// Delay before reconnect attempt [attempt] (0-based). Attempts past the
/// end of [kTogetherReconnectDelaysSeconds] reuse the last delay instead
/// of indexing out of range.
Duration togetherReconnectDelay(int attempt) {
  const delays = kTogetherReconnectDelaysSeconds;
  final clamped = attempt.clamp(0, delays.length - 1);
  return Duration(seconds: delays[clamped]);
}

/// What actually went wrong when a relay connection failed.
///
/// The distinction that matters to the user: [noNetwork] means the
/// failure itself proves the *device* cannot reach the network (DNS
/// lookup failed, or the OS says the network is unreachable) — only then
/// may the UI mention the device's connection at all. Every other
/// failure is the *relay's* problem (or this network blocking it) and
/// must never be reported as "check your internet connection".
enum TogetherConnectFailureKind {
  /// The relay host could not be resolved, or the OS reports the network
  /// itself unreachable. The only kind that may mention the connection.
  noNetwork,

  /// The relay accepted the TCP connection but never answered the
  /// websocket upgrade / CONNACK within the timeout.
  relayTimeout,

  /// The relay (or something in front of it) refused, reset, or closed
  /// the connection, or the TLS handshake failed.
  relayUnreachable,

  /// The broker answered but rejected the MQTT connection.
  brokerRejected,
}

/// One failed attempt to reach the relay(s): what kind of failure it was,
/// which relays were tried, and the low-level detail (exception text) for
/// diagnostics. Never contains a room code or message content.
class TogetherConnectFailure {
  const TogetherConnectFailure({
    required this.kind,
    required this.triedRelays,
    this.detail,
  });

  final TogetherConnectFailureKind kind;

  /// Relay labels tried, in order, e.g. `['EMQX', 'Mosquitto']`.
  final List<String> triedRelays;

  /// The underlying exception text, if any. Shown only in debug logs,
  /// never as the whole user-facing message.
  final String? detail;

  /// Short `EMQX, Mosquitto` list for messages.
  String get triedRelaysLabel => triedRelays.join(', ');

  /// Honest user-facing text. It names what actually failed and which
  /// relays were tried. It never says "check your internet connection":
  /// a relay failure on a working connection is the relay's (or this
  /// network's) fault, and only [TogetherConnectFailureKind.noNetwork]
  /// — DNS / OS-level unreachable — mentions the device's connection.
  String get message {
    final tried = triedRelaysLabel;
    return switch (kind) {
      TogetherConnectFailureKind.noNetwork =>
        'Couldn’t resolve the Together relay ($tried) — the device looks '
            'offline or its DNS is failing. Check the connection and retry.',
      TogetherConnectFailureKind.relayTimeout =>
        'The Together relay ($tried) didn’t answer in time '
            '(${kTogetherConnectTimeoutMs ~/ 1000}s per relay). It may be '
            'slow or blocked on this network — try again, or switch networks.',
      TogetherConnectFailureKind.brokerRejected =>
        'The Together relay ($tried) refused the connection. '
            'Try again in a moment.',
      TogetherConnectFailureKind.relayUnreachable =>
        'Couldn’t reach the Together relay ($tried). Your internet may be '
            'fine — the relay itself didn’t answer, or this network blocks '
            'it. Try again, or switch networks.',
    };
  }
}

/// The outcome of one `_connectAndSubscribe` pass over the relay list.
class TogetherConnectResult {
  const TogetherConnectResult({
    required this.ok,
    this.relay,
    this.failure,
  });

  /// True when a relay connected and the room topic was subscribed.
  final bool ok;

  /// The relay that answered, when [ok] is true.
  final TogetherRelay? relay;

  /// Why every relay failed, when [ok] is false.
  final TogetherConnectFailure? failure;
}

/// Classifies a connection exception into a [TogetherConnectFailureKind].
///
/// Conservative by design: only failures that positively indicate the
/// *device* has no network (DNS lookup failure, OS "network unreachable")
/// map to [TogetherConnectFailureKind.noNetwork]. Everything else —
/// refused, reset, TLS failure, websocket upgrade closed, CONNACK
/// timeout, unknown — is the relay's problem and maps to a relay kind,
/// so the UI never blames the user's internet for a relay failure.
TogetherConnectFailureKind mapConnectError(Object error) {
  if (error is TimeoutException) {
    return TogetherConnectFailureKind.relayTimeout;
  }
  if (error is NoConnectionException) {
    // mqtt_client reports a lapsed connection timeout in the message.
    if (error.toString().toLowerCase().contains('timeout')) {
      return TogetherConnectFailureKind.relayTimeout;
    }
    return TogetherConnectFailureKind.relayUnreachable;
  }
  if (error is HandshakeException) {
    return TogetherConnectFailureKind.relayUnreachable;
  }
  if (error is HttpException) {
    // A websocket upgrade the broker closed mid-handshake.
    return TogetherConnectFailureKind.relayUnreachable;
  }
  if (error is SocketException) {
    final message = error.message.toLowerCase();
    final osMessage = error.osError?.message.toLowerCase() ?? '';
    final text = '$message $osMessage';
    if (text.contains('failed host lookup') ||
        text.contains('name or service not known') ||
        text.contains('nodename nor servname')) {
      return TogetherConnectFailureKind.noNetwork;
    }
    if (text.contains('network is unreachable') ||
        text.contains('no route to host')) {
      return TogetherConnectFailureKind.noNetwork;
    }
    return TogetherConnectFailureKind.relayUnreachable;
  }
  return TogetherConnectFailureKind.relayUnreachable;
}

/// One-line connection status for the room UI.
///
/// * connected: `Connected via EMQX` (+ ` · 120 ms` when [roundTripMs]
///   was really measured — never a made-up number);
/// * reconnecting: `Reconnecting… (attempt 2/5)` (+ ` · last tried EMQX`
///   when known);
/// * connecting: `Connecting to the Together relay…`;
/// * otherwise: `Not connected`.
String togetherConnectionStatusLabel({
  required bool connected,
  required bool reconnecting,
  required bool connecting,
  String? relayLabel,
  int? roundTripMs,
  int reconnectAttempt = 0,
  int maxReconnectAttempts = kTogetherMaxReconnectAttempts,
  String? lastTriedRelaysLabel,
}) {
  if (connected) {
    final relay = relayLabel == null ? '' : ' via $relayLabel';
    final latency = roundTripMs == null ? '' : ' · $roundTripMs ms';
    return 'Connected$relay$latency';
  }
  if (reconnecting) {
    final attempt = ' (attempt ${reconnectAttempt + 1}/$maxReconnectAttempts)';
    final tried = lastTriedRelaysLabel == null
        ? ''
        : ' · last tried $lastTriedRelaysLabel';
    return 'Reconnecting…$attempt$tried';
  }
  if (connecting) return 'Connecting to the Together relay…';
  return 'Not connected';
}
