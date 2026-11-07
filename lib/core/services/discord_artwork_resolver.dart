import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config/tmdb_config.dart';

/// Resolves public TMDB poster URLs for Discord presence artwork.
///
/// Results (including misses) are cached per title, media type, and configured
/// API key. A single in-flight request is shared by multiple playback ticks.
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

  Future<String?> resolve({
    required String title,
    required String mediaType,
  }) async {
    final query = title.trim();
    final apiKey = TmdbConfig.apiKey.trim();
    final type = mediaType.trim().toLowerCase();
    if (query.isEmpty || apiKey.isEmpty || (type != 'movie' && type != 'tv')) {
      return null;
    }

    // Keep the key out of logs and persistent storage; its hash only scopes
    // this in-memory cache if the user replaces their configured TMDB key.
    final cacheKey =
        '$type|${query.toLowerCase()}|${apiKey.hashCode.toRadixString(16)}';
    if (_cache.containsKey(cacheKey)) {
      final cached = _cache.remove(cacheKey);
      _cache[cacheKey] = cached;
      return cached;
    }

    final request = _inFlight.putIfAbsent(
      cacheKey,
      () => _fetchPoster(query: query, mediaType: type, apiKey: apiKey),
    );
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
      if (posterPath is! String ||
          posterPath.trim().isEmpty ||
          !posterPath.trim().startsWith('/') ||
          posterPath.contains('..')) {
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

  static String _normalizedTitle(String? value) =>
      (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}
