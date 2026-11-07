import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/tmdb_config.dart';

/// Resolves public poster URLs for Discord presence artwork.
///
/// Two sources, in priority order:
///
/// 1. TMDB (key-gated) — the image.tmdb.org poster Discord's media proxy
///    serves most reliably. Returns null without a configured key.
/// 2. Stremio Cinemeta (keyless) — `v3-cinemeta.strem.io/meta/<type>/<imdb>.json`
///    returns `poster`/`background` (images.metahub.space) with no key at
///    all, so artwork keeps working in builds shipped without a TMDB key.
///
/// Nothing in this file ever sends an asset key: a poster is only usable
/// after [verifyPosterUrl] proves it fetches as an image (HTTP 200/206,
/// `content-type: image/*`). An unverified or missing poster means "send no
/// image", never a fallback key — see [DiscordPresenceService.buildActivity].
class DiscordArtworkResolver {
  DiscordArtworkResolver({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: TmdbConfig.baseUrl,
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
              sendTimeout: const Duration(seconds: 5),
              headers: const {'Accept': 'application/json'},
            ),
          );

  final Dio _dio;
  final _cache = <String, String?>{};
  final _inFlight = <String, Future<String?>>{};
  static const int _maxCacheEntries = 128;

  /// In-memory fetch-verification results, so a poster proven (or disproven)
  /// once is not re-checked on every playback tick.
  final _verifiedCache = <String, bool>{};
  static const int _maxVerifiedEntries = 128;

  /// Keyless Stremio Cinemeta metadata endpoint.
  static const String cinemetaBaseUrl = 'https://v3-cinemeta.strem.io';

  /// Only a well-formed IMDb id is ever sent to Cinemeta; anything else is
  /// refused rather than guessed at.
  static bool isValidImdbId(String? imdbId) =>
      imdbId != null && RegExp(r'^tt\d{6,}$').hasMatch(imdbId.trim());

  /// Resolves a public TMDB poster URL for Discord presence artwork.
  ///
  /// When [tmdbId] is known (from the item itself or its `syncData`), the
  /// exact title is looked up by id first — no title guessing, so a film
  /// can never resolve to a same-named different one. Otherwise the
  /// exact-title search runs. Returns null when no TMDB key is configured:
  /// the caller keeps the extension poster in that case.
  Future<String?> resolve({
    required String title,
    required String mediaType,
    int? tmdbId,
  }) async {
    final type = mediaType.trim().toLowerCase();
    final apiKey = TmdbConfig.apiKey.trim();
    if (apiKey.isEmpty || (type != 'movie' && type != 'tv')) return null;

    if (tmdbId != null && tmdbId > 0) {
      final byId = await resolveById(tmdbId: tmdbId, mediaType: type);
      if (byId != null) return byId;
    }

    final query = title.trim();
    if (query.isEmpty) return null;
    // Keep the key out of logs and persistent storage; its hash only scopes
    // this in-memory cache if the user replaces their configured TMDB key.
    final cacheKey =
        '$type|${query.toLowerCase()}|${apiKey.hashCode.toRadixString(16)}';
    return _cachedFetch(
      cacheKey,
      () => _fetchPoster(query: query, mediaType: type, apiKey: apiKey),
    );
  }

  /// Direct `/movie/{id}` or `/tv/{id}` lookup. Poster first, backdrop as
  /// a last resort. Returns null when the id is invalid, no key is
  /// configured, or the title has neither a poster nor a backdrop.
  Future<String?> resolveById({
    required int tmdbId,
    required String mediaType,
  }) async {
    final type = mediaType.trim().toLowerCase();
    final apiKey = TmdbConfig.apiKey.trim();
    if (tmdbId <= 0 ||
        apiKey.isEmpty ||
        (type != 'movie' && type != 'tv')) {
      return null;
    }
    final cacheKey =
        'id|$type|$tmdbId|${apiKey.hashCode.toRadixString(16)}';
    return _cachedFetch(
      cacheKey,
      () => _fetchById(tmdbId: tmdbId, mediaType: type, apiKey: apiKey),
    );
  }

