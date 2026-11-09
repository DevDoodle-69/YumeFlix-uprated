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
//   2. Discord poster chain for "Harry Potter and the Deathly Hallows:
//      Part 2" (IMDb tt1201607): keyless Cinemeta lookup returns a poster
//      URL, and that URL (plus the metahub extension poster) really
//      fetches HTTP 200 as an image. The built Gateway activity payload
//      must then carry a valid https `large_image` — and never a dead
//      asset key (the 2.6.0 black-circle cause).
//   3. MovieSubLK provider live: a real search for "Aquaman" returns
//      results with https thumbnails, and a real detail fetch returns an
//      https poster that fetches HTTP 200 as an image.
//   4. Discord poster chain for a SERIES, "Dexter: Resurrection" (IMDb
//      tt33043892): the keyless Cinemeta lookup works by series id AND by
//      exact title search (the no-ImdbId path), the episode still and the
//      poster fetch as images, and the built activity carries a valid
//      https `large_image` with the correct "S1 E1" series title.
//   5. Together start flow over the live broker: room created, guest sees
//      the host browsing with NO go-live state yet, then the host going
//      live publishes a retained playing state the guest receives, and a
//      title change re-shares the new title at position 0. (2.9.0: the
//      go-live title shape is checked too — a movie's state carries the
//      bare title with no `S{n} E{n}` suffix and no episode label, while a
//      series episode's state carries the exact `· S1 E1` title and label,
//      so the guest opens the same title the host started.)
//
//   6. In-app updates (2.11.0, `_checkLatestRelease`): the public latest-
//      release API answers, its tag parses as a plain release version, and
//      it carries a universal APK asset (the exact
//      `yumeflix-android-universal-vX.Y.Z.apk` name, or any `.apk` with
//      "universal" in the name) whose download URL answers. A release with
//      only split APKs would fail this check — the app never offers those.
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
  final movieStateSeen = Completer<Map<String, dynamic>>();
  final episodeStateSeen = Completer<Map<String, dynamic>>();
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
          // 2.9.0 title-shape checks: a movie go-live carries the bare
          // title (no S/E suffix, no episode label); a series go-live
          // carries the exact episode title and label.
          if (decoded['playing'] == true &&
              gotTitle == 'Dune' &&
              !movieStateSeen.isCompleted) {
            movieStateSeen.complete(decoded);
          }
          if (gotTitle == 'Dexter: Resurrection · S1 E1' &&
              !episodeStateSeen.isCompleted) {
            episodeStateSeen.complete(decoded);
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

  // 2.9.0 title shape on go-live: the exact payloads the app publishes
  // when the host presses Start on a movie and on a series episode.
  // The movie's title must be bare — a dummy S1 E1 must never leak onto
  // it — and the episode's title must carry the exact S/E.
  // `host` is non-null here (the null case returned above), but a local
  // function cannot see that promotion — bind it once, then close over it.
  final MqttServerClient liveHost = host;
  Future<Map<String, dynamic>?> waitForState(
    Completer<Map<String, dynamic>> seen,
    Map<String, dynamic> payload,
  ) async {
    for (var attempt = 0; attempt < 3 && !seen.isCompleted; attempt++) {
      _publish(liveHost, topic, payload, retain: true);
      try {
        return await seen.future.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        // The public relay occasionally drops a single publish; retry.
      }
    }
    return seen.isCompleted ? await seen.future : null;
  }

  final movieState = await waitForState(movieStateSeen, {
    'kind': 'state',
    'media': {'title': 'Dune', 'tmdbType': 'movie'},
    'positionMs': 5000,
    'durationMs': 600000,
    'playing': true,
    'hostTimestampMs': DateTime.now().millisecondsSinceEpoch,
    'sequence': 3,
    'hostId': hostId,
  });
  _check('guest receives the movie go-live state', movieState != null);
  if (movieState != null) {
    final movieMedia = movieState['media'];
    final movieTitle = movieMedia is Map
        ? movieMedia['title'] as String?
        : null;
    _check(
      'movie go-live title is bare — no S/E suffix, no episode label',
      movieTitle == 'Dune' &&
          (movieMedia is Map
              ? movieMedia['episodeLabel'] == null
              : false),
      'got "$movieTitle"',
    );
  }

  final episodeState = await waitForState(episodeStateSeen, {
    'kind': 'state',
    'media': {
      'title': 'Dexter: Resurrection · S1 E1',
      'tmdbType': 'tv',
      'episodeLabel': 'S1 E1',
    },
    'positionMs': 14000,
    'durationMs': 3084000,
    'playing': true,
    'hostTimestampMs': DateTime.now().millisecondsSinceEpoch,
    'sequence': 4,
    'hostId': hostId,
  });
  _check('guest receives the episode go-live state', episodeState != null);
  if (episodeState != null) {
    final episodeMedia = episodeState['media'];
    _check(
      'episode go-live title carries the exact S/E',
      episodeMedia is Map &&
          episodeMedia['title'] == 'Dexter: Resurrection · S1 E1' &&
          episodeMedia['episodeLabel'] == 'S1 E1',
      'got "${episodeMedia is Map ? episodeMedia['title'] : null}"',
    );
  }

  try {
    host.disconnect();
  } catch (_) {}
  try {
    guest.disconnect();
  } catch (_) {}
}

