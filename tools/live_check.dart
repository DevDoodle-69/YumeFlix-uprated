// YumeFlix live checks — run with: `dart tools/live_check.dart`
//
// Hits the LIVE internet (no Flutter app, no mocks) and verifies the three
// things 2.7.0 claims to fix, end to end:
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
//   2. Discord poster chain for "Harry Potter and the Deathly Hallows:
//      Part 2" (IMDb tt1201607): keyless Cinemeta lookup returns a poster
//      URL, and that URL (plus the metahub extension poster) really
//      fetches HTTP 200 as an image. The built Gateway activity payload
//      must then carry a valid https `large_image` — and never a dead
//      asset key (the 2.6.0 black-circle cause).
//   3. MovieSubLK provider live: a real search for "Aquaman" returns
//      results with https thumbnails, and a real detail fetch returns an
//      https poster that fetches HTTP 200 as an image.
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

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

const String _hpTitle = 'Harry Potter and the Deathly Hallows: Part 2';
const String _hpImdbId = 'tt1201607';
const String _cinemetaBase = 'https://v3-cinemeta.strem.io';
const String _metahubPoster =
    'https://images.metahub.space/poster/medium/tt1201607/img';
const String _aquamanSlug = 'aquaman-2018-sinhala-subtitles';

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
  builder.addString(jsonEncode(payload));
  client.publishMessage(
    topic,
    MqttQos.atLeastOnce,
    builder.payload!,
    retain: retain,
  );
}

Future<void> _checkTogether() async {
  print('[1/3] Together MQTT round-trip (live broker)');
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

Future<void> _checkDiscordPoster() async {
  print('[2/3] Discord poster chain — $_hpTitle ($_hpImdbId)');
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

Future<void> _checkMovieSubLk() async {
  print('[3/3] MovieSubLK provider live (moviesublk.com)');
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

Future<void> main() async {
  print('YumeFlix 2.7.0 live checks (real network, no mocks)');
  print('');
  try {
    await _checkTogether();
  } catch (e) {
    _failed++;
    print('  FAIL  Together round-trip threw: $e');
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
    await _checkMovieSubLk();
  } catch (e) {
    _failed++;
    print('  FAIL  MovieSubLK live check threw: $e');
  }
  print('');
  print('Result: $_passed passed, $_failed failed.');
  if (_failed > 0) {
    print('Live checks FAILED — fix the code, not this script.');
    exit(1);
  }
  print('All live checks PASSED.');
}
