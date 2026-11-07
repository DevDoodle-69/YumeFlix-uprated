import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config/tmdb_config.dart';
import 'discord_artwork_resolver.dart';

/// Connection state for the Discord account configured in YumeFlix.
enum DiscordConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  invalidToken,
}

/// The account identity returned by Discord's Gateway READY event.
@immutable
class DiscordAccountProfile {
  const DiscordAccountProfile({
    required this.id,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
  });

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;

  factory DiscordAccountProfile.fromGateway(Map<String, dynamic> user) {
    final id = user['id']?.toString() ?? '';
    final username = (user['username'] as String?)?.trim() ?? '';
    final globalName = (user['global_name'] as String?)?.trim();
    final avatarHash = (user['avatar'] as String?)?.trim();

    String? avatarUrl;
    if (id.isNotEmpty && avatarHash != null && avatarHash.isNotEmpty) {
      final extension = avatarHash.startsWith('a_') ? 'gif' : 'png';
      avatarUrl =
          'https://cdn.discordapp.com/avatars/$id/$avatarHash.$extension?size=128';
    } else if (id.isNotEmpty) {
      final userId = BigInt.tryParse(id) ?? BigInt.zero;
      final defaultAvatarIndex = ((userId >> 22) % BigInt.from(6)).toInt();
      avatarUrl =
          'https://cdn.discordapp.com/embed/avatars/$defaultAvatarIndex.png';
    }

    return DiscordAccountProfile(
      id: id,
      username: username.isEmpty ? 'Discord user' : username,
      displayName: globalName == null || globalName.isEmpty
          ? (username.isEmpty ? 'Discord user' : username)
          : globalName,
      avatarUrl: avatarUrl,
    );
  }
}

/// Discord Gateway Rich Presence client for Android and desktop.
///
/// Playback metadata is held here so player screens never own the socket.
/// Gateway presence is not published until the connection has completed its
/// READY handshake; the most recent playback state is then sent immediately.
class DiscordPresenceService extends ChangeNotifier {
  DiscordPresenceService._();
  static final DiscordPresenceService instance = DiscordPresenceService._();

  /// Discord application that owns the YumeFlix Rich Presence activity.
  /// External media-proxy artwork is resolved in the context of this app.
  static const String applicationId = '1322319281819488256';

  // NOTE (2.7.0): there used to be a `discordLargeImageKey = 'yumeflix_logo'`
  // constant here, sent as large_image whenever no poster was available and
  // as small_image beside every poster. It was removed on purpose: the key
  // appears nowhere else in the repo — no uploaded-asset record, no asset
  // file — and an asset key Discord has never been given renders as a black
  // circle, which is exactly the symptom users reported on every movie.
  // Until a Rich Presence asset is actually uploaded under this application
  // id and its key verified, NO asset key is ever sent: no verified poster
  // means no `assets` object at all, and a verified poster is sent on its
  // own, with no small image. See [buildActivity].

  WebSocket? _socket;
  Timer? _heartbeat;
  Timer? _firstHeartbeat;
  Timer? _reconnect;
  String? _token;
  int? _sequence;
  bool _connecting = false;
  bool _enabled = false;
  bool _closed = false;
  bool _ready = false;
  bool _awaitingHeartbeatAck = false;
  bool _invalidToken = false;
  String? _title;
  String? _state;
  String? _posterUrl;
  String? _extensionPosterUrl;
  String? _tmdbPosterUrl;
  String? _cinemetaPosterUrl;
  String? _imdbId;
  String? _artworkLookupKey;
  final DiscordArtworkResolver _artworkResolver = DiscordArtworkResolver();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  DiscordAccountProfile? _profile;
  DiscordConnectionState _connectionState = DiscordConnectionState.disconnected;
  String? _lastSentSignature;
  DateTime? _lastSentAt;
  Duration? _lastSentPosition;
  Duration? _lastSentDuration;
  bool _lastSentPlaying = false;

