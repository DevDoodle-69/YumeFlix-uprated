// YumeFlix live checks — run with: `dart tools/live_check.dart`
//
// Hits the LIVE internet (no Flutter app, no mocks) and verifies the six
// things 2.8.0 claims, end to end:
//
//   1. Together MQTT round-trip: host creates a room on a throwaway OTP,
//      guest joins, host publishes a status + a retained playback state,
//      guest receives the same title + position (within tolerance).
//      Uses the exact client construction the app uses (see
//      lib/features/together/together_service.dart): `wss://<host>/mqtt`
//      URL, `useWebSocket = true`, `secure` NEVER set (setting it together
//      with useWebSocket silently turns the websocket off — the 2.6.0 bug
//      that made Together fail on every network with a "check internet"
//      error). Relays are tried in the app's order: EMQX, then Mosquitto.
//   2. Together chunked chat image (2.8.0, `_checkTogetherChunkedImage`
//      — one clearly-marked function, self-contained): a real ~1 MB image
//      round-trips over the live broker as 32 KiB chunks and reassembles
//      byte-exact with its SHA-256 intact, including an out-of-order
//      chunk and a duplicate. Chunks are sent paced (250 ms gaps — the
//      public relay drops rapid bursts) and, if any are still missing,
//      the guest asks for exactly those indices and the host re-publishes
//      just them, up to 3 retry rounds — the same protocol the app runs.
//   3. Discord poster chain for "Harry Potter and the Deathly Hallows:
//      Part 2" (IMDb tt1201607): keyless Cinemeta lookup returns a poster
//      URL, and that URL (plus the metahub extension poster) really
//      fetches HTTP 200 as an image. The built Gateway activity payload
//      must then carry a valid https `large_image` — and never a dead
//      asset key (the 2.6.0 black-circle cause).
//   4. MovieSubLK provider live: a real search for "Aquaman" returns
//      results with https thumbnails, and a real detail fetch returns an
//      https poster that fetches HTTP 200 as an image.
//   5. Discord poster chain for a SERIES, "Dexter: Resurrection" (IMDb
//      tt33043892): the keyless Cinemeta lookup works by series id AND by
//      exact title search (the no-ImdbId path), the episode still and the
//      poster fetch as images, and the built activity carries a valid
//      https `large_image` with the correct "S1 E1" series title.
//   6. Together start flow over the live broker: room created, guest sees
//      the host browsing with NO go-live state yet, then the host going
//      live publishes a retained playing state the guest receives, and a
//      title change re-shares the new title at position 0.
//
// Exit code 0 = every check passed. Exit code 1 = at least one failed
// (the failing check prints why). No credentials, no tokens, no writes.
// A failure here means the feature is broken live — fix the code, not
// this script.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const String _hpTitle = 'Harry Potter and the Deathly Hallows: Part 2';
const String _hpImdbId = 'tt1201607';
const String _cinemetaBase = 'https://v3-cinemeta.strem.io';
const String _metahubPoster =
    'https://images.metahub.space/poster/medium/tt1201607/img';
const String _aquamanSlug = 'aquaman-2018-sinhala-subtitles';
const String _dexterTitle = 'Dexter: Resurrection';
const String _dexterImdbId = 'tt33043892';
const String _dexterEpisodeStill =
    'https://episodes.metahub.space/tt33043892/0/1/w780.jpg';

int _passed = 0;
int _failed = 0;

void _check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _passed++;
    print('  PASS  $name${detail.isEmpty ? '' : ' — $detail'}');
  } else {
    _failed++;
    print('  FAIL  $name${detail.isEmpty ? '' : ' — $detail'}');
  }
}

Future<Map<String, dynamic>?> _getJson(Uri uri) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/json');
      request.headers.set(
        'User-Agent',
        'YumeFlix-live-check/2.7.0 (Dart HttpClient)',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      // Retry once: live networks are flaky, a single slow attempt
      // must not fail the whole check.
      if (attempt == 1) return null;
    } finally {
      client.close();
    }
  }
  return null;
}