  /// Keyless poster lookup via Stremio Cinemeta.
  ///
  /// `GET https://v3-cinemeta.strem.io/meta/<movie|series>/<imdbId>.json`
  /// needs no key and returns the item's `poster` and `background`
  /// (images.metahub.space URLs). This is the artwork source for builds
  /// shipped without a TMDB key — which is every shipped build while
  /// `secrets.TMDB_API_KEY` is unset, since [resolve]/[resolveById] then
  /// return null for every title.
  ///
  /// Returns null for an invalid IMDb id, an unsupported media type, a
  /// failed request, or a meta object with neither a poster nor a
  /// background. Results (including misses) are cached per id and type.
  Future<String?> resolveKeyless({
    required String? imdbId,
    required String mediaType,
  }) async {
    final type = mediaType.trim().toLowerCase();
    final id = imdbId?.trim();
    if (!isValidImdbId(id) || (type != 'movie' && type != 'tv')) {
      return null;
    }
    final kind = type == 'tv' ? 'series' : 'movie';
    final cacheKey = 'cinemeta|$type|$id';
    return _cachedFetch(cacheKey, () => _fetchCinemeta(kind: kind, imdbId: id!));
  }

  Future<String?> _fetchCinemeta({
    required String kind,
    required String imdbId,
  }) async {
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(
        Uri.parse('$cinemetaBaseUrl/meta/$kind/$imdbId.json'),
        options: Options(headers: const {'Accept': 'application/json'}),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return posterUrlFromCinemetaResponse(response.data!);
    } catch (_) {
      // Presence must survive Cinemeta being down: the caller sends no
      // image rather than failing playback.
      return null;
    }
  }

  /// Keyless poster lookup via Stremio Cinemeta catalog search — the
  /// fallback that needs NO IMDb id.
  ///
  /// `GET https://v3-cinemeta.strem.io/catalog/<series|movie>/top/search=<title>.json`
  /// needs no key and returns matching metas with their `poster` /
  /// `background`. This is the artwork source for plugin items in builds
  /// shipped without a TMDB key: plugins send no `syncData.imdb`, and the
  /// details-screen id enrichment needs a TMDB key to run, so
  /// [resolveKeyless] (IMDb-gated) never fires for them and the extension
  /// poster is the only candidate. When that fails verification, this is
  /// what still finds a cover.
  ///
  /// Only an exact normalized-title match is accepted — a wrong film's
  /// poster is worse than no poster. Returns null for an empty title, an
  /// unsupported media type, a failed request, or no exact match with a
  /// usable poster. Results (including misses) are cached per title/type.
  Future<String?> resolveKeylessByTitle({
    required String title,
    required String mediaType,
  }) async {
    final type = mediaType.trim().toLowerCase();
    final query = title.trim();
    if (query.isEmpty || (type != 'movie' && type != 'tv')) {
      return null;
    }
    final kind = type == 'tv' ? 'series' : 'movie';
    final cacheKey =
        'cinemeta-title|$type|${_normalizedTitle(query)}';
    return _cachedFetch(
      cacheKey,
      () => _fetchCinemetaByTitle(kind: kind, query: query),
    );
  }

  Future<String?> _fetchCinemetaByTitle({
    required String kind,
    required String query,
  }) async {
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(
        Uri.parse(
          '$cinemetaBaseUrl/catalog/$kind/top/'
          'search=${Uri.encodeComponent(query)}.json',
        ),
        options: Options(headers: const {'Accept': 'application/json'}),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return posterUrlFromCinemetaSearchResponse(
        response.data!,
        query: query,
      );
    } catch (_) {
      // Presence must survive Cinemeta being down: the caller sends no
      // image rather than failing playback.
      return null;
    }
  }

  /// Poster (medium-upgraded) of the exact normalized-title match in a
  /// Cinemeta catalog-search response, background as a last resort, or null
  /// when no result matches the title exactly. Exposed for focused tests.
  @visibleForTesting
  static String? posterUrlFromCinemetaSearchResponse(
    Map<String, dynamic> response, {
    required String query,
  }) {
    final queryKey = _normalizedTitle(query);
    if (queryKey.isEmpty) return null;
    final metas = response['metas'];
    if (metas is! List) return null;
    for (final raw in metas) {
      if (raw is! Map) continue;
      final meta = Map<String, dynamic>.from(raw);
      if (_normalizedTitle(meta['name']?.toString()) != queryKey) {
        continue;
      }
      final poster = (meta['poster'] as String?)?.trim();
      if (poster != null && poster.isNotEmpty) {
        final upgraded = _upgradeCinemetaPoster(poster);
        if (upgraded != null) return upgraded;
      }
      final background = (meta['background'] as String?)?.trim();
      if (background != null && background.isNotEmpty) {
        return _asHttpsImageUrl(background);
      }
    }
    return null;
  }

