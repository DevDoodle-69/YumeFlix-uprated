import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/services/discord_artwork_resolver.dart';
import 'package:yumeflix/core/services/discord_presence_service.dart';

/// Builds a resolver whose HTTP layer is fully stubbed: every request is
/// answered by [handler] from the request itself, and every request is
/// recorded so tests can assert which endpoint was hit, with which method,
/// and in which order. No test here touches the network.
({DiscordArtworkResolver resolver, List<RequestOptions> requests})
stubbedResolver(Response<dynamic> Function(RequestOptions options) handler) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, interceptorHandler) {
        requests.add(options);
        interceptorHandler.resolve(handler(options));
      },
    ),
  );
  return (resolver: DiscordArtworkResolver(dio: dio), requests: requests);
}

Response<dynamic> _response(
  RequestOptions options, {
  required int status,
  Map<String, dynamic>? data,
  String? contentType,
}) => Response<dynamic>(
  requestOptions: options,
  statusCode: status,
  data: data,
  headers: contentType == null
      ? Headers()
      : Headers.fromMap({
          Headers.contentTypeHeader: [contentType],
        }),
);

Map<String, dynamic> _cinemetaBody({
  String? poster,
  String? background,
}) => {
  'meta': {
    'id': 'tt1201607',
    'type': 'movie',
    'name': 'Harry Potter and the Deathly Hallows: Part 2',
    'poster': ?poster,
    'background': ?background,
  },
};