  /// Diagnostics for Settings → Discord: what the last Gateway op-3
  /// actually carried, so the cover can be checked on-device instead of
  /// guessed from code. Null until the first presence update is sent.
  String? _lastSentLargeImage;
  String? _lastSentTitle;

  /// Where the last sent cover came from: 'tmdb', 'extension', 'cinemeta',
  /// or 'none' when the activity was sent with no image at all.
  String _lastPosterSource = 'none';

  /// Human-readable outcome of the last artwork resolution attempt, e.g.
  /// which candidate failed verification and what was used instead.
  String? _lastArtworkNote;

  /// Guards [_refreshVerifiedPoster]: a run already in flight defers the
  /// next request instead of stacking parallel HEAD/GET verifications.
  bool _verifyingPoster = false;
  bool _verifyPosterPending = false;

  bool get enabled => _enabled;
  bool get isConnected => _connectionState == DiscordConnectionState.connected;
  DiscordConnectionState get connectionState => _connectionState;
  DiscordAccountProfile? get profile => _profile;

  /// Exact `large_image` value carried by the last presence update sent to
  /// Discord, or null when the last update carried no image. This is the
  /// ground truth for the Settings → Discord diagnostics row.
  String? get lastSentLargeImage => _lastSentLargeImage;

  /// Title carried by the last presence update sent, or null if none sent.
  String? get lastSentTitle => _lastSentTitle;

  /// When the last presence update was sent, or null if none sent.
  DateTime? get lastSentAt => _lastSentAt;

  /// Source of the last sent cover: 'tmdb', 'extension', 'cinemeta', 'none'.
  String get lastPosterSource => _lastPosterSource;

  /// Outcome of the last artwork resolution attempt, or null before the
  /// first attempt.
  String? get lastArtworkNote => _lastArtworkNote;

  /// The currently verified poster that will be (or was) sent as
  /// `large_image`, or null when no candidate has verified yet.
  String? get currentPosterUrl => _posterUrl;

  /// Configures the existing token-based connection without ever logging or
  /// exposing the token to the UI. An invalid token stops retries until the
  /// user saves the integration settings again.
  Future<void> configure({required bool enabled, required String token}) async {
    final normalizedToken = token.trim();
    final shouldEnable = enabled && normalizedToken.isNotEmpty;
    final tokenChanged = normalizedToken != _token;

    if (!shouldEnable) {
      _enabled = false;
      _token = normalizedToken.isEmpty ? null : normalizedToken;
      if (_ready) await _sendClearedActivity();
      await disconnect();
      return;
    }

    if (tokenChanged && _socket != null) {
      await disconnect();
    }
    _token = normalizedToken;
    _enabled = true;
    _closed = false;
    _invalidToken = false;
    if (_socket == null) await _connect();
  }