  /// Poster first, background as a last resort, from a Cinemeta
  /// `/meta/<type>/<imdb>.json` response. Cinemeta serves posters in
  /// `small`/`medium`/`large` sizes; the `medium` variant is used so the
  /// Discord cover is not a thumbnail upscale. A background URL is used
  /// as-is (Cinemeta already serves it at `medium`).
  /// Exposed for focused keyless-resolve tests.
  @visibleForTesting
  static String? posterUrlFromCinemetaResponse(Map<String, dynamic> response) {
    final meta = response['meta'];
    if (meta is! Map) return null;
    final poster = (meta['poster'] as String?)?.trim();
    if (poster != null && poster.isNotEmpty) {
      final upgraded = _upgradeCinemetaPoster(poster);
      if (upgraded != null) return upgraded;
    }
    final background = (meta['background'] as String?)?.trim();
    if (background != null && background.isNotEmpty) {
      return _asHttpsImageUrl(background);
    }
    return null;
  }

  /// Cinemeta poster URLs carry their size in the path
  /// (`/poster/small/tt1201607/img`); `medium` is the Discord-cover size.
  /// Any other poster host passes through unchanged.
  static String? _upgradeCinemetaPoster(String url) {
    final upgraded = url.replaceFirst('/poster/small/', '/poster/medium/');
    return _asHttpsImageUrl(upgraded);
  }

