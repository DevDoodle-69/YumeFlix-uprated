import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/config/tmdb_config.dart';
import 'package:yumeflix/core/services/discord_artwork_resolver.dart';

/// Builds a resolver whose HTTP layer is fully stubbed: every request is
/// answered from [handlers] keyed by path, and every requested path is
/// recorded in [requestedPaths] so tests can assert which endpoint was hit
/// (by-id lookup vs title search) and in which order.
({DiscordArtworkResolver resolver, List<String> requestedPaths})
stubbedResolver(Map<String, Map<String, dynamic>?> handlers) {
  final requestedPaths = <String>[];
  final dio = Dio(BaseOptions(baseUrl: TmdbConfig.baseUrl));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requestedPaths.add(options.path);
        final data = handlers[options.path];
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: data == null ? 404 : 200,
            data: data,
          ),
        );
      },
    ),
  );
  return (resolver: DiscordArtworkResolver(dio: dio), requestedPaths: requestedPaths);
}

void main() {
  // The resolver refuses every lookup without a key; the stub key keeps the
  // tests off the network while exercising the real code path.
  setUp(() => TmdbConfig.setUserApiKey('test-key'));
  tearDown(() => TmdbConfig.setUserApiKey(null));
  group('Discord TMDB artwork lookup', () {
    test('uses the exact TV result and its w500 poster path', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'name': 'Black Clover: Special', 'poster_path': '/special.jpg'},
            {'name': 'Black Clover', 'poster_path': '/series.jpg'},
          ],
        },
        query: 'Black Clover',
        mediaType: 'tv',
      );

      expect(poster, 'https://image.tmdb.org/t/p/w500/series.jpg');
    });

    test('uses the exact movie result instead of the first fuzzy result', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'title': 'Black Clover: Shorts', 'poster_path': '/shorts.jpg'},
            {
              'title': 'Black Clover: Sword of the Wizard King',
              'original_title': 'Black Clover',
              'poster_path': '/movie.jpg',
            },
          ],
        },
        query: 'Black Clover',
        mediaType: 'movie',
      );

      expect(poster, 'https://image.tmdb.org/t/p/w500/movie.jpg');
    });

    test('skips null or unsafe poster_path values', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'name': 'Black Clover', 'poster_path': null},
            {'name': 'Other', 'poster_path': '/../../private.jpg'},
          ],
        },
        query: 'Black Clover',
        mediaType: 'tv',
      );

      expect(poster, isNull);
    });

    test('returns no poster for an unsupported media type', () {
      expect(
        DiscordArtworkResolver.posterUrlFromSearchResponse(
          {
            'results': [
              {'title': 'Example', 'poster_path': '/example.jpg'},
            ],
          },
          query: 'Example',
          mediaType: 'person',
        ),
        isNull,
      );
    });
  });

  group('Discord TMDB artwork lookup by id', () {
    test('prefers the poster from a direct /movie/{id} lookup', () async {
      final stub = stubbedResolver({
        '/movie/27205': {
          'title': 'Inception',
          'poster_path': '/inception.jpg',
          'backdrop_path': '/inception-bg.jpg',
        },
      });

      expect(
        await stub.resolver.resolveById(tmdbId: 27205, mediaType: 'movie'),
        'https://image.tmdb.org/t/p/w500/inception.jpg',
      );
      expect(stub.requestedPaths, ['/movie/27205']);
    });

    test('falls back to the backdrop when the details have no poster', () {
      expect(
        DiscordArtworkResolver.posterUrlFromDetailsResponse({
          'title': 'Example',
          'poster_path': null,
          'backdrop_path': '/example-bg.jpg',
        }),
        'https://image.tmdb.org/t/p/w780/example-bg.jpg',
      );
    });

    test('returns no poster when details have neither poster nor backdrop', () {
      expect(
        DiscordArtworkResolver.posterUrlFromDetailsResponse({
          'title': 'Example',
          'poster_path': null,
          'backdrop_path': null,
        }),
        isNull,
      );
    });

    test('rejects unsafe paths in a details response', () {
      expect(
        DiscordArtworkResolver.posterUrlFromDetailsResponse({
          'poster_path': '/../../private.jpg',
          'backdrop_path': '/../../private-bg.jpg',
        }),
        isNull,
      );
    });

    test('resolve() tries the id first and never searches on a hit', () async {
      final stub = stubbedResolver({
        '/movie/27205': {
          'title': 'Inception',
          'poster_path': '/inception.jpg',
          'backdrop_path': '/inception-bg.jpg',
        },
        '/search/movie': {
          'results': [
            {'title': 'Inception', 'poster_path': '/wrong.jpg'},
          ],
        },
      });

      expect(
        await stub.resolver.resolve(
          title: 'Inception',
          mediaType: 'movie',
          tmdbId: 27205,
        ),
        'https://image.tmdb.org/t/p/w500/inception.jpg',
      );
      expect(stub.requestedPaths, ['/movie/27205']);
    });

    test(
      'resolve() falls back to exact-title search when the id has no poster',
      () async {
        final stub = stubbedResolver({
          '/movie/27205': {
            'title': 'Inception',
            'poster_path': null,
            'backdrop_path': null,
          },
          '/search/movie': {
            'results': [
              {'title': 'Inception', 'poster_path': '/search.jpg'},
            ],
          },
        });

        expect(
          await stub.resolver.resolve(
            title: 'Inception',
            mediaType: 'movie',
            tmdbId: 27205,
          ),
          'https://image.tmdb.org/t/p/w500/search.jpg',
        );
        expect(stub.requestedPaths, ['/movie/27205', '/search/movie']);
      },
    );

    test('resolveById rejects invalid ids and unsupported media types', () async {
      final stub = stubbedResolver({});
      expect(
        await stub.resolver.resolveById(tmdbId: 0, mediaType: 'movie'),
        isNull,
      );
      expect(
        await stub.resolver.resolveById(tmdbId: -5, mediaType: 'movie'),
        isNull,
      );
      expect(
        await stub.resolver.resolveById(tmdbId: 27205, mediaType: 'person'),
        isNull,
      );
      expect(stub.requestedPaths, isEmpty);
    });
  });
}
