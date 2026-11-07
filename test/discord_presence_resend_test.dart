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

/// Same stub, but [handler] may reject (e.g. to model a HEAD that throws).
({DiscordArtworkResolver resolver, List<RequestOptions> requests})
stubbedResolverWithReject(
  void Function(
    RequestOptions options,
    RequestInterceptorHandler interceptorHandler,
  )
  handler,
) {
  final requests = <RequestOptions>[];
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, interceptorHandler) {
        requests.add(options);
        handler(options, interceptorHandler);
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
  String? location,
}) {
  final headersMap = <String, List<String>>{};
  if (contentType != null) {
    headersMap[Headers.contentTypeHeader] = [contentType];
  }
  if (location != null) {
    headersMap['location'] = [location];
  }
  return Response<dynamic>(
    requestOptions: options,
    statusCode: status,
    data: data,
    headers: Headers.fromMap(headersMap),
  );
}

const _dexterMetaBody = {
  'meta': {
    'id': 'tt33043892',
    'type': 'series',
    'name': 'Dexter: Resurrection',
    'poster': 'https://images.metahub.space/poster/small/tt33043892/img',
    'background':
        'https://images.metahub.space/background/medium/tt33043892/img',
  },
};

Map<String, dynamic> _dexterSearchBody({String? poster, bool noPoster = false}) => {
  'metas': [
    {
      'id': 'tt13030378',
      'type': 'series',
      'name': 'Dexter: New Blood',
      'poster':
          'https://images.metahub.space/poster/small/tt13030378/img',
    },
    {
      'id': 'tt33043892',
      'type': 'series',
      'name': 'Dexter: Resurrection',
      if (!noPoster)
        'poster':
            poster ??
            'https://m.media-amazon.com/images/M/MV5BMWFmZDE2OTktOWY1Yi00ZTBiLWE3NWUtMzdmNTM1ZmQ0ZGQzXkEyXkFqcGc@._V1_SX250.jpg',
      'background':
          'https://images.metahub.space/background/medium/tt33043892/img',
    },
  ],
};