  /// Accepts only absolute http(s) image URLs; upgrades http to https.
  /// Anything else (relative paths, data/blob URLs, local hosts) is null.
  static String? _asHttpsImageUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 4096) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return (uri.scheme == 'http' ? uri.replace(scheme: 'https') : uri)
        .toString();
  }

  /// Proves a poster URL actually fetches as an image before Discord is
  /// ever told about it.
  ///
  /// Sends a `HEAD` first (no body downloaded); servers that refuse `HEAD`
  /// fall back to a 1 KiB ranged `GET`. True only for HTTP 200/206 with a
  /// `content-type` starting with `image/`. Results are cached in memory
  /// per URL so playback ticks never re-check the same poster.
  ///
  /// Discord's media proxy fetches the URL itself, so a phone-side 200 does
  /// not guarantee Discord renders it — but an unverifiable URL is
  /// guaranteed not to render, and sending it anyway is what used to
  /// collapse the cover onto the dead fallback key.
  Future<bool> verifyPosterUrl(String url) async {
    final normalized = url.trim();
    if (normalized.isEmpty) return false;
    final cached = _verifiedCache[normalized];
    if (cached != null) return cached;
    final result = await _verifyPosterUrlUncached(normalized);
    _verifiedCache[normalized] = result;
    while (_verifiedCache.length > _maxVerifiedEntries) {
      _verifiedCache.remove(_verifiedCache.keys.first);
    }
    return result;
  }

  Future<bool> _verifyPosterUrlUncached(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return false;
    }
    try {
      final head = await _dio.headUri<void>(
        uri,
        options: Options(
          validateStatus: (_) => true,
          // Verification runs off the playback path and a false negative
          // costs the whole cover, so it gets more room than the 5s API
          // defaults: a slow HEAD must not kill a good poster by itself.
          // (Live probe, 2026-11-07: image.tmdb.org HEADs intermittently
          // exceeded 5s through this machine's egress proxy and the
          // candidate was dropped, while the same URL verified fine a
          // minute later.)
          connectTimeout: _verifyTimeout,
          receiveTimeout: _verifyTimeout,
        ),
      );
      if (_isImageResponse(head.statusCode, head.headers)) return true;
      // Some CDNs reject HEAD (405/501) while serving GET fine, and some
      // hosts answer HEAD with a redirect the platform stack does not
      // follow for HEAD; a ranged GET proves fetchability either way
      // without downloading the whole poster.
      if (_headNeedsRangedGet(head.statusCode)) {
        return await _verifyWithRangedGet(uri);
      }
      return false;
    } catch (_) {
      return _verifyWithRangedGet(uri);
    }
  }

  /// Verification-only timeout, longer than the API defaults (see above).
  static const Duration _verifyTimeout = Duration(seconds: 10);

  /// HEAD outcomes that do not settle fetchability and deserve a ranged
  /// GET: HEAD refused (405/501) or a redirect (301/302/303/307/308) the
  /// HEAD stack may not have followed.
  static bool _headNeedsRangedGet(int? statusCode) =>
      statusCode == 405 ||
      statusCode == 501 ||
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  Future<bool> _verifyWithRangedGet(Uri uri) async {
    try {
      final response = await _dio.getUri<void>(
        uri,
        options: Options(
          headers: const {'Range': 'bytes=0-1023'},
          validateStatus: (_) => true,
          connectTimeout: _verifyTimeout,
          receiveTimeout: _verifyTimeout,
        ),
      );
      return _isImageResponse(response.statusCode, response.headers);
    } catch (_) {
      return false;
    }
  }

  static bool _isImageResponse(int? statusCode, Headers headers) {
    if (statusCode != 200 && statusCode != 206) return false;
    final contentType =
        headers.value(Headers.contentTypeHeader)?.trim().toLowerCase() ?? '';
    return contentType.startsWith('image/');
  }

  Future<String?> _cachedFetch(
    String cacheKey,
    Future<String?> Function() fetch,
  ) async {
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache.remove(cacheKey);
      _cache[cacheKey] = cached;
      return cached;
    }

    final request = _inFlight.putIfAbsent(cacheKey, fetch);
    try {
      final result = await request;
      _cache[cacheKey] = result;
      while (_cache.length > _maxCacheEntries) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    } finally {
      await _inFlight.remove(cacheKey);
    }
  }

  Future<String?> _fetchById({
    required int tmdbId,
    required String mediaType,
    required String apiKey,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/$mediaType/$tmdbId',
        queryParameters: {'api_key': apiKey},
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return posterUrlFromDetailsResponse(response.data!);
    } catch (_) {
      // Presence should still work when TMDB is unavailable: the caller keeps
      // the extension-provided poster as its fallback.
      return null;
    }
  }

  Future<String?> _fetchPoster({
    required String query,
    required String mediaType,
    required String apiKey,
  }) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '/search/$mediaType',
        queryParameters: {
          'api_key': apiKey,
          'query': query,
          'include_adult': false,
          'page': 1,
        },
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return posterUrlFromSearchResponse(
        response.data!,
        query: query,
        mediaType: mediaType,
      );
    } catch (_) {
      // Presence should still work when TMDB is unavailable: the caller keeps
      // the extension-provided poster as its fallback.
      return null;
    }
  }

  /// Selects an exact title match when possible, otherwise TMDB's first result
  /// with a usable poster. TMDB's poster_path is nullable and starts with '/'.
  @visibleForTesting
  static String? posterUrlFromSearchResponse(
    Map<String, dynamic> response, {
    required String query,
    required String mediaType,
  }) {
    final type = mediaType.trim().toLowerCase();
    if (type != 'movie' && type != 'tv') return null;
    final results = response['results'];
    if (results is! List) return null;

    Map<String, dynamic>? firstWithPoster;
    Map<String, dynamic>? exactMatch;
    final queryKey = _normalizedTitle(query);
    final titleField = type == 'tv' ? 'name' : 'title';
    final originalTitleField = type == 'tv'
        ? 'original_name'
        : 'original_title';

    for (final raw in results) {
      if (raw is! Map) continue;
      final result = Map<String, dynamic>.from(raw);
      final posterPath = result['poster_path'];
      if (posterPath is! String || !_isSafeTmdbPath(posterPath)) {
        continue;
      }
      firstWithPoster ??= result;
      if (queryKey.isNotEmpty &&
          (_normalizedTitle(result[titleField]?.toString()) == queryKey ||
              _normalizedTitle(result[originalTitleField]?.toString()) ==
                  queryKey)) {
        exactMatch = result;
        break;
      }
    }

    final selected = exactMatch ?? firstWithPoster;
    if (selected == null) return null;
    final path = (selected['poster_path'] as String).trim();
    if (path.length > 512) return null;
    return 'https://image.tmdb.org/t/p/w500$path';
  }

  /// Poster first, backdrop as a last resort, from a direct `/movie/{id}`
  /// or `/tv/{id}` details response. TMDB's paths are nullable and start
  /// with '/'.
  @visibleForTesting
  static String? posterUrlFromDetailsResponse(
    Map<String, dynamic> details,
  ) {
    final posterPath = details['poster_path'];
    if (posterPath is String && _isSafeTmdbPath(posterPath)) {
      return 'https://image.tmdb.org/t/p/w500${posterPath.trim()}';
    }
    final backdropPath = details['backdrop_path'];
    if (backdropPath is String && _isSafeTmdbPath(backdropPath)) {
      return 'https://image.tmdb.org/t/p/w780${backdropPath.trim()}';
    }
    return null;
  }

  /// A TMDB image path is a single absolute segment: non-empty, starting
  /// with '/', with no traversal and within a sane length.
  static bool _isSafeTmdbPath(String path) {
    final trimmed = path.trim();
    return trimmed.isNotEmpty &&
        trimmed.startsWith('/') &&
        !trimmed.contains('..') &&
        trimmed.length <= 512;
  }

  static String _normalizedTitle(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}