  Future<void> updateWatching({
    required String title,
    String? state,
    String? posterUrl,
    required String tmdbSearchTitle,
    required String tmdbMediaType,
    int? tmdbId,
    String? imdbId,
    required Duration position,
    required Duration duration,
    required bool playing,
  }) async {
    _title = title;
    _state = state;
    _extensionPosterUrl = normalizePosterUrl(posterUrl);
    _imdbId = imdbId?.trim().isEmpty == true ? null : imdbId?.trim();
    final searchTitle = tmdbSearchTitle.trim().isEmpty
        ? title.trim()
        : tmdbSearchTitle.trim();
    final mediaType = tmdbMediaType.trim().toLowerCase() == 'tv'
        ? 'tv'
        : 'movie';
    final keyFingerprint = TmdbConfig.apiKey.hashCode.toRadixString(16);
    // The lookup key covers everything that can change the cover: a new
    // title/id, a different extension poster, or a different IMDb id for the
    // keyless Cinemeta fallback. Playback ticks reuse the same key and so
    // never re-verify or re-fetch artwork.
    final lookupKey =
        '$mediaType|id:${tmdbId ?? 0}|imdb:${_imdbId ?? ''}|ext:${_extensionPosterUrl ?? ''}|${searchTitle.toLowerCase()}|$keyFingerprint';
    final lookupChanged = lookupKey != _artworkLookupKey;
    if (lookupChanged) {
      _artworkLookupKey = lookupKey;
      _tmdbPosterUrl = null;
      _cinemetaPosterUrl = null;
      // The previously verified poster belongs to the previous item: drop
      // it now so the next presence update cannot carry a stale cover while
      // the new candidates are being verified.
      _posterUrl = null;
      _lastPosterSource = 'none';
      _lastArtworkNote = 'Checking artwork…';
      _lastSentSignature = null;
    }
    // The extension knows the exact artwork for the item it resolved, but
    // Discord's media proxy does not fetch every host the app itself can
    // load. A TMDB poster (image.tmdb.org) is the one host the proxy
    // reliably serves, so it outranks an extension poster from any other
    // host; the extension URL still wins when it already lives on
    // image.tmdb.org or when TMDB has nothing for this title. Nothing is
    // sent as the cover until it has been fetch-verified — see
    // [_refreshVerifiedPoster] — so [_posterUrl] stays null here and the
    // presence goes out imageless first, then again with the cover once a
    // candidate verifies.
    _position = position < Duration.zero ? Duration.zero : position;
    _duration = duration < Duration.zero ? Duration.zero : duration;
    _playing = playing;

    if (lookupChanged) {
      unawaited(
        _resolveArtwork(
          lookupKey: lookupKey,
          title: searchTitle,
          mediaType: mediaType,
          tmdbId: tmdbId,
        ),
      );
      unawaited(_refreshVerifiedPoster(lookupKey: lookupKey));
    }
    if (_enabled && _ready) await _sendPresence();
  }

  Future<void> _resolveArtwork({
    required String lookupKey,
    required String title,
    required String mediaType,
    int? tmdbId,
  }) async {
    final poster = await _artworkResolver.resolve(
      title: title,
      mediaType: mediaType,
      tmdbId: tmdbId,
    );
    if (_artworkLookupKey != lookupKey) return;

    _tmdbPosterUrl = normalizePosterUrl(poster);
    // A TMDB poster that arrived late outranks an already-verified
    // extension poster, so re-run verification instead of keeping the
    // extension URL unconditionally.
    unawaited(_refreshVerifiedPoster(lookupKey: lookupKey));
  }

