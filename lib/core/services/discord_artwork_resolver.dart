import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/tmdb_config.dart';

/// Resolves public TMDB poster URLs for Discord presence artwork.
///
/// Results (including misses) are cached per title or TMDB id, media type,
/// and configured API key. A single in-flight request is shared by multiple
/// playback ticks. No key is ever hard-coded: without a configured key every
/// lookup returns null and the caller keeps the extension poster.
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