/// [7/7] In-app updates (2.11.0) — the source the app checks itself.
/// Mirrors the selection in lib/features/update/update_models.dart:
/// plain release tag (no pre-release suffix) + a universal APK asset.
/// Only the asset's URL is fetched (HEAD), never the ~120 MB file.
Future<void> _checkLatestRelease() async {
  print('[7] In-app update source — latest GitHub release');
  final json = await _getJson(
    Uri.parse(
      'https://api.github.com/repos/DevDoodle-69/YumeFlix-uprated/releases/latest',
    ),
  );
  _check('latest-release API answers with JSON', json != null);
  if (json == null) return;
  final tag = (json['tag_name'] as String?) ?? '';
  final plain = RegExp(r'^v?\d+\.\d+\.\d+$').hasMatch(tag);
  _check(
    'latest tag parses as a plain release version',
    plain,
    'got "$tag"',
  );
  _check('latest release is not a pre-release', json['prerelease'] != true);
  _check('latest release is not a draft', json['draft'] != true);
  final assets = json['assets'];
  Map<String, dynamic>? universal;
  if (assets is List) {
    final exact = RegExp(
      r'^yumeflix-android-universal-v[\d.]+\.apk$',
      caseSensitive: false,
    );
    for (final raw in assets) {
      if (raw is Map<String, dynamic>) {
        final name = (raw['name'] as String?) ?? '';
        if (exact.hasMatch(name)) {
          universal = raw;
          break;
        }
      }
    }
    universal ??= () {
      for (final raw in assets) {
        if (raw is Map<String, dynamic>) {
          final name = ((raw['name'] as String?) ?? '').toLowerCase();
          if (name.endsWith('.apk') && name.contains('universal')) {
            return raw;
          }
        }
      }
      return null;
    }();
  }
  _check(
    'latest release carries a universal APK asset',
    universal != null,
    universal == null
        ? 'assets: ${(assets is List ? assets.map((a) => a is Map ? a['name'] : '?').join(', ') : 'none')}'
        : universal['name'] as String? ?? '',
  );
  if (universal != null) {
    final url = universal['browser_download_url'] as String?;
    final size = universal['size'];
    _check(
      'universal asset has a download URL and a plausible size',
      url != null &&
          url.startsWith('https://') &&
          size is num &&
          size > 50 * 1024 * 1024,
      'size=${size is num ? (size / (1024 * 1024)).toStringAsFixed(0) : size} MB',
    );
    if (url != null) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final head = await client.headUrl(Uri.parse(url));
        head.headers.set('User-Agent', 'YumeFlix-live-check/2.11.0');
        final response = await head.close().timeout(
          const Duration(seconds: 30),
        );
        await response.drain<void>();
        _check(
          'universal APK URL answers (HEAD 200/302)',
          response.statusCode == 200 || response.statusCode == 302,
          'HTTP ${response.statusCode}',
        );
      } catch (e) {
        _check('universal APK URL answers (HEAD 200/302)', false, '$e');
      } finally {
        client.close();
      }
    }
  }
}