  /// Picks the first fetch-verified poster, in priority order, and
  /// re-publishes the presence with it.
  ///
  /// Priority: TMDB poster (image.tmdb.org, the host Discord's media proxy
  /// serves most reliably) → extension poster → keyless Cinemeta poster
  /// (only fetched when neither of the first two verified, and only when
  /// the item carries an IMDb id). A candidate that fails verification
  /// (non-200, non-image, unreachable) never blocks the next one, and when
  /// nothing verifies the activity is re-sent with no image at all — never
  /// with a dead asset key.
  ///
  /// Runs only when the artwork lookup changes (or a late TMDB result
  /// arrives), never per playback tick: verification results are cached in
  /// the resolver. Concurrent calls collapse into one run plus a single
  /// deferred re-run.
  Future<void> _refreshVerifiedPoster({required String lookupKey}) async {
    if (_verifyingPoster) {
      _verifyPosterPending = true;
      return;
    }
    _verifyingPoster = true;
    try {
      // Re-check the lookup key at every await boundary: the user may have
      // started a different title while verification was in flight.
      if (_artworkLookupKey != lookupKey) return;
      final mediaType = lookupKey.split('|').first;
      final candidates = <({String url, String source})>[
        if (_tmdbPosterUrl != null)
          (url: _tmdbPosterUrl!, source: 'tmdb'),
        if (_extensionPosterUrl != null)
          (url: _extensionPosterUrl!, source: 'extension'),
      ];
      // De-duplicate: the extension poster and the TMDB poster are often
      // the same image.tmdb.org URL, and verifying it twice is pure waste.
      final seen = <String>{};
      final deduped = candidates.where((c) => seen.add(c.url)).toList();

      String? verified;
      String? verifiedSource;
      final failed = <String>[];
      for (final candidate in deduped) {
        if (_artworkLookupKey != lookupKey) return;
        if (await _artworkResolver.verifyPosterUrl(candidate.url)) {
          verified = candidate.url;
          verifiedSource = candidate.source;
          break;
        }
        failed.add('${candidate.source} poster did not verify');
      }

      // Keyless fallback, only when the first two sources had nothing
      // verified and the item carries an IMDb id. Cinemeta needs no key,
      // which matters because the shipped TMDB key is unset (see
      // [DiscordArtworkResolver.resolveKeyless]).
      if (verified == null && _artworkLookupKey == lookupKey) {
        final cinemeta = _cinemetaPosterUrl ??
            await _artworkResolver.resolveKeyless(
              imdbId: _imdbId,
              mediaType: mediaType,
            );
        if (_artworkLookupKey != lookupKey) return;
        _cinemetaPosterUrl = normalizePosterUrl(cinemeta);
        final cinemetaUrl = _cinemetaPosterUrl;
        if (cinemetaUrl != null &&
            !seen.contains(cinemetaUrl) &&
            await _artworkResolver.verifyPosterUrl(cinemetaUrl)) {
          verified = cinemetaUrl;
          verifiedSource = 'cinemeta';
        } else if (cinemetaUrl != null) {
          failed.add('cinemeta poster did not verify');
        }
      }

      if (_artworkLookupKey != lookupKey) return;
      final changed = _posterUrl != verified;
      _posterUrl = verified;
      _lastPosterSource = verifiedSource ?? 'none';
      _lastArtworkNote = verified == null
          ? (failed.isEmpty
                ? 'No poster available — activity sent without a cover.'
                : '${failed.join('; ')} — activity sent without a cover.')
          : 'Cover verified (${verifiedSource ?? 'unknown'}).';
      if (changed) _lastSentSignature = null;
      notifyListeners();
      if (changed &&
          _enabled &&
          _ready &&
          _title?.trim().isNotEmpty == true) {
        await _sendPresence(force: true);
      }
    } finally {
      _verifyingPoster = false;
      if (_verifyPosterPending) {
        _verifyPosterPending = false;
        final key = _artworkLookupKey;
        if (key != null) unawaited(_refreshVerifiedPoster(lookupKey: key));
      }
    }
  }

  Future<void> clearActivity() async {
    _title = null;
    _state = null;
    _posterUrl = null;
    _extensionPosterUrl = null;
    _tmdbPosterUrl = null;
    _cinemetaPosterUrl = null;
    _imdbId = null;
    _artworkLookupKey = null;
    _lastPosterSource = 'none';
    _lastArtworkNote = null;
    _lastSentLargeImage = null;
    _lastSentTitle = null;
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lastSentSignature = null;
    _lastSentAt = null;
    if (_ready) await _sendClearedActivity();
  }

  Future<void> disconnect() async {
    _closed = true;
    _ready = false;
    _connecting = false;
    _heartbeat?.cancel();
    _heartbeat = null;
    _firstHeartbeat?.cancel();
    _firstHeartbeat = null;
    _reconnect?.cancel();
    _reconnect = null;
    final socket = _socket;
    _socket = null;
    _awaitingHeartbeatAck = false;
    _profile = null;
    _setConnectionState(DiscordConnectionState.disconnected);
    try {
      await socket?.close(WebSocketStatus.normalClosure, 'disabled');
    } catch (_) {
      // Closing an already-closed socket is harmless.
    }
  }