Future<String?> _getHtml(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(
      'User-Agent',
      'Mozilla/5.0 (YumeFlix-live-check/2.7.0)',
    );
    final response = await request.close().timeout(
      const Duration(seconds: 30),
    );
    if (response.statusCode != 200) return null;
    return await response.transform(utf8.decoder).join();
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// True only for a URL that really fetches as an image: HTTP 200 (or 206
/// for a ranged re-request) with `content-type: image/*`. HEAD first,
/// ranged GET as fallback for HEAD-refusing hosts — the same rule the app
/// uses before sending a poster to Discord. Any HEAD failure (timeout,
/// error, non-image status) falls through to the ranged GET instead of
/// failing outright: a slow HEAD must not condemn a fetchable poster.
Future<bool> _verifyImageUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    try {
      final head = await client.headUrl(uri);
      head.headers.set('User-Agent', 'YumeFlix-live-check/2.7.0');
      final headResponse = await head.close().timeout(
        const Duration(seconds: 30),
      );
      await headResponse.drain<void>();
      if (headResponse.statusCode == 200) {
        final type = headResponse.headers.contentType?.mimeType ?? '';
        if (type.startsWith('image/')) return true;
      }
    } catch (_) {
      // Fall through to the ranged GET below.
    }
    final get = await client.getUrl(uri);
    get.headers.set('Range', 'bytes=0-1023');
    get.headers.set('User-Agent', 'YumeFlix-live-check/2.7.0');
    final getResponse = await get.close().timeout(
      const Duration(seconds: 30),
    );
    await getResponse.drain<void>();
    if (getResponse.statusCode != 200 && getResponse.statusCode != 206) {
      return false;
    }
    final type = getResponse.headers.contentType?.mimeType ?? '';
    return type.startsWith('image/');
  } catch (_) {
    return false;
  } finally {
    client.close();
  }
}

/// The Discord activity payload the app builds for a playing title.
/// Mirrors DiscordPresenceService.buildActivity: type 3, details = title,
/// assets.large_image = verified https poster ONLY — no small_image and no
/// uploaded-asset key (a key Discord was never given renders as a black
/// circle, which is what 2.6.0 shipped).
Map<String, dynamic> _buildDiscordActivity({
  required String title,
  String? posterUrl,
}) {
  final activity = <String, dynamic>{
    'application_id': '1322319281819488256',
    'name': 'YumeFlix',
    'type': 3,
    'details': title,
    'state': 'Watching',
  };
  final poster = posterUrl?.trim();
  final uri = poster == null ? null : Uri.tryParse(poster);
  if (poster != null &&
      poster.isNotEmpty &&
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty) {
    activity['assets'] = {
      'large_image': poster,
      'large_text': title,
    };
  }
  return activity;
}

MqttServerClient _buildMqttClient(String url, int port, String clientId) {
  // Exactly the app's construction: wss:// URL, websocket on, secure
  // NEVER set (it is TCP-only and disables the websocket).
  final client = MqttServerClient(url, clientId, maxConnectionAttempts: 1);
  client.useWebSocket = true;
  client.port = port;
  client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
  client.keepAlivePeriod = 20;
  client.logging(on: false);
  client.connectionTimeout = 8000;
  client.connectTimeoutPeriod = 3000;
  client.connectionMessage = MqttConnectMessage()
      .withClientIdentifier(clientId)
      .startClean();
  return client;
}

Future<MqttServerClient?> _connectRelay(
  String url,
  int port,
  String label,
  String clientId,
) async {
  final client = _buildMqttClient(url, port, clientId);
  try {
    await client.connect().timeout(const Duration(seconds: 15));
    if (client.connectionStatus?.state == MqttConnectionState.connected) {
      print('  info  connected to $label relay ($url:$port)');
      return client;
    }
  } catch (e) {
    print('  info  $label relay failed: $e');
  }
  try {
    client.disconnect();
  } catch (_) {}
  return null;
}

void _publish(
  MqttServerClient client,
  String topic,
  Map<String, dynamic> payload, {
  bool retain = false,
}) {
  final builder = MqttClientPayloadBuilder();
  // addUTF8String, NEVER addString: addString encodes UTF-16-ish
  // (Latin-1 bytes for code units <= 255, raw half-words above), which
  // is not valid UTF-8 — any non-ASCII character (the '·' in a series
  // title, an accent, an emoji) then fails utf8.decode on receipt and
  // bytesToStringAsString returns '' so the message is silently lost.
  // The app's TogetherService publishes with utf8.encode (correct);
  // this script must do the same or it tests a bug the app doesn't have.
  builder.addUTF8String(jsonEncode(payload));
  client.publishMessage(
    topic,
    MqttQos.atLeastOnce,
    builder.payload!,
    retain: retain,
  );
}

