import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:yumeflix/features/together/connection.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.7.0 Together connection fix: the relay list, the failure
/// classification (a broker failure is NEVER reported as a network error),
/// the reconnect/backoff math, the status label, and the status/presence
/// message round-trips the room depends on.
///
/// No test here touches the network: the classification and the labels
/// are pure functions of the exception / state, and the relay list is
/// data. The live behaviour (a real `mqtt_client` connect to EMQX with
/// the corrected construction) was verified by hand from this machine
/// with a throwaway probe — see `connection.dart` — and still needs the
/// two-phone user test.
void main() {
  group('relay list (failover order)', () {
    test('EMQX first, Mosquitto second — and nothing unproven', () {
      expect(kTogetherRelays.length, 2);
      expect(kTogetherRelays[0].label, 'EMQX');
      expect(kTogetherRelays[0].url, 'wss://broker.emqx.io/mqtt');
      expect(kTogetherRelays[0].port, 8084);
      expect(kTogetherRelays[1].label, 'Mosquitto');
      expect(kTogetherRelays[1].url, 'wss://test.mosquitto.org/mqtt');
      expect(kTogetherRelays[1].port, 8081);
    });

    test('every relay is a wss URL with the /mqtt path (mqtt_client '
        'never appends a path, and EMQX only serves the upgrade on /mqtt)', () {
      for (final relay in kTogetherRelays) {
        expect(relay.url.startsWith('wss://'), isTrue, reason: relay.label);
        expect(relay.url.endsWith('/mqtt'), isTrue, reason: relay.label);
        expect(relay.url.contains('://'), isTrue);
      }
      // No HiveMQ: it never answered a websocket upgrade from this
      // machine, so it is not added on a guess.
      expect(
        kTogetherRelays.map((r) => r.label),
        isNot(contains('HiveMQ')),
      );
    });

    test('one relay attempt is bounded: 8 s connect timeout, 3 s CONNACK wait', () {
      expect(kTogetherConnectTimeoutMs, 8000);
      expect(kTogetherConnAckWaitMs, 3000);
    });
  });

  group('mapConnectError — a broker failure is NOT a network error', () {
    test('timeouts are relay timeouts, not network errors', () {
      expect(
        mapConnectError(TimeoutException('connect timed out')),
        TogetherConnectFailureKind.relayTimeout,
      );
      expect(
        mapConnectError(
          NoConnectionException(
            'The connection to the message broker {wss://broker.emqx.io:8084/mqtt} '
            'could not be made, the connection timeout of 8000ms has elapsed',
          ),
        ),
        TogetherConnectFailureKind.relayTimeout,
      );
    });

    test('a broker that closes / refuses / fails TLS is relayUnreachable', () {
      expect(
        mapConnectError(NoConnectionException('maximum attempts exceeded')),
        TogetherConnectFailureKind.relayUnreachable,
      );
      expect(
        mapConnectError(const SocketException('Connection refused')),
        TogetherConnectFailureKind.relayUnreachable,
      );
      expect(
        mapConnectError(const SocketException('Connection reset by peer')),
        TogetherConnectFailureKind.relayUnreachable,
      );
      expect(
        mapConnectError(const HandshakeException('Handshake error')),
        TogetherConnectFailureKind.relayUnreachable,
      );
      expect(
        mapConnectError(
          const HttpException(
            'Connection closed before full header was received',
          ),
        ),
        TogetherConnectFailureKind.relayUnreachable,
      );
      expect(
        mapConnectError(Exception('something unexpected')),
        TogetherConnectFailureKind.relayUnreachable,
      );
    });

    test('only DNS / OS-level unreachable is noNetwork', () {
      expect(
        mapConnectError(
          const SocketException('Failed host lookup: broker.emqx.io'),
        ),
        TogetherConnectFailureKind.noNetwork,
      );
      expect(
        mapConnectError(
          const SocketException(
            'Connection failed',
            osError: OSError('Network is unreachable', 101),
          ),
        ),
        TogetherConnectFailureKind.noNetwork,
      );
      expect(
        mapConnectError(
          const SocketException('Connection failed', osError: OSError('No route to host', 113)),
        ),
        TogetherConnectFailureKind.noNetwork,
      );
    });
  });

  group('TogetherConnectFailure.message — honest, never "check internet"', () {
    const tried = <String>['EMQX', 'Mosquitto'];

    test('no message blames the user’s internet for a relay failure', () {
      for (final kind in TogetherConnectFailureKind.values) {
        final message = TogetherConnectFailure(
          kind: kind,
          triedRelays: tried,
        ).message;
        expect(
          message.toLowerCase(),
          isNot(contains('check internet')),
          reason: '$kind said: $message',
        );
        expect(
          message.toLowerCase(),
          isNot(contains('check your internet')),
          reason: '$kind said: $message',
        );
      }
    });

    test('relay failures name the relays tried', () {
      final unreachable = const TogetherConnectFailure(
        kind: TogetherConnectFailureKind.relayUnreachable,
        triedRelays: tried,
      ).message;
      expect(unreachable, contains('EMQX, Mosquitto'));
      expect(unreachable, contains('Your internet may be fine'));

      final timeout = const TogetherConnectFailure(
        kind: TogetherConnectFailureKind.relayTimeout,
        triedRelays: tried,
      ).message;
      expect(timeout, contains('EMQX, Mosquitto'));
      expect(timeout, contains('8s'));

      final rejected = const TogetherConnectFailure(
        kind: TogetherConnectFailureKind.brokerRejected,
        triedRelays: tried,
      ).message;
      expect(rejected, contains('refused'));
    });

    test('only the noNetwork message mentions the device connection — '
        'and only because DNS itself failed', () {
      final message = const TogetherConnectFailure(
        kind: TogetherConnectFailureKind.noNetwork,
        triedRelays: tried,
      ).message;
      expect(message, contains('offline'));
      expect(message, contains('DNS'));
    });

    test('the legacy fallback constant no longer blames the internet either', () {
      expect(
        kTogetherRelayUnreachableMessage.toLowerCase(),
        isNot(contains('check internet')),
      );
    });
  });

  group('reconnect / backoff', () {
    test('delays are 1, 2, 4, 8, 15 s and the cap is 5 attempts', () {
      expect(kTogetherReconnectDelaysSeconds, <int>[1, 2, 4, 8, 15]);
      expect(kTogetherMaxReconnectAttempts, 5);
      expect(togetherReconnectDelay(0), const Duration(seconds: 1));
      expect(togetherReconnectDelay(1), const Duration(seconds: 2));
      expect(togetherReconnectDelay(2), const Duration(seconds: 4));
      expect(togetherReconnectDelay(3), const Duration(seconds: 8));
      expect(togetherReconnectDelay(4), const Duration(seconds: 15));
    });

    test('attempts past the list reuse the last delay instead of crashing', () {
      expect(togetherReconnectDelay(5), const Duration(seconds: 15));
      expect(togetherReconnectDelay(99), const Duration(seconds: 15));
    });
  });

  group('togetherConnectionStatusLabel', () {
    test('connected shows the relay, and latency only when measured', () {
      expect(
        togetherConnectionStatusLabel(
          connected: true,
          reconnecting: false,
          connecting: false,
          relayLabel: 'EMQX',
          roundTripMs: 120,
        ),
        'Connected via EMQX · 120 ms',
      );
      expect(
        togetherConnectionStatusLabel(
          connected: true,
          reconnecting: false,
          connecting: false,
          relayLabel: 'EMQX',
        ),
        'Connected via EMQX',
      );
      expect(
        togetherConnectionStatusLabel(
          connected: true,
          reconnecting: false,
          connecting: false,
        ),
        'Connected',
      );
    });

    test('reconnecting shows the attempt count and the relay last tried', () {
      expect(
        togetherConnectionStatusLabel(
          connected: false,
          reconnecting: true,
          connecting: false,
          reconnectAttempt: 1,
          lastTriedRelaysLabel: 'EMQX, Mosquitto',
        ),
        'Reconnecting… (attempt 2/5) · last tried EMQX, Mosquitto',
      );
    });

    test('connecting and idle states', () {
      expect(
        togetherConnectionStatusLabel(
          connected: false,
          reconnecting: false,
          connecting: true,
        ),
        'Connecting to the Together relay…',
      );
      expect(
        togetherConnectionStatusLabel(
          connected: false,
          reconnecting: false,
          connecting: false,
        ),
        'Not connected',
      );
    });
  });

  group('TogetherService initial connection state', () {
    test('starts disconnected with no relay, no latency, no failure', () {
      final service = TogetherService();
      addTearDown(service.dispose);
      expect(service.phase, TogetherPhase.idle);
      expect(service.isConnected, isFalse);
      expect(service.connectedRelayLabel, isNull);
      expect(service.roundTripMs, isNull);
      expect(service.lastFailure, isNull);
      expect(service.attemptedRelayLabels, isEmpty);
      expect(service.reconnectAttempt, 0);
      expect(service.reconnecting, isFalse);
      expect(service.connectionStatusLabel, 'Not connected');
    });
  });

  group('TogetherService wire round-trips (via the @visibleForTesting seams)', () {
    test('own heartbeat echo measures the MQTT round-trip', () {
      final service = TogetherService();
      addTearDown(service.dispose);
      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      expect(service.roundTripMs, isNull);

      final sentMs = DateTime.now().millisecondsSinceEpoch - 137;
      service.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'heartbeat',
          'senderId': service.clientId,
          'positionMs': 60000,
          'timestampMs': sentMs,
        }),
      );
      // ~137 ms sent 137 ms ago, plus test overhead: a real measurement
      // in a plausible band, never a guess. (The status pill only shows
      // the latency while actually connected; the pure label test covers
      // that branch with connected: true.)
      expect(service.roundTripMs, isNotNull);
      expect(service.roundTripMs!, greaterThanOrEqualTo(100));
      expect(service.roundTripMs!, lessThan(5000));
    });

    test('presence join/leave round-trips update the presence line', () {
      final service = TogetherService();
      addTearDown(service.dispose);
      service.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(service.hostPresent, isFalse);

      service.debugReceivePayloadForTest(
        jsonEncode(
          const TogetherPresenceEvent(
            senderId: 'yumeflix-host1',
            role: 'host',
            joined: true,
            timestampMs: 1000000,
          ).toJson(),
        ),
      );
      expect(service.hostPresent, isTrue);
      expect(service.memberCount, 1);
      expect(service.presenceLabel, 'HOST 👑 in room');

      service.debugReceivePayloadForTest(
        jsonEncode(
          const TogetherPresenceEvent(
            senderId: 'yumeflix-host1',
            role: 'host',
            joined: false,
            timestampMs: 1001000,
          ).toJson(),
        ),
      );
      expect(service.hostPresent, isFalse);
      expect(service.hostGone, isTrue);
    });

    test('host status round-trips update the waiting screen’s live line', () {
      final service = TogetherService();
      addTearDown(service.dispose);
      service.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(service.roomStatus, TogetherRoomStatus.hostBrowsing);

      service.debugReceivePayloadForTest(
        jsonEncode(
          const TogetherRoomStatusMessage(
            status: TogetherRoomStatus.hostPickedTitle,
            media: TogetherMediaIdentity(
              title: 'Dune',
              tmdbType: 'movie',
              tmdbId: 693134,
            ),
            senderId: 'yumeflix-host1',
            timestampMs: 1000000,
          ).toJson(),
        ),
      );
      expect(service.roomStatus, TogetherRoomStatus.hostPickedTitle);
      expect(service.roomStatus.label, 'Host picked a title');
      expect(service.currentMedia?.title, 'Dune');
      expect(service.hostPresent, isTrue);
    });

    test('own chat echo is ignored — the local copy is already listed', () {
      final service = TogetherService();
      addTearDown(service.dispose);
      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      service.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'chat',
          'id': '${service.clientId}-1-1',
          'senderId': service.clientId,
          'senderLabel': 'You',
          'text': 'hello',
          'timestampMs': 1000000,
        }),
      );
      expect(service.messages, isEmpty);
    });
  });
}