  Future<void> _connect() async {
    if (!_enabled ||
        _closed ||
        _invalidToken ||
        _connecting ||
        _socket != null) {
      return;
    }
    final token = _token;
    if (token == null || token.isEmpty) return;

    _connecting = true;
    _ready = false;
    _setConnectionState(
      _profile == null
          ? DiscordConnectionState.connecting
          : DiscordConnectionState.reconnecting,
    );
    try {
      final socket = await WebSocket.connect(
        'wss://gateway.discord.gg/?v=10&encoding=json',
        headers: {'User-Agent': 'YumeFlix Discord Presence'},
      ).timeout(const Duration(seconds: 15));
      if (!_enabled || _closed) {
        await socket.close(WebSocketStatus.normalClosure, 'disabled');
        return;
      }
      _socket = socket;
      socket.listen(
        (message) => _onMessage(socket, message),
        onError: (_) => _handleDisconnect(socket),
        onDone: () => _handleDisconnect(socket),
        cancelOnError: true,
      );
    } catch (_) {
      if (_enabled && !_closed) {
        _setConnectionState(DiscordConnectionState.reconnecting);
        _scheduleReconnect();
      } else {
        _setConnectionState(DiscordConnectionState.disconnected);
      }
    } finally {
      _connecting = false;
    }
  }

  void _onMessage(WebSocket socket, dynamic message) {
    if (!identical(socket, _socket) || message is! String) return;
    Map<String, dynamic> payload;
    try {
      payload = Map<String, dynamic>.from(jsonDecode(message) as Map);
    } catch (_) {
      return;
    }

    _sequence = payload['s'] as int? ?? _sequence;
    final op = payload['op'] as int?;
    final data = payload['d'];

    if (op == 10 && data is Map) {
      final interval = (data['heartbeat_interval'] as num?)?.toInt() ?? 41250;
      _heartbeat?.cancel();
      _firstHeartbeat?.cancel();
      _awaitingHeartbeatAck = false;
      final safeInterval = interval.clamp(1000, 120000).toInt();
      _firstHeartbeat = Timer(
        Duration(milliseconds: Random().nextInt(safeInterval)),
        () {
          _firstHeartbeat = null;
          _sendHeartbeat();
        },
      );
      _heartbeat = Timer.periodic(
        Duration(milliseconds: safeInterval),
        (_) => _sendHeartbeat(),
      );
      unawaited(
        _send({
          'op': 2,
          'd': {
            'token': _token,
            'properties': {
              'os': Platform.operatingSystem,
              'browser': 'YumeFlix',
              'device': Platform.operatingSystem,
            },
            'presence': {
              'since': null,
              'activities': <Map<String, dynamic>>[],
              'status': 'online',
              'afk': false,
            },
          },
        }),
      );
      return;
    }

    if (op == 11) {
      _awaitingHeartbeatAck = false;
      return;
    }

    if (op == 0 && payload['t'] == 'READY' && data is Map) {
      final user = data['user'];
      _profile = user is Map
          ? DiscordAccountProfile.fromGateway(Map<String, dynamic>.from(user))
          : null;
      _ready = true;
      _invalidToken = false;
      _setConnectionState(DiscordConnectionState.connected);
      _lastSentSignature = null;
      _lastSentAt = null;
      if (_title != null && _title!.trim().isNotEmpty) {
        unawaited(_sendPresence(force: true));
      }
      return;
    }

    if (op == 0 && payload['t'] == 'RESUMED') {
      _ready = true;
      _setConnectionState(DiscordConnectionState.connected);
      if (_title != null && _title!.trim().isNotEmpty) {
        unawaited(_sendPresence(force: true));
      }
      return;
    }

    if (op == 7) {
      _handleDisconnect(socket);
    } else if (op == 9) {
      // A fresh connection will re-identify, which is the safe recovery path
      // for either a resumable or non-resumable invalid session.
      _handleDisconnect(socket);
    }
  }