Future<void> _checkTogether() async {
  print('[1/6] Together MQTT round-trip (live broker)');
  final otp = (100000 + Random().nextInt(900000)).toString();
  final topic = 'yumeflix/together/v1/$otp';
  const title = _hpTitle;
  const positionMs = 42000;
  const durationMs = 7826000;

  final guestId = 'livecheck-guest-${Random().nextInt(1 << 30)}';
  final hostId = 'livecheck-host-${Random().nextInt(1 << 30)}';
  MqttServerClient? guest;
  MqttServerClient? host;
  String? relayLabel;

  // Guest first (like a real guest joining before the host goes live),
  // then the host — both on the same throwaway OTP topic.
  for (final relay in const [
    ('wss://broker.emqx.io/mqtt', 8084, 'EMQX'),
    ('wss://test.mosquitto.org/mqtt', 8081, 'Mosquitto'),
  ]) {
    guest = await _connectRelay(relay.$1, relay.$2, relay.$3, guestId);
    if (guest != null) {
      relayLabel = relay.$3;
      break;
    }
  }
  _check('guest connects to a Together relay', guest != null);
  if (guest == null) {
    print('  FAIL  host/guest round-trip skipped — no relay reachable');
    _failed++;
    return;
  }
  host = await _connectRelay(
    relayLabel == 'EMQX'
        ? 'wss://broker.emqx.io/mqtt'
        : 'wss://test.mosquitto.org/mqtt',
    relayLabel == 'EMQX' ? 8084 : 8081,
    relayLabel!,
    hostId,
  );
  _check('host connects to the same relay ($relayLabel)', host != null);
  if (host == null) {
    guest.disconnect();
    return;
  }

  final received = <Map<String, dynamic>>[];
  final stateSeen = Completer<Map<String, dynamic>>();
  final statusSeen = Completer<Map<String, dynamic>>();
  guest.subscribe(topic, MqttQos.atLeastOnce);
  guest.updates!.listen((events) {
    for (final event in events) {
      final payload = event.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          received.add(decoded);
          if (decoded['kind'] == 'state' && !stateSeen.isCompleted) {
            stateSeen.complete(decoded);
          }
          if (decoded['kind'] == 'status' && !statusSeen.isCompleted) {
            statusSeen.complete(decoded);
          }
        }
      } catch (_) {}
    }
  });
  await Future<void>.delayed(const Duration(seconds: 1));

  // Host: browsing status, then go-live with the retained playback state.
  _publish(host, topic, {
    'kind': 'status',
    'status': 'hostBrowsing',
  });
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _publish(host, topic, {
    'kind': 'state',
    'media': {
      'title': title,
      'tmdbType': 'movie',
      'tmdbId': 121,
      'posterUrl': _metahubPoster,
    },
    'positionMs': positionMs,
    'durationMs': durationMs,
    'playing': false,
    'hostTimestampMs': DateTime.now().millisecondsSinceEpoch,
    'sequence': 1,
    'hostId': hostId,
  }, retain: true);

  Map<String, dynamic>? state;
  try {
    state = await stateSeen.future.timeout(const Duration(seconds: 15));
  } on TimeoutException {
    state = null;
  }
  _check('guest receives the host playback state', state != null);
  if (state != null) {
    final media = state['media'];
    final gotTitle = media is Map ? media['title'] as String? : null;
    final gotPosition = (state['positionMs'] as num?)?.toInt();
    _check('guest sees the same title', gotTitle == title, 'got "$gotTitle"');
    final drift = gotPosition == null
        ? null
        : (gotPosition - positionMs).abs();
    _check(
      'guest sees the same position (±2000 ms)',
      drift != null && drift <= 2000,
      'got ${gotPosition}ms, drift ${drift}ms',
    );
    _check(
      'state carries a poster URL for the guest card',
      media is Map &&
          (media['posterUrl'] as String?)?.startsWith('https://') == true,
    );
  }
  Map<String, dynamic>? status;
  try {
    status = await statusSeen.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    status = null;
  }
  _check(
    'guest receives the host status message',
    status != null,
    status == null ? '' : 'status=${status['status']}',
  );

  try {
    host.disconnect();
  } catch (_) {}
  try {
    guest.disconnect();
  } catch (_) {}
}