void main() {
  group('Discord keyless Cinemeta artwork lookup', () {
    test('returns the medium poster for a movie IMDb id', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: _cinemetaBody(
            poster: 'https://images.metahub.space/poster/small/tt1201607/img',
          ),
        ),
      );

      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt1201607',
          mediaType: 'movie',
        ),
        'https://images.metahub.space/poster/medium/tt1201607/img',
      );
      expect(stub.requests, hasLength(1));
      expect(
        stub.requests.single.uri.toString(),
        'https://v3-cinemeta.strem.io/meta/movie/tt1201607.json',
      );
    });

    test('uses the series endpoint for TV', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: _cinemetaBody(
            poster: 'https://images.metahub.space/poster/small/tt0903747/img',
          ),
        ),
      );

      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt0903747',
          mediaType: 'tv',
        ),
        'https://images.metahub.space/poster/medium/tt0903747/img',
      );
      expect(
        stub.requests.single.uri.toString(),
        'https://v3-cinemeta.strem.io/meta/series/tt0903747.json',
      );
    });

    test('falls back to the background when Cinemeta has no poster', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: _cinemetaBody(
            background:
                'https://images.metahub.space/background/medium/tt1201607/img',
          ),
        ),
      );

      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt1201607',
          mediaType: 'movie',
        ),
        'https://images.metahub.space/background/medium/tt1201607/img',
      );
    });

    test('returns null when Cinemeta has neither poster nor background',
        () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, data: _cinemetaBody()),
      );

      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt1201607',
          mediaType: 'movie',
        ),
        isNull,
      );
    });

    test('returns null on a Cinemeta error response', () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 404),
      );

      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt1201607',
          mediaType: 'movie',
        ),
        isNull,
      );
    });

    test('refuses invalid IMDb ids and unsupported types without a request',
        () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, data: _cinemetaBody()),
      );

      for (final badId in [null, '', 'tt123', '1201607', 'tt12x4567']) {
        expect(
          await stub.resolver.resolveKeyless(
            imdbId: badId,
            mediaType: 'movie',
          ),
          isNull,
          reason: 'imdbId: $badId',
        );
      }
      expect(
        await stub.resolver.resolveKeyless(
          imdbId: 'tt1201607',
          mediaType: 'person',
        ),
        isNull,
      );
      expect(stub.requests, isEmpty);
    });

    test('parses the poster from a raw Cinemeta response', () {
      expect(
        DiscordArtworkResolver.posterUrlFromCinemetaResponse(
          _cinemetaBody(
            poster: 'https://images.metahub.space/poster/small/tt1201607/img',
          ),
        ),
        'https://images.metahub.space/poster/medium/tt1201607/img',
      );
      expect(
        DiscordArtworkResolver.posterUrlFromCinemetaResponse(
          {'meta': <String, dynamic>{}},
        ),
        isNull,
      );
      expect(
        DiscordArtworkResolver.posterUrlFromCinemetaResponse({}),
        isNull,
      );
    });
  });

  group('Discord poster fetch verification', () {
    test('accepts a HEAD 200 with an image content type', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          contentType: 'image/jpeg',
        ),
      );

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.metahub.space/poster/medium/tt1201607/img',
        ),
        isTrue,
      );
      expect(stub.requests, hasLength(1));
      expect(stub.requests.single.method, 'HEAD');
    });

    test('rejects a 404 poster', () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 404, contentType: 'text/html'),
      );

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.example.org/posters/gone.jpg',
        ),
        isFalse,
      );
    });

    test('rejects a 200 response that is not an image', () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, contentType: 'text/html'),
      );

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.example.org/posters/not-an-image.jpg',
        ),
        isFalse,
      );
    });

    test('falls back to a ranged GET when the host refuses HEAD', () async {
      final stub = stubbedResolver((options) {
        if (options.method == 'HEAD') {
          return _response(options, status: 405, contentType: 'text/html');
        }
        return _response(options, status: 206, contentType: 'image/webp');
      });

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.example.org/posters/head-refused.jpg',
        ),
        isTrue,
      );
      expect(stub.requests, hasLength(2));
      expect(stub.requests[1].method, 'GET');
      expect(stub.requests[1].headers['Range'], 'bytes=0-1023');
    });

    test('rejects when the ranged GET also fails', () async {
      final stub = stubbedResolver((options) {
        if (options.method == 'HEAD') {
          return _response(options, status: 405, contentType: 'text/html');
        }
        return _response(options, status: 404, contentType: 'text/html');
      });

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.example.org/posters/gone.jpg',
        ),
        isFalse,
      );
    });

    test('rejects non-http(s) URLs without a request', () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, contentType: 'image/png'),
      );

      expect(
        await stub.resolver.verifyPosterUrl('data:image/png;base64,AAAA'),
        isFalse,
      );
      expect(
        await stub.resolver.verifyPosterUrl(''),
        isFalse,
      );
      expect(stub.requests, isEmpty);
    });

    test('caches verification results instead of re-checking', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          contentType: 'image/jpeg',
        ),
      );
      const url = 'https://images.metahub.space/poster/medium/tt1201607/img';

      expect(await stub.resolver.verifyPosterUrl(url), isTrue);
      expect(await stub.resolver.verifyPosterUrl(url), isTrue);
      expect(stub.requests, hasLength(1));
    });
  });

  group('Discord fallback to no image', () {
    test('buildActivity carries no assets key when no poster is verified',
        () {
      for (final posterUrl in <String?>[null, '', 'not a url']) {
        final activity = DiscordPresenceService.buildActivity(
          title: 'Harry Potter and the Deathly Hallows: Part 2',
          posterUrl: posterUrl,
          position: Duration.zero,
          duration: const Duration(minutes: 130),
          playing: true,
        );
        expect(activity.containsKey('assets'), isFalse, reason: '$posterUrl');
        // Title and timestamps still reach Discord; only the cover is
        // omitted. A missing cover is honest — the old dead `yumeflix_logo`
        // key rendered as a black circle instead.
        expect(
          activity['details'],
          'Harry Potter and the Deathly Hallows: Part 2',
        );
        expect(activity.containsKey('timestamps'), isTrue);
      }
    });

    test('a verified poster is sent on its own, with no small image', () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Harry Potter and the Deathly Hallows: Part 2',
        posterUrl: 'https://images.metahub.space/poster/medium/tt1201607/img',
        position: Duration.zero,
        duration: const Duration(minutes: 130),
        playing: true,
      );
      final assets = activity['assets'] as Map<String, dynamic>;
      expect(
        assets['large_image'],
        'https://images.metahub.space/poster/medium/tt1201607/img',
      );
      expect(assets.containsKey('small_image'), isFalse);
      expect(assets.containsKey('large_image'), isTrue);
    });
  });

  group('Discord activity title rule', () {
    test('a movie never gets an S/E suffix, even with a dummy S1 E1 episode',
        () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Harry Potter and the Deathly Hallows: Part 2',
          isSeries: false,
          season: 1,
          episode: 1,
        ),
        'Harry Potter and the Deathly Hallows: Part 2',
      );
    });

    test('a true series episode keeps its S/E suffix', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Breaking Bad',
          isSeries: true,
          season: 1,
          episode: 1,
        ),
        'Breaking Bad · S1 E1',
      );
    });
  });
}