  void _sendHeartbeat() {
    final socket = _socket;
    if (socket == null || !_enabled || _closed) return;
    if (_awaitingHeartbeatAck) {
      unawaited(socket.close(4000, 'heartbeat acknowledgement timeout'));
      _handleDisconnect(socket);
      return;
    }
    _awaitingHeartbeatAck = true;
    unawaited(_send({'op': 1, 'd': _sequence}));
  }

  Future<void> _sendPresence({bool force = false}) async {
    if (!_ready || !_enabled || _title == null || _title!.trim().isEmpty) {
      return;
    }

    final now = DateTime.now();
    final signature = jsonEncode([_title, _state, _posterUrl, _playing]);
    final lastSentAt = _lastSentAt;
    var needsUpdate =
        force || _lastSentSignature != signature || lastSentAt == null;

    if (!needsUpdate) {
      final elapsed = now.difference(lastSentAt);
      final previousPosition = _lastSentPosition ?? Duration.zero;
      final expectedPosition = _lastSentPlaying
          ? previousPosition + elapsed
          : previousPosition;
      final driftSeconds = (_position - expectedPosition).inSeconds.abs();
      final durationDriftSeconds =
          (_duration - (_lastSentDuration ?? Duration.zero)).inSeconds.abs();
      // Avoid sending one Gateway presence update for each video position
      // sample. Discord animates the timestamps itself; only resync on a seek,
      // meaningful media-duration correction, or a low-frequency refresh.
      needsUpdate =
          driftSeconds >= 10 ||
          durationDriftSeconds >= 5 ||
          (_playing && elapsed >= const Duration(seconds: 45));
    }
    if (!needsUpdate) return;

    final activity = buildActivity(
      title: _title!,
      state: _state,
      posterUrl: _posterUrl,
      position: _position,
      duration: _duration,
      playing: _playing,
      nowMilliseconds: now.millisecondsSinceEpoch,
    );
    await _send({
      'op': 3,
      'd': {
        'since': _playing
            ? now.millisecondsSinceEpoch - _position.inMilliseconds
            : null,
        'activities': <Map<String, dynamic>>[activity],
        'status': 'online',
        'afk': false,
      },
    });
    if (!_ready) return;
    // Record exactly what Discord was sent, for the Settings → Discord
    // diagnostics row: the large_image value (or its absence) is the ground
    // truth about the cover, not what the code hoped to send.
    _lastSentSignature = signature;
    _lastSentAt = now;
    _lastSentPosition = _position;
    _lastSentDuration = _duration;
    _lastSentPlaying = _playing;
    _lastSentTitle = _title;
    final sentAssets = activity['assets'];
    _lastSentLargeImage = sentAssets is Map
        ? sentAssets['large_image'] as String?
        : null;
    notifyListeners();
  }