/// [8/8] Together guest auto-open (2.11.0) — the go-live payload a guest
/// resolves from, the presence payload carrying the guest's typed name,
/// and the room-full protocol a 6th guest receives.
///
/// Like [6/6], this checks the wire format with synthetic publishes
/// through raw clients: the app's enforcement (the 5-guest cap counting,
/// name validation, auto-open navigation, same-source resolution) is
/// covered by flutter test — what the live broker proves here is that
/// every field the guest needs survives the relay intact.
Future<void> _checkTogetherGuestAutoOpen() async {
  print('[8/8] Together guest auto-open payloads (live broker)');
  final otp = (100000 + Random().nextInt(900000)).toString();
  final topic = 'yumeflix/together/v1/$otp';
  final guestId =
      'livecheck-autoopen-guest-${Random().nextInt(1 << 30)}';
  final hostId = 'livecheck-autoopen-host-${Random().nextInt(1 << 30)}';
  final sixthId = 'livecheck-autoopen-sixth-${Random().nextInt(1 << 30)}';
  MqttServerClient? guest;
  MqttServerClient? host;
  MqttServerClient? sixth;
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
    print('  FAIL  guest auto-open skipped — no relay reachable');
    _failed++;
    return;
  }
  final relayUrl = relayLabel == 'EMQX'
      ? 'wss://broker.emqx.io/mqtt'
      : 'wss://test.mosquitto.org/mqtt';
  final relayPort = relayLabel == 'EMQX' ? 8084 : 8081;
  host = await _connectRelay(relayUrl, relayPort, relayLabel!, hostId);
  _check('host connects to the same relay ($relayLabel)', host != null);
  if (host == null) {
    guest.disconnect();
    return;
  }
  sixth = await _connectRelay(relayUrl, relayPort, relayLabel, sixthId);
  _check('6th guest connects to the same relay ($relayLabel)', sixth != null);
  if (sixth == null) {
    host.disconnect();
    guest.disconnect();
    return;
  }

  final liveStateSeen = Completer<Map<String, dynamic>>();
  final presenceSeen = Completer<Map<String, dynamic>>();
  final roomFullSeen = Completer<Map<String, dynamic>>();
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
        if (decoded['kind'] == 'state' &&
            decoded['playing'] == true &&
            !liveStateSeen.isCompleted) {
          liveStateSeen.complete(decoded);
        }
      } catch (_) {}
    }
  });
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
        if (decoded['kind'] == 'presence' &&
            decoded['senderId'] == guestId &&
            !presenceSeen.isCompleted) {
          presenceSeen.complete(decoded);
        }
      } catch (_) {}
    }
  });
  sixth.subscribe(topic, MqttQos.atLeastOnce);
  sixth.updates!.listen((events) {
    for (final event in events) {
      final payload = event.payload as MqttPublishMessage;
      final text = MqttPublishPayload.bytesToStringAsString(
        payload.payload.message,
      );
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['kind'] == 'room-full' &&
            decoded['targetId'] == sixthId &&
            !roomFullSeen.isCompleted) {
          roomFullSeen.complete(decoded);
        }
      } catch (_) {}
    }
  });
  await Future<void>.delayed(const Duration(seconds: 1));

  // Presence: the guest announces itself with its role and the name it
  // typed — the host learns who is in the room from this, not from a
  // device name.
  _publish(guest, topic, {
    'kind': 'presence',
    'senderId': guestId,
    'role': 'guest',
    'displayName': 'Aisha',
  });
  Map<String, dynamic>? presence;
  try {
    presence = await presenceSeen.future.timeout(
      const Duration(seconds: 15),
    );
  } on TimeoutException {
    presence = null;
  }
  _check('host receives the guest presence', presence != null);
  if (presence != null) {
    _check(
      'presence carries the guest role and typed name',
      presence['role'] == 'guest' && presence['displayName'] == 'Aisha',
      'got role=${presence['role']} name=${presence['displayName']}',
    );
  }

  // Go live: the full 2.11.0 identity — everything the guest needs to
  // open the SAME title on the SAME source, with no extra round trip.
  _publish(host, topic, {
    'kind': 'state',
    'media': {
      'title': 'Dexter: Resurrection · S1 E1',
      'tmdbType': 'tv',
      'tmdbId': 234876,
      'posterUrl': _dexterEpisodeStill,
      'episodeLabel': 'S1 E1',
      'season': 1,
      'episode': 1,
      'provider': 'MovieSubLK',
      'itemUrl': 'https://example.invalid/dexter-resurrection',
      'episodeUrl': 'https://example.invalid/dexter-resurrection-s1-e1',
      'source': 'Server 1',
    },
    'positionMs': 14000,
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
    final media = liveState['media'];
    _check(
      'go-live media carries provider + source + episode URL',
      media is Map &&
          media['provider'] == 'MovieSubLK' &&
          media['source'] == 'Server 1' &&
          media['episodeUrl'] ==
              'https://example.invalid/dexter-resurrection-s1-e1',
      'got ${media is Map ? media.keys.join(', ') : media}',
    );
    _check(
      'go-live media carries season + episode + TMDB id',
      media is Map &&
          media['season'] == 1 &&
          media['episode'] == 1 &&
          media['tmdbId'] == 234876,
      'got season=${media is Map ? media['season'] : null} '
      'episode=${media is Map ? media['episode'] : null} '
      'tmdbId=${media is Map ? media['tmdbId'] : null}',
    );
  }

  // Room full: the host answers a 6th joiner with a targeted room-full
  // event naming that phone — only that phone acts on it.
  _publish(host, topic, {
    'kind': 'room-full',
    'targetId': sixthId,
    'message': 'This room is full — the host already has 5 guests.',
  });
  Map<String, dynamic>? roomFull;
  try {
    roomFull = await roomFullSeen.future.timeout(
      const Duration(seconds: 15),
    );
  } on TimeoutException {
    roomFull = null;
  }
  _check('6th guest receives the room-full event', roomFull != null);
  if (roomFull != null) {
    _check(
      'room-full names the 6th guest and carries the honest message',
      roomFull['targetId'] == sixthId &&
          (roomFull['message'] as String?)?.contains('full') == true,
      'got ${roomFull['message']}',
    );
  }

  try {
    host.disconnect();
  } catch (_) {}
  try {
    guest.disconnect();
  } catch (_) {}
  try {
    sixth.disconnect();
  } catch (_) {}
}

Future<void> main() async {
  print('YumeFlix 2.9.0 live checks (real network, no mocks)');
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
  try {
    await _checkLatestRelease();
  } catch (e) {
    _failed++;
    print('  FAIL  Latest-release check threw: $e');
  }
  print('');
  try {
    await _checkTogetherGuestAutoOpen();
  } catch (e) {
    _failed++;
    print('  FAIL  Together guest auto-open threw: $e');
  }
  print('');
  print('Result: $_passed passed, $_failed failed.');
  if (_failed > 0) {
    print('Live checks FAILED — fix the code, not this script.');
    exit(1);
  }
  print('All live checks PASSED.');
}