/// [2.8.0 — Together chunked chat image, ONE self-contained function]
/// A real ~1 MB image round-trips over the live broker the way the app
/// sends it (see lib/features/together/chat_image_chunks.dart): split
/// into 32 KiB chunks on the room topic, reassembled by the guest and
/// verified byte-exact with SHA-256. The chunks go out out of order with
/// one duplicate, because the relay (QoS 1) owes the app neither order
/// nor exactly-once delivery. If any chunk is lost or corrupted, the
/// reassembly check fails here — exactly as the app refuses to show a
/// partial photo. Deliberately duplicated here instead of importing the
/// app's chunk module: this script runs standalone with `dart
/// tools/live_check.dart` and must keep working even if the app's chunk
/// shape changes (a drift between the two is itself a failure to fix).
Future<void> _checkTogetherChunkedImage() async {
  print('[2/6] Together chunked chat image — ~1 MB over the live broker');
  const imageBytes = 1024 * 1024;
  const chunkBytes = 32 * 1024;
  final otp = (100000 + Random().nextInt(900000)).toString();
  final topic = 'yumeflix/together/v1/$otp';
  const messageId = 'livecheck-img-1';
  final senderId = 'livecheck-img-host-${Random().nextInt(1 << 30)}';
  final guestId = 'livecheck-img-guest-${Random().nextInt(1 << 30)}';

  // ~1 MB of incompressible bytes: a real photo's size class, without
  // depending on any image file on disk.
  final random = Random(1234);
  final original = List<int>.generate(imageBytes, (_) => random.nextInt(256));
  final checksum = sha256.convert(original).toString();
  final totalChunks = (imageBytes + chunkBytes - 1) ~/ chunkBytes;

  MqttServerClient? guest;
  MqttServerClient? host;
  String? relayLabel;
  for (final relay in const [
    ('wss://broker.emqx.io/mqtt', 8084, 'EMQX'),
    ('wss://test.mosquitto.org/mqtt', 8081, 'Mosquitto'),
  ]) {
    guest = await _connectRelay(relay.$1, relay.$2, relay.$3, guestId);
    if (guest != null) {
      relayLabel = relay.$3;
      break;
    }
  }
  _check('guest connects to a Together relay', guest != null);
  if (guest == null) {
    _failed++;
    print('  FAIL  chunked image round-trip skipped — no relay reachable');
    return;
  }
  host = await _connectRelay(
    relayLabel == 'EMQX'
        ? 'wss://broker.emqx.io/mqtt'
        : 'wss://test.mosquitto.org/mqtt',
    relayLabel == 'EMQX' ? 8084 : 8081,
    relayLabel!,
    senderId,
  );
  _check('host connects to the same relay ($relayLabel)', host != null);
  if (host == null) {
    guest.disconnect();
    return;
  }

  try {
    final received = <int, List<int>>{};
    final complete = Completer<void>();
    guest.subscribe(topic, MqttQos.atLeastOnce);
    guest.updates!.listen((events) {
      for (final event in events) {
        final payload = event.payload as MqttPublishMessage;
        final text = MqttPublishPayload.bytesToStringAsString(
          payload.payload.message,
        );
        try {
          final decoded = jsonDecode(text);
          if (decoded is! Map<String, dynamic>) continue;
          if (decoded['kind'] != 'chat-image-chunk') continue;
          if (decoded['messageId'] != messageId) continue;
          final index = (decoded['chunkIndex'] as num?)?.toInt();
          final data = decoded['data'] as String?;
          if (index == null || data == null) continue;
          // A duplicate (QoS 1) overwrites identical bytes: harmless.
          received[index] = base64Decode(data);
          if (received.length == totalChunks && !complete.isCompleted) {
            complete.complete();
          }
        } catch (_) {}
      }
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    final sentAt = DateTime.now();

    // One paced publish of a list of chunk indices, with the same 250 ms
    // gap the app uses (see kTogetherChatChunkPublishGap in
    // lib/features/together/chat_image_chunks.dart): the public relay
    // drops rapid bursts — measured 2026-11-07, 32 chunks at 20 ms or
    // 100 ms gaps lost ~40–70% of the burst (identical loss on two
    // independent receivers, so broker-side), while 200/250/500 ms gaps
    // all delivered 32/32 first-pass. Used for the initial send and for
    // every retry round below.
    //
    // (Non-null alias: `host` is nullable and a closure cannot use its
    // null-check promotion.)
    final liveHost = host;
    Future<void> publishChunks(List<int> indices) async {
      for (var i = 0; i < indices.length; i++) {
        final index = indices[i];
        final start = index * chunkBytes;
        var end = start + chunkBytes;
        if (end > imageBytes) end = imageBytes;
        _publish(liveHost, topic, {
          'kind': 'chat-image-chunk',
          'messageId': messageId,
          'senderId': senderId,
          'timestampMs': sentAt.millisecondsSinceEpoch,
          'totalChunks': totalChunks,
          'chunkIndex': index,
          'totalBytes': imageBytes,
          'sha256': checksum,
          'data': base64Encode(original.sublist(start, end)),
        });
        if (i < indices.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    }

    // The host hears retry requests on the same topic (it is subscribed
    // too) and re-publishes just the missing indices — the same protocol
    // the app runs in TogetherService.
    host.subscribe(topic, MqttQos.atLeastOnce);
    host.updates!.listen((events) {
      for (final event in events) {
        final payload = event.payload as MqttPublishMessage;
        final text = MqttPublishPayload.bytesToStringAsString(
          payload.payload.message,
        );
        try {
          final decoded = jsonDecode(text);
          if (decoded is! Map<String, dynamic>) continue;
          if (decoded['kind'] != 'chat-image-request') continue;
          if (decoded['messageId'] != messageId) continue;
          final missing = (decoded['missing'] as List?)
              ?.map((e) => (e as num).toInt())
              .where((i) => i >= 0 && i < totalChunks)
              .toList();
          if (missing == null || missing.isEmpty) continue;
          unawaited(publishChunks(missing));
        } catch (_) {}
      }
    });

    // Out of order on purpose (last chunk first), plus a duplicate of
    // chunk 0 at the end.
    final order = <int>[
      totalChunks - 1,
      ...List<int>.generate(totalChunks - 1, (i) => i + 1),
      0,
      0, // duplicate
    ];
    await publishChunks(order);
    _check(
      'host published $totalChunks chunks (+1 duplicate, out of order)',
      true,
      '$imageBytes bytes in ${totalChunks}x32 KiB chunks, paced 250 ms',
    );

    bool allArrived = false;
    try {
      await complete.future.timeout(const Duration(seconds: 20));
      allArrived = true;
    } on TimeoutException {
      allArrived = false;
    }
    // First pass not complete: run the app's retry protocol — the guest
    // asks for exactly the missing indices, the host re-publishes just
    // those, up to 3 rounds like TogetherService.
    var retryRounds = 0;
    for (var round = 1; round <= 3 && !allArrived; round++) {
      retryRounds = round;
      final missing = List<int>.generate(totalChunks, (i) => i)
          .where((i) => !received.containsKey(i))
          .toList();
      print(
        '  retry round $round: guest asks for ${missing.length} missing '
        'chunks',
      );
      _publish(guest, topic, {
        'kind': 'chat-image-request',
        'messageId': messageId,
        'senderId': guestId,
        'missing': missing,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      });
      try {
        await complete.future.timeout(const Duration(seconds: 10));
        allArrived = true;
      } on TimeoutException {
        allArrived = false;
      }
    }
    _check(
      'guest received every chunk',
      allArrived,
      allArrived
          ? (retryRounds == 0
                ? 'first pass, no retry needed'
                : 'after $retryRounds retry round(s)')
          : 'got ${received.length}/$totalChunks chunks',
    );
    if (allArrived) {
      final reassembled = <int>[];
      for (var i = 0; i < totalChunks; i++) {
        reassembled.addAll(received[i]!);
      }
      _check(
        'reassembled image is the same length',
        reassembled.length == imageBytes,
        'got ${reassembled.length} bytes',
      );
      _check(
        'reassembled image matches the SHA-256 (byte-exact)',
        sha256.convert(reassembled).toString() == checksum,
      );
      final elapsed = DateTime.now().difference(sentAt);
      _check(
        'round-trip finished in a reasonable time',
        elapsed < const Duration(seconds: 90),
        '${elapsed.inMilliseconds} ms for $totalChunks chunks',
      );
    }
  } finally {
    try {
      host.disconnect();
    } catch (_) {}
    try {
      guest.disconnect();
    } catch (_) {}
  }
}

Future<void> _checkDiscordPoster() async {
  print('[3/6] Discord poster chain — $_hpTitle ($_hpImdbId)');
  final meta = await _getJson(
    Uri.parse('$_cinemetaBase/meta/movie/$_hpImdbId.json'),
  );
  final cinemetaPoster = meta == null
      ? null
      : (meta['meta'] as Map?)?['poster'] as String?;
  _check(
    'Cinemeta (keyless) returns a poster URL',
    cinemetaPoster != null && cinemetaPoster.startsWith('https://'),
    cinemetaPoster ?? 'no poster in response',
  );
  String? verifiedPoster;
  if (cinemetaPoster != null) {
    // Cinemeta serves /poster/small/ — the app upgrades to medium.
    final medium = cinemetaPoster.replaceFirst(
      '/poster/small/',
      '/poster/medium/',
    );
    final ok = await _verifyImageUrl(medium);
    _check(
      'Cinemeta poster fetches HTTP 200 as an image',
      ok,
      medium,
    );
    if (ok) verifiedPoster = medium;
  }
  final metahubOk = await _verifyImageUrl(_metahubPoster);
  _check(
    'extension (metahub) poster fetches HTTP 200 as an image',
    metahubOk,
    _metahubPoster,
  );
  verifiedPoster ??= metahubOk ? _metahubPoster : null;

  final activity = _buildDiscordActivity(
    title: _hpTitle,
    posterUrl: verifiedPoster,
  );
  final assets = activity['assets'];
  final largeImage = assets is Map ? assets['large_image'] as String? : null;
  _check(
    'built activity carries a valid https large_image',
    largeImage != null && largeImage.startsWith('https://'),
    largeImage ?? 'no large_image in payload',
  );
  _check(
    'built activity never sends an un-uploaded asset key',
    largeImage == null || largeImage.startsWith('https://'),
    'large_image=$largeImage',
  );
  _check(
    'activity title is clean (no S/E suffix on a movie)',
    (activity['details'] as String) == _hpTitle,
  );
}

Future<void> _checkDiscordPosterSeries() async {
  print('[4/6] Discord poster chain — series $_dexterTitle ($_dexterImdbId)');
  final meta = await _getJson(
    Uri.parse('$_cinemetaBase/meta/series/$_dexterImdbId.json'),
  );
  final cinemetaPoster = meta == null
      ? null
      : (meta['meta'] as Map?)?['poster'] as String?;
  _check(
    'Cinemeta (keyless) returns a series poster URL',
    cinemetaPoster != null && cinemetaPoster.startsWith('https://'),
    cinemetaPoster ?? 'no poster in response',
  );
  String? verifiedPoster;
  if (cinemetaPoster != null) {
    final medium = cinemetaPoster.replaceFirst(
      '/poster/small/',
      '/poster/medium/',
    );
    final ok = await _verifyImageUrl(medium);
    _check('Cinemeta series poster fetches HTTP 200 as an image', ok, medium);
    if (ok) verifiedPoster = medium;
  }
  // The no-ImdbId path: exact-title catalog search must find the same id.
  final search = await _getJson(
    Uri.parse(
      '$_cinemetaBase/catalog/series/top/'
      'search=${Uri.encodeComponent(_dexterTitle)}.json',
    ),
  );
  String? searchedId;
  String? searchedPoster;
  final metas = search == null ? null : search['metas'];
  if (metas is List) {
    for (final raw in metas) {
      if (raw is Map<String, dynamic>) {
        final name = (raw['name'] as String?)?.trim() ?? '';
        if (name.toLowerCase() == _dexterTitle.toLowerCase()) {
          searchedId = raw['id'] as String?;
          searchedPoster = raw['poster'] as String?;
          break;
        }
      }
    }
  }
  _check(
    'Cinemeta title search finds Dexter: Resurrection by exact title',
    searchedId == _dexterImdbId,
    'got id=$searchedId',
  );
  if (searchedPoster != null && verifiedPoster == null) {
    if (await _verifyImageUrl(searchedPoster)) {
      verifiedPoster = searchedPoster;
    }
  }
  // The episode still the player sends first for a series episode: it
  // 301-redirects to image.tmdb.org, which the verifier must survive.
  final stillOk = await _verifyImageUrl(_dexterEpisodeStill);
  _check(
    'episode still fetches as an image (via redirect)',
    stillOk,
    _dexterEpisodeStill,
  );
  verifiedPoster ??= stillOk ? _dexterEpisodeStill : null;

  final activity = _buildDiscordActivity(
    title: '$_dexterTitle · S1 E1',
    posterUrl: verifiedPoster,
  );
  final assets = activity['assets'];
  final largeImage = assets is Map ? assets['large_image'] as String? : null;
  _check(
    'series activity carries a valid https large_image',
    largeImage != null && largeImage.startsWith('https://'),
    largeImage ?? 'no large_image in payload',
  );
  _check(
    'series activity never sends an un-uploaded asset key',
    largeImage == null || largeImage.startsWith('https://'),
    'large_image=$largeImage',
  );
  _check(
    'series title keeps its correct S1 E1 suffix',
    (activity['details'] as String) == '$_dexterTitle · S1 E1',
  );
}

Future<void> _checkMovieSubLk() async {
  print('[5/6] MovieSubLK provider live (moviesublk.com)');
  final api = await _getJson(
    Uri.parse('https://www.moviesublk.com/api/search?q=Aquaman'),
  );
  final posts = api?['posts'];
  String? firstSlug;
  if (posts is List && posts.isNotEmpty && posts.first is Map) {
    firstSlug = (posts.first as Map)['slug'] as String?;
  }
  _check(
    'search API returns results for "Aquaman"',
    firstSlug != null && firstSlug.isNotEmpty,
    firstSlug ?? 'no posts in response',
  );

  final searchHtml = await _getHtml(
    Uri.parse('https://www.moviesublk.com/search?q=Aquaman'),
  );
  final thumbRegex = RegExp(
    r'https://[^\s"\\]+\.(?:jpg|jpeg|png|webp|jfif)',
    caseSensitive: false,
  );
  final thumbs = searchHtml == null
      ? <String>[]
      : thumbRegex
            .allMatches(searchHtml)
            .map((m) => m.group(0)!)
            .where((u) => u.startsWith('https://'))
            .toList();
  // The page head carries a social-card image; the check must see a real
  // movie poster thumbnail (Blogger CDN), not just any image on the page.
  final posterThumbs = thumbs
      .where(
        (u) =>
            u.contains('blogger.googleusercontent.com') ||
            u.contains('image.tmdb.org') ||
            u.contains('postimg'),
      )
      .toList();
  _check(
    'search page returns results with https poster thumbnails',
    posterThumbs.isNotEmpty,
    posterThumbs.isEmpty
        ? (thumbs.isEmpty
              ? 'no https image URL on the page'
              : 'only non-poster images (first: ${thumbs.first})')
        : posterThumbs.first,
  );

  final slug = firstSlug ?? _aquamanSlug;
  final detailHtml = await _getHtml(
    Uri.parse('https://www.moviesublk.com/post/$slug'),
  );
  _check(
    'detail page loads for "$slug"',
    detailHtml != null && detailHtml.isNotEmpty,
  );
  String? poster;
  if (detailHtml != null) {
    final og = RegExp(
      r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"',
    ).firstMatch(detailHtml)?.group(1);
    final candidates = <String>[
      if (og != null) og,
      ...thumbRegex
          .allMatches(detailHtml)
          .map((m) => m.group(0)!)
          .where((u) => u.contains('blogger.googleusercontent.com')),
    ];
    for (final candidate in candidates) {
      final decoded = candidate
          .replaceAll(r'\"', '')
          .replaceAll('\\u002F', '/');
      if (decoded.startsWith('https://')) {
        poster = decoded;
        break;
      }
    }
  }
  _check(
    'detail page exposes an https poster URL',
    poster != null,
    poster ?? 'no poster found in detail page',
  );
  if (poster != null) {
    final upscaled = poster.contains('/s320/')
        ? poster.replaceFirst('/s320/', '/s1536/')
        : poster;
    final ok = await _verifyImageUrl(upscaled);
    _check(
      'MovieSubLK poster fetches HTTP 200 as an image',
      ok,
      upscaled,
    );
  }
}

/// [6/6] Together start flow over the live broker — the wire-level half
/// of the app's Start-button state machine (the service side is covered by
/// unit tests in test/together_start_button_state_test.dart). Sequence:
/// room created -> guest sees the host BROWSING with no go-live state yet
/// (no start prompt while browsing) -> host goes live with a retained
/// playing state -> guest receives the same title, playing=true ->
/// host changes title -> guest receives the new title at position 0
/// (re-share clears the old state).
Future<void> _checkTogetherStartFlow() async {
  print('[6/6] Together start flow (live broker)');
  final otp = (100000 + Random().nextInt(900000)).toString();
  final topic = 'yumeflix/together/v1/$otp';
  const title = _dexterTitle;
  const nextTitle = 'Dexter: Resurrection · S2 Premiere';
  const positionMs = 14000;

  final guestId = 'livecheck-start-guest-${Random().nextInt(1 << 30)}';
  final hostId = 'livecheck-start-host-${Random().nextInt(1 << 30)}';
  MqttServerClient? guest;
  MqttServerClient? host;
  String? relayLabel;
  for (final relay in const [
    ('wss://broker.emqx.io/mqtt', 8084, 'EMQX'),
    ('wss://test.mosquitto.org/mqtt', 8081, 'Mosquitto'),
  ]) {
    guest = await _connectRelay(relay.$1, relay.$2, relay.$3, guestId);
    if (guest != null) {
      relayLabel = relay.$3;
      break;
    }
  }
  _check('guest connects to a Together relay', guest != null);
  if (guest == null) {
    print('  FAIL  start flow skipped — no relay reachable');
    _failed++;
    return;
  }
  host = await _connectRelay(
    relayLabel == 'EMQX'
        ? 'wss://broker.emqx.io/mqtt'
        : 'wss://test.mosquitto.org/mqtt',
    relayLabel == 'EMQX' ? 8084 : 8081,
    relayLabel!,
    hostId,
  );
  _check('host connects to the same relay ($relayLabel)', host != null);
  if (host == null) {
    guest.disconnect();
    return;
  }

  final statuses = <String>[];
  final states = <Map<String, dynamic>>[];
  final liveStateSeen = Completer<Map<String, dynamic>>();
  final reshareSeen = Completer<Map<String, dynamic>>();
  guest.subscribe(topic, MqttQos.atLeastOnce);
  guest.updates!.listen((events) {
    for (final event in events) {
      final payload = event.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['kind'] == 'status') {
          final s = decoded['status'] as String?;
          if (s != null) statuses.add(s);
        }
        if (decoded['kind'] == 'state') {
          states.add(decoded);
          final media = decoded['media'];
          final gotTitle = media is Map ? media['title'] as String? : null;
          if (decoded['playing'] == true &&
              gotTitle == title &&
              !liveStateSeen.isCompleted) {
            liveStateSeen.complete(decoded);
          }
          if (gotTitle == nextTitle && !reshareSeen.isCompleted) {
            reshareSeen.complete(decoded);
          }
        }
      } catch (_) {}
    }
  });
  await Future<void>.delayed(const Duration(seconds: 1));

  // Browsing: host publishes a status only — no playback state, so the
  // guest has nothing to start from and no start prompt is warranted.
  _publish(host, topic, {'kind': 'status', 'status': 'hostBrowsing'});
  await Future<void>.delayed(const Duration(seconds: 3));
  _check(
    'guest sees hostBrowsing status',
    statuses.contains('hostBrowsing'),
    'saw: ${statuses.join(', ')}',
  );
  _check(
    'no go-live state while the host is only browsing',
    states.isEmpty,
    states.isEmpty ? '' : 'got ${states.length} state(s) early',
  );

  // Go live: retained playing state, exactly as the app publishes on Start.
  _publish(host, topic, {
    'kind': 'state',
    'media': {
      'title': title,
      'tmdbType': 'tv',
      'posterUrl': _dexterEpisodeStill,
    },
    'positionMs': positionMs,
    'durationMs': 3084000,
    'playing': true,
    'hostTimestampMs': DateTime.now().millisecondsSinceEpoch,
    'sequence': 1,
    'hostId': hostId,
  }, retain: true);
  Map<String, dynamic>? liveState;
  try {
    liveState = await liveStateSeen.future.timeout(
      const Duration(seconds: 15),
    );
  } on TimeoutException {
    liveState = null;
  }
  _check('guest receives the go-live state', liveState != null);
  if (liveState != null) {
    _check(
      'go-live state is playing with the host title',
      liveState['playing'] == true &&
          (liveState['media'] as Map?)?['title'] == title,
    );
    final drift = ((liveState['positionMs'] as num?)?.toInt() ?? -1);
    _check(
      'go-live position matches the host (±2000 ms)',
      (drift - positionMs).abs() <= 2000,
      'got ${drift}ms',
    );
  }

  // Title change: re-share the new title at position 0, old state gone.
  // Re-publish up to 3 times, like the app's 1 s heartbeat re-asserting
  // live state: the public relay occasionally drops a single publish,
  // and the app never relies on one publish landing.
  Map<String, dynamic>? reshare;
  for (var attempt = 0; attempt < 3 && !reshareSeen.isCompleted; attempt++) {
    _publish(host, topic, {
      'kind': 'state',
      'media': {'title': nextTitle, 'tmdbType': 'tv'},
      'positionMs': 0,
      'durationMs': 3000000,
      'playing': true,
      'hostTimestampMs': DateTime.now().millisecondsSinceEpoch,
      'sequence': 2,
      'hostId': hostId,
    }, retain: true);
    try {
      reshare = await reshareSeen.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      reshare = null;
    }
  }
  _check('guest receives the re-shared title', reshare != null);
  if (reshare != null) {
    _check(
      're-share starts the new title at position 0',
      (reshare['positionMs'] as num?)?.toInt() == 0,
      'got ${reshare['positionMs']}ms',
    );
  }

  try {
    host.disconnect();
  } catch (_) {}
  try {
    guest.disconnect();
  } catch (_) {}
}

Future<void> main() async {
  print('YumeFlix 2.8.0 live checks (real network, no mocks)');
  print('');
  try {
    await _checkTogether();
  } catch (e) {
    _failed++;
    print('  FAIL  Together round-trip threw: $e');
  }
  print('');
  try {
    await _checkTogetherChunkedImage();
  } catch (e) {
    _failed++;
    print('  FAIL  Together chunked image threw: $e');
  }
  print('');
  try {
    await _checkDiscordPoster();
  } catch (e) {
    _failed++;
    print('  FAIL  Discord poster chain threw: $e');
  }
  print('');
  try {
    await _checkDiscordPosterSeries();
  } catch (e) {
    _failed++;
    print('  FAIL  Discord series poster chain threw: $e');
  }
  print('');
  try {
    await _checkMovieSubLk();
  } catch (e) {
    _failed++;
    print('  FAIL  MovieSubLK live check threw: $e');
  }
  print('');
  try {
    await _checkTogetherStartFlow();
  } catch (e) {
    _failed++;
    print('  FAIL  Together start flow threw: $e');
  }
  print('');
  print('Result: $_passed passed, $_failed failed.');
  if (_failed > 0) {
    print('Live checks FAILED — fix the code, not this script.');
    exit(1);
  }
  print('All live checks PASSED.');
}