  /// Builds the Gateway activity with Discord's media-proxy-compatible
  /// external poster URL. Only a caller-verified https poster URL becomes
  /// the large image (with the title as large text). When there is no
  /// verified poster the activity carries NO `assets` object at all.
  ///
  /// That omission is deliberate and is the 2.7.0 cover fix: the old code
  /// fell back to the `yumeflix_logo` asset key here, but that key was
  /// never uploaded under application 1322319281819488256, and Discord
  /// renders an unknown asset key as a black circle — the exact symptom
  /// reported on every movie. A missing cover is honest; a dead key looks
  /// broken. No small image is sent either, for the same reason: the only
  /// small-image key ever used was the same unproven one.
  /// Exposed for focused payload tests.
  @visibleForTesting
  static Map<String, dynamic> buildActivity({
    required String title,
    String? state,
    String? posterUrl,
    required Duration position,
    required Duration duration,
    required bool playing,
    int? nowMilliseconds,
  }) {
    final now = nowMilliseconds ?? DateTime.now().millisecondsSinceEpoch;
    final clampedPosition = position < Duration.zero ? Duration.zero : position;
    final clampedDuration = duration < Duration.zero ? Duration.zero : duration;
    final remaining = clampedDuration - clampedPosition;
    final activity = <String, dynamic>{
      'application_id': applicationId,
      'name': 'YumeFlix',
      'type': 3,
      'details': _truncate(title.trim(), 128),
      'state': _truncate(
        (state?.trim().isNotEmpty ?? false) ? state!.trim() : 'Watching',
        128,
      ),
      if (playing)
        'timestamps': {
          'start': now - clampedPosition.inMilliseconds,
          if (remaining > Duration.zero) 'end': now + remaining.inMilliseconds,
        },
    };
    // Discord's media proxy only fetches external artwork over https, so
    // only a normalized https poster URL may become the large image.
    // normalizePosterUrl() upgrades http to https, so anything it returns
    // is safe to send as large_image. Callers must only pass a URL that
    // has already been fetch-verified (see _refreshVerifiedPoster); this
    // method itself is pure and trusts its input, which is why the
    // payload tests can exercise it directly.
    final normalizedPoster = normalizePosterUrl(posterUrl);
    final posterUri = normalizedPoster == null
        ? null
        : Uri.tryParse(normalizedPoster);
    if (posterUri != null && posterUri.scheme == 'https') {
      activity['assets'] = {
        'large_image': normalizedPoster,
        'large_text': _truncate(title.trim(), 128),
      };
    }
    // No verified poster: no `assets` key at all. Never send an asset key
    // Discord has not been given — it renders as a black circle.
    return activity;
  }

  /// The Discord activity title: the clean title, plus `· S{n} E{n}` only
  /// for a true series/anime episode with real numbering. Movies never get
  /// a season/episode suffix — plugins file films as one-episode shows, and
  /// a stale dummy `S1 E1` used to leak onto movie activities — and neither
  /// do `S0`/`E0` placeholders. The TMDB search title must stay the same
  /// clean title, so callers pass the bare item title separately.
  /// Exposed for focused title-rule tests.
  static String formatWatchingTitle({
    required String title,
    required bool isSeries,
    int? season,
    int? episode,
  }) {
    final clean = title.trim();
    if (!isSeries) return clean;
    final s = season ?? 0;
    final e = episode ?? 0;
    if (s <= 0 || e <= 0) return clean;
    return '$clean · S$s E$e';
  }

  /// Picks the poster Discord is most likely to render: a TMDB poster
  /// (image.tmdb.org) outranks an extension poster from any other host,
  /// because Discord's media proxy reliably fetches image.tmdb.org and
  /// silently drops artwork from hosts it cannot reach. When both live on
  /// the same host the extension URL wins, so the activity shows the same
  /// cover the viewer sees in YumeFlix. The keyless Cinemeta poster ranks
  /// last: it is the fallback for when neither of the first two is usable.
  /// A rejected extension URL never blocks the next fallback, and with
  /// neither usable the result is null — the caller then sends no image
  /// rather than a dead asset key. Exposed for focused fallback-chain tests.
  @visibleForTesting
  static String? selectEffectivePoster({
    String? extensionPosterUrl,
    String? tmdbPosterUrl,
    String? cinemetaPosterUrl,
  }) {
    final extension = normalizePosterUrl(extensionPosterUrl);
    final tmdb = normalizePosterUrl(tmdbPosterUrl);
    final cinemeta = normalizePosterUrl(cinemetaPosterUrl);
    if (extension == null) return tmdb ?? cinemeta;
    if (tmdb == null) return extension;
    final best = _posterRank(tmdb) < _posterRank(extension) ? tmdb : extension;
    return best;
  }

  static int _posterRank(String normalizedUrl) {
    final host = Uri.tryParse(normalizedUrl)?.host.toLowerCase() ?? '';
    return host == 'image.tmdb.org' ? 0 : 1;
  }