/// Waits until the service finished its artwork run for the current item
/// (the "Checking artwork…" note is replaced), or fails the test.
Future<void> _waitForArtwork(DiscordPresenceService service) async {
  for (var i = 0; i < 250; i++) {
    if (service.lastArtworkNote != 'Checking artwork…') return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('artwork verification did not finish (note still "Checking artwork…")');
}

void main() {
  group('Discord keyless title-search artwork lookup', () {
    test('returns the medium poster for an exact series title match',
        () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: _dexterSearchBody(),
        ),
      );

      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: 'Dexter: Resurrection',
          mediaType: 'tv',
        ),
        // The search catalog serves an m.media-amazon.com poster, which
        // passes through unchanged (only metahub /poster/small/ URLs are
        // upgraded to medium).
        'https://m.media-amazon.com/images/M/MV5BMWFmZDE2OTktOWY1Yi00ZTBiLWE3NWUtMzdmNTM1ZmQ0ZGQzXkEyXkFqcGc@._V1_SX250.jpg',
      );
      expect(stub.requests, hasLength(1));
      expect(
        stub.requests.single.uri.toString(),
        'https://v3-cinemeta.strem.io/catalog/series/top/search=Dexter%3A%20Resurrection.json',
      );
    });

    test('uses the movie catalog for movies', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: {
            'metas': [
              {
                'id': 'tt1201607',
                'type': 'movie',
                'name': 'Harry Potter and the Deathly Hallows: Part 2',
                'poster':
                    'https://images.metahub.space/poster/small/tt1201607/img',
              },
            ],
          },
        ),
      );

      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: 'Harry Potter and the Deathly Hallows: Part 2',
          mediaType: 'movie',
        ),
        'https://images.metahub.space/poster/medium/tt1201607/img',
      );
      expect(
        stub.requests.single.uri.toString(),
        'https://v3-cinemeta.strem.io/catalog/movie/top/search=Harry%20Potter%20and%20the%20Deathly%20Hallows%3A%20Part%202.json',
      );
    });

    test('returns null when no result matches the title exactly', () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: {
            'metas': [
              {
                'id': 'tt13030378',
                'type': 'series',
                'name': 'Dexter: New Blood',
                'poster':
                    'https://images.metahub.space/poster/small/tt13030378/img',
              },
            ],
          },
        ),
      );

      // A same-franchise near miss must never be adopted as this title's
      // cover: a wrong poster is worse than no poster.
      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: 'Dexter: Resurrection',
          mediaType: 'tv',
        ),
        isNull,
      );
    });

    test('falls back to the background when the exact match has no poster',
        () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          data: _dexterSearchBody(noPoster: true),
        ),
      );

      // The stub body above still carries the exact match's background.
      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: 'Dexter: Resurrection',
          mediaType: 'tv',
        ),
        'https://images.metahub.space/background/medium/tt33043892/img',
      );
    });

    test('returns null for an empty title or bad type without a request',
        () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, data: _dexterSearchBody()),
      );

      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: '   ',
          mediaType: 'tv',
        ),
        isNull,
      );
      expect(
        await stub.resolver.resolveKeylessByTitle(
          title: 'Dexter: Resurrection',
          mediaType: 'person',
        ),
        isNull,
      );
      expect(stub.requests, isEmpty);
    });

    test('parses the poster from a raw catalog-search response', () {
      expect(
        DiscordArtworkResolver.posterUrlFromCinemetaSearchResponse(
          _dexterSearchBody(),
          query: 'Dexter: Resurrection',
        ),
        contains('m.media-amazon.com'),
      );
      expect(
        DiscordArtworkResolver.posterUrlFromCinemetaSearchResponse(
          {'metas': <Map<String, dynamic>>[]},
          query: 'Dexter: Resurrection',
        ),
        isNull,
      );
    });
  });

  group('Discord poster fetch verification (redirects and failures)', () {
    test('follows a HEAD redirect via a ranged GET (episode still shape)',
        () async {
      const episodeThumb =
          'https://episodes.metahub.space/tt33043892/0/1/w780.jpg';
      final stub = stubbedResolver((options) {
        if (options.method == 'HEAD') {
          // episodes.metahub.space 301s to image.tmdb.org; the HEAD stack
          // does not always follow that, so the verifier must fall through
          // to a ranged GET instead of dropping the candidate.
          return _response(
            options,
            status: 301,
            location:
                'https://image.tmdb.org/t/p/w780/tLjsB8eTB3EGMegxPNwoanPdcZM.jpg',
          );
        }
        return _response(options, status: 206, contentType: 'image/jpeg');
      });

      expect(await stub.resolver.verifyPosterUrl(episodeThumb), isTrue);
      expect(stub.requests, hasLength(2));
      expect(stub.requests[0].method, 'HEAD');
      expect(stub.requests[1].method, 'GET');
      expect(stub.requests[1].headers['Range'], 'bytes=0-1023');
    });

    test('retries with a ranged GET when HEAD throws', () async {
      final stub = stubbedResolverWithReject((options, handler) {
        if (options.method == 'HEAD') {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.connectionTimeout,
            ),
          );
          return;
        }
        handler.resolve(
          _response(options, status: 206, contentType: 'image/webp'),
        );
      });

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.metahub.space/poster/medium/tt33043892/img',
        ),
        isTrue,
      );
      expect(stub.requests, hasLength(2));
    });

    test('still rejects a 200 HEAD that is not an image', () async {
      final stub = stubbedResolver(
        (options) => _response(options, status: 200, contentType: 'text/html'),
      );

      expect(
        await stub.resolver.verifyPosterUrl(
          'https://images.example.org/posters/not-an-image.jpg',
        ),
        isFalse,
      );
      expect(stub.requests, hasLength(1));
    });

    test('accepts the Dexter-like hosts Discord serves (webp, Blogger, TMDB)',
        () async {
      final stub = stubbedResolver(
        (options) => _response(
          options,
          status: 200,
          contentType: options.uri.host == 'images.metahub.space'
              ? 'image/webp'
              : 'image/jpeg',
        ),
      );

      for (final url in [
        'https://images.metahub.space/poster/medium/tt33043892/img',
        'https://blogger.googleusercontent.com/img/b/R29vZ2xl/AVvXsEg/s600/poster.jpg',
        'https://image.tmdb.org/t/p/w500/zn3IXZzGavH3qle3o3g1r32eXDy.jpg',
      ]) {
        expect(await stub.resolver.verifyPosterUrl(url), isTrue, reason: url);
      }
    });
  });

  group('Discord presence artwork reaches the activity after verification',
      () {
    // The service is a singleton, so each test drives it with a distinct
    // title (distinct lookup key) and resets it first. The Gateway socket
    // is never connected in tests, so the observable proof is the verified
    // poster state plus the activity that state builds: the force-resend
    // in _refreshVerifiedPoster sends exactly that activity once the
    // socket is live.
    late DiscordPresenceService service;

    setUp(() async {
      service = DiscordPresenceService.instance;
      await service.clearActivity();
    });

    Future<void> watchDexter({
      required DiscordArtworkResolver resolver,
      required List<String> posterUrls,
      String? imdbId,
    }) async {
      service.setArtworkResolverForTest(resolver);
      await service.updateWatching(
        title: 'Dexter: Resurrection · S1 E1',
        state: 'Episode 1',
        posterUrls: posterUrls,
        tmdbSearchTitle: 'Dexter: Resurrection',
        tmdbMediaType: 'tv',
        imdbId: imdbId,
        position: const Duration(seconds: 14),
        duration: const Duration(minutes: 51, seconds: 24),
        playing: true,
      );
      await _waitForArtwork(service);
    }

    test(
      'a series without an IMDb id keeps the item poster when the episode '
      'still fails verification',
      () async {
        const episodeThumb =
            'https://episodes.metahub.space/tt33043892/0/1/w780.jpg';
        const itemPoster =
            'https://images.metahub.space/poster/small/tt33043892/img';
        final stub = stubbedResolver((options) {
          final url = options.uri.toString();
          if (url == episodeThumb) {
            return _response(options, status: 404, contentType: 'text/html');
          }
          return _response(options, status: 200, contentType: 'image/webp');
        });

        await watchDexter(
          resolver: stub.resolver,
          posterUrls: [episodeThumb, itemPoster],
        );

        expect(service.currentPosterUrl, itemPoster);
        expect(service.lastPosterSource, 'extension');
        // The activity the resend carries has the cover — the old code
        // discarded the item poster with the failed still and sent none.
        final activity = DiscordPresenceService.buildActivity(
          title: 'Dexter: Resurrection · S1 E1',
          posterUrl: service.currentPosterUrl,
          position: const Duration(seconds: 14),
          duration: const Duration(minutes: 51, seconds: 24),
          playing: true,
        );
        expect(
          (activity['assets'] as Map<String, dynamic>)['large_image'],
          itemPoster,
        );
        // The title-search fallback was never needed, so it was never hit.
        expect(
          stub.requests.any(
            (r) => r.uri.toString().contains('/catalog/'),
          ),
          isFalse,
        );
      },
    );

    test(
      'a series without an IMDb id falls back to the Cinemeta title search '
      'when all extension artwork fails',
      () async {
        const episodeThumb =
            'https://episodes.metahub.space/tt33043892/0/1/w780.jpg';
        const itemPoster =
            'https://images.metahub.space/poster/small/tt33043892/img';
        const titleSearchPoster =
            'https://m.media-amazon.com/images/M/MV5BMWFmZDE2OTktOWY1Yi00ZTBiLWE3NWUtMzdmNTM1ZmQ0ZGQzXkEyXkFqcGc@._V1_SX250.jpg';
        final stub = stubbedResolver((options) {
          final url = options.uri.toString();
          if (url.contains('/catalog/series/top/search=')) {
            return _response(options, status: 200, data: _dexterSearchBody());
          }
          if (url == titleSearchPoster) {
            return _response(options, status: 200, contentType: 'image/jpeg');
          }
          return _response(options, status: 404, contentType: 'text/html');
        });

        await watchDexter(
          resolver: stub.resolver,
          posterUrls: [episodeThumb, itemPoster],
        );

        expect(service.currentPosterUrl, titleSearchPoster);
        expect(service.lastPosterSource, 'cinemeta');
        expect(
          stub.requests.any(
            (r) => r.uri.toString().contains(
              '/catalog/series/top/search=Dexter%3A%20Resurrection.json',
            ),
          ),
          isTrue,
        );
      },
    );

    test(
      'a series with an IMDb id uses the Cinemeta meta endpoint when '
      'extension artwork fails',
      () async {
        const episodeThumb =
            'https://episodes.metahub.space/tt33043892/0/1/w780.jpg';
        const cinemetaPoster =
            'https://images.metahub.space/poster/medium/tt33043892/img';
        final stub = stubbedResolver((options) {
          final url = options.uri.toString();
          if (url ==
              'https://v3-cinemeta.strem.io/meta/series/tt33043892.json') {
            return _response(options, status: 200, data: _dexterMetaBody);
          }
          if (url == cinemetaPoster) {
            return _response(options, status: 200, contentType: 'image/webp');
          }
          return _response(options, status: 404, contentType: 'text/html');
        });

        await watchDexter(
          resolver: stub.resolver,
          posterUrls: [episodeThumb],
          imdbId: 'tt33043892',
        );

        expect(service.currentPosterUrl, cinemetaPoster);
        expect(service.lastPosterSource, 'cinemeta');
        // The IMDb-id path answered, so the title search was never needed.
        expect(
          stub.requests.any(
            (r) => r.uri.toString().contains('/catalog/'),
          ),
          isFalse,
        );
      },
    );

    test('no cover anywhere leaves the activity imageless, never a dead key',
        () async {
      final stub = stubbedResolver((options) {
        if (options.uri.toString().contains('/catalog/')) {
          return _response(
            options,
            status: 200,
            data: {
              'metas': [
                {
                  'id': 'tt13030378',
                  'type': 'series',
                  'name': 'Dexter: New Blood',
                },
              ],
            },
          );
        }
        return _response(options, status: 404, contentType: 'text/html');
      });

      await watchDexter(
        resolver: stub.resolver,
        posterUrls: [
          'https://episodes.metahub.space/tt33043892/0/1/w780.jpg',
          'https://images.metahub.space/poster/small/tt33043892/img',
        ],
      );

      expect(service.currentPosterUrl, isNull);
      expect(service.lastPosterSource, 'none');
      expect(service.lastArtworkNote, contains('did not verify'));
      final activity = DiscordPresenceService.buildActivity(
        title: 'Dexter: Resurrection · S1 E1',
        posterUrl: service.currentPosterUrl,
        position: const Duration(seconds: 14),
        duration: const Duration(minutes: 51, seconds: 24),
        playing: true,
      );
      expect(activity.containsKey('assets'), isFalse);
    });
  });
}