  /// Discord fetches this image from its media proxy, so only absolute public
  /// HTTPS URLs can be used. Plain http is upgraded to https, protocol-
  /// relative URLs gain the https scheme, and a bare TMDB poster_path (a
  /// single path segment such as `/abc123.jpg`) is expanded to its
  /// image.tmdb.org URL. Local files, private hosts, data/blob URLs, and
  /// extension-local resources are deliberately omitted instead of leaking
  /// them externally — and a rejected extension URL falls through to the
  /// TMDB lookup rather than sending the logo fallback.
  @visibleForTesting
  static String? normalizePosterUrl(String? rawUrl) {
    var value = rawUrl?.trim();
    if (value == null || value.isEmpty || value.length > 4096) return null;
    // Strip the fragment first so it cannot smuggle a bad scheme or host
    // past the checks below.
    final fragmentIndex = value.indexOf('#');
    if (fragmentIndex >= 0) {
      value = value.substring(0, fragmentIndex);
      if (value.isEmpty) return null;
    }
    // Bare TMDB poster_path: exactly one path segment. A multi-segment
    // relative path ('/posters/title.jpg') is not a TMDB path and stays
    // rejected rather than becoming a bogus image.tmdb.org URL.
    if (RegExp(r'^/[A-Za-z0-9._-]+$').hasMatch(value)) {
      return 'https://image.tmdb.org/t/p/w500$value';
    }
    final candidate = value.startsWith('//') ? 'https:$value' : value;
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        !host.contains('.')) {
      return null;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null && _isPrivateOrLocalAddress(ip)) return null;
    // Discord's media proxy only fetches https, so upgrade plain http.
    final upgraded = uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri;
    return upgraded.toString();
  }

  static bool _isPrivateOrLocalAddress(InternetAddress address) {
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return true;
    }
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      final first = bytes[0];
      final second = bytes[1];
      return first == 0 ||
          first == 10 ||
          first == 127 ||
          (first == 169 && second == 254) ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          first >= 224;
    }
    // IPv6 unique-local fc00::/7 and unspecified :: addresses.
    return (bytes[0] & 0xfe) == 0xfc || bytes.every((byte) => byte == 0);
  }

  static String _truncate(String value, int maxLength) =>
      value.length <= maxLength
      ? value
      : '${value.substring(0, maxLength - 1)}…';

  Future<void> _send(Map<String, dynamic> payload) async {
    final socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(payload));
    } catch (_) {
      _handleDisconnect(socket);
    }
  }

  Future<void> _sendClearedActivity() async {
    await _send({
      'op': 3,
      'd': {'since': null, 'activities': <Map<String, dynamic>>[]},
    });
  }

  void _handleDisconnect(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    final closeCode = socket.closeCode;
    _socket = null;
    _ready = false;
    _awaitingHeartbeatAck = false;
    unawaited(socket.close(WebSocketStatus.normalClosure, 'reconnecting'));
    _heartbeat?.cancel();
    _heartbeat = null;
    _firstHeartbeat?.cancel();
    _firstHeartbeat = null;

    if (closeCode == 4004) {
      _invalidToken = true;
      _profile = null;
      _setConnectionState(DiscordConnectionState.invalidToken);
      return;
    }
    if (_enabled && !_closed) {
      _setConnectionState(DiscordConnectionState.reconnecting);
      _scheduleReconnect();
    } else {
      _profile = null;
      _setConnectionState(DiscordConnectionState.disconnected);
    }
  }

  void _scheduleReconnect() {
    if (!_enabled || _closed || _invalidToken || _reconnect?.isActive == true) {
      return;
    }
    _reconnect = Timer(const Duration(seconds: 5), () {
      _reconnect = null;
      unawaited(_connect());
    });
  }

  void _setConnectionState(DiscordConnectionState value) {
    if (_connectionState == value) return;
    _connectionState = value;
    notifyListeners();
  }
}
