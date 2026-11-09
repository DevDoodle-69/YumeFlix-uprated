import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/features/together/guest_auto_open.dart';
import 'package:yumeflix/features/together/guest_title_resolver.dart';
import 'package:yumeflix/features/together/models.dart';

/// 2.13.0 resolver bounds + parallelism + progress, with fake time.
///
/// The contract: tiers 1 (episode token + provider pre-resolve) and 2
/// (detail URL) run IN PARALLEL — the open takes the slower tier, not
/// the sum — every stage is bounded (details 15 s, streams 20 s, title
/// search 30 s absolute, 90 s total), slow tiers at 300–500 ms still
/// succeed, and a failure carries tier-by-tier diagnostics plus the
/// progress steps the guest's screen shows. Nothing here may hang
/// forever: the worst case is a bounded failure, never an infinite
/// "Opening…".
void main() {
  /// "The Garden of Words" as the host shares it: movie, provider,
  /// source, episode token AND detail URL — both parallel tiers known.
  const gardenMedia = TogetherMediaIdentity(
    title: 'The Garden of Words',
    tmdbType: 'movie',
    tmdbId: 999001,
    posterUrl: 'https://example.invalid/garden.jpg',
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/garden',
    episodeUrl: 'https://example.invalid/garden-play',
    source: 'Server 1',
  );

  final gardenItem = MultimediaItem(
    title: 'The Garden of Words',
    url: 'https://example.invalid/garden',
    posterUrl: 'https://example.invalid/garden.jpg',
    contentType: MultimediaContentType.movie,
    tmdbId: 999001,
    provider: 'MovieSubLK',
    episodes: <Episode>[
      Episode(
        name: 'The Garden of Words',
        url: 'https://example.invalid/garden-play',
      ),
    ],
  );

  Future<List<StreamResult>> noStreams(
    MultimediaItem item,
    String episodeUrl,
  ) async => const <StreamResult>[];

  Stream<List<MultimediaItem>> noSearch(String query) =>
      Stream<List<MultimediaItem>>.value(const <MultimediaItem>[]);

  /// Runs [resolveGuestTitle] capturing its outcome into the two
  /// cells, so fakeAsync tests can assert on it after elapsing time.
  void captureResolve(
    Future<GuestTitleResolution> future, {
    required void Function(GuestTitleResolution?) onDone,
    required void Function(Object) onFailure,
  }) {
    unawaited(() async {
      try {
        onDone(await future);
      } catch (e) {
        onFailure(e);
      }
    }());
  }

  group('parallel tiers + stage timings', () {
    test('tier 1 + tier 2 run in parallel — 300 ms + 300 ms takes ~300 ms',
        () {
      fakeAsync((async) {
        GuestTitleResolution? resolution;
        Object? failure;
        captureResolve(
          resolveGuestTitle(
            identity: gardenMedia,
            loadDetails: (_) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              return gardenItem;
            },
            loadStreams: (_, _) async {
              await Future<void>.delayed(const Duration(milliseconds: 300));
              return const <StreamResult>[
                StreamResult(
                  url: 'https://example.invalid/s1',
                  source: 'Server 1',
                ),
              ];
            },
            searchTitles: noSearch,
          ),
          onDone: (r) => resolution = r,
          onFailure: (e) => failure = e,
        );
        // Serial tiers would still be waiting at 550 ms; parallel
        // tiers are both done at ~300 ms.
        async.elapse(const Duration(milliseconds: 299));
        expect(resolution, isNull);
        expect(failure, isNull);
        async.elapse(const Duration(milliseconds: 50));
        expect(failure, isNull);
        expect(resolution, isNotNull);
        expect(
          resolution!.videoUrl,
          'https://example.invalid/garden-play',
        );
        expect(resolution!.preloadedStreams.single.source, 'Server 1');
      });
    });

    test('slow tiers at 500 ms still succeed — no short timeout', () {
      fakeAsync((async) {
        GuestTitleResolution? resolution;
        resolveGuestTitle(
          identity: gardenMedia,
          loadDetails: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            return gardenItem;
          },
          loadStreams: (_, _) async {
            await Future<void>.delayed(const Duration(milliseconds: 500));
            return const <StreamResult>[
              StreamResult(
                url: 'https://example.invalid/s1',
                source: 'Server 1',
              ),
            ];
          },
          searchTitles: noSearch,
        ).then((r) => resolution = r);
        async.elapse(const Duration(milliseconds: 550));
        expect(resolution, isNotNull);
        expect(
          resolution!.videoUrl,
          'https://example.invalid/garden-play',
        );
      });
    });

    test('progress steps run findingTitle → gettingStream → openingPlayer',
        () async {
      final steps = <GuestResolveStep>[];
      final resolution = await resolveGuestTitle(
        identity: gardenMedia,
        loadDetails: (_) async => gardenItem,
        loadStreams: (_, _) async => const <StreamResult>[
          StreamResult(url: 'https://example.invalid/s1', source: 'Server 1'),
        ],
        searchTitles: noSearch,
        onProgress: steps.add,
      );
      expect(resolution.videoUrl, 'https://example.invalid/garden-play');
      expect(steps, <GuestResolveStep>[
        GuestResolveStep.findingTitle,
        GuestResolveStep.gettingStream,
        GuestResolveStep.openingPlayer,
      ]);
    });
  });

  group('bounded stages — never an infinite Opening…', () {
    test('details load hanging fails at the 15 s tier bound, with '
        'diagnostics', () {
      fakeAsync((async) {
        GuestTitleResolution? resolution;
        Object? failure;
        captureResolve(
          resolveGuestTitle(
            identity: gardenMedia,
            // Hangs forever: the old code awaited this with no timeout.
            loadDetails: (_) => Completer<MultimediaItem?>().future,
            loadStreams: (_, _) async => throw StateError('no streams'),
            searchTitles: noSearch,
          ),
          onDone: (r) => resolution = r,
          onFailure: (e) => failure = e,
        );
        async.elapse(const Duration(seconds: 14));
        expect(resolution, isNull);
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(resolution, isNull);
        expect(failure, isA<GuestTitleResolutionFailure>());
        final diagnostics =
            (failure as GuestTitleResolutionFailure).diagnostics ?? '';
        expect(diagnostics, contains('details load timed out after 15s'));
        expect(diagnostics, contains('title search found no exact match'));
      });
    });

    test('trickling search fails at the absolute 30 s budget', () {
      fakeAsync((async) {
        // No token, no detail URL: tier 3 is the only tier.
        const searchOnly = TogetherMediaIdentity(
          title: 'The Garden of Words',
          tmdbType: 'movie',
          tmdbId: 999001,
          provider: 'MovieSubLK',
        );
        final controller = StreamController<List<MultimediaItem>>();
        final ticker = Timer.periodic(const Duration(seconds: 5), (_) {
          if (!controller.isClosed) {
            controller.add(<MultimediaItem>[
              MultimediaItem(
                title: 'A Different Film',
                url: 'https://example.invalid/other',
                posterUrl: '',
                contentType: MultimediaContentType.movie,
              ),
            ]);
          }
        });
        GuestTitleResolution? resolution;
        Object? failure;
        captureResolve(
          resolveGuestTitle(
            identity: searchOnly,
            loadDetails: (_) async => null,
            loadStreams: noStreams,
            searchTitles: (_) => controller.stream,
          ),
          onDone: (r) => resolution = r,
          onFailure: (e) => failure = e,
        );
        // Batches keep trickling in — the old per-event timeout reset
        // on every batch, so this never ended. The absolute budget
        // ends it at 30 s regardless.
        async.elapse(const Duration(seconds: 29));
        expect(resolution, isNull);
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(failure, isA<GuestTitleResolutionFailure>());
        expect(
          (failure as GuestTitleResolutionFailure).diagnostics,
          contains('title search found no exact match'),
        );
        ticker.cancel();
        unawaited(controller.close());
      });
    });

    test('everything hanging fails well inside the 90 s total cap', () {
      fakeAsync((async) {
        GuestTitleResolution? resolution;
        Object? failure;
        captureResolve(
          resolveGuestTitle(
            identity: gardenMedia,
            loadDetails: (_) => Completer<MultimediaItem?>().future,
            loadStreams: (_, _) => Completer<List<StreamResult>>().future,
            searchTitles: (_) => Completer<List<MultimediaItem>>().future
                .asStream(),
          ),
          onDone: (r) => resolution = r,
          onFailure: (e) => failure = e,
        );
        // The per-tier bounds end it first — streams at 20 s, then the
        // search at its 30 s absolute budget — so the failure lands at
        // ~50 s, comfortably inside the 90 s total cap that stands
        // behind them as a backstop.
        async.elapse(const Duration(seconds: 49));
        expect(resolution, isNull);
        expect(failure, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(failure, isA<GuestTitleResolutionFailure>());
      });
    });
  });

  group('title matching', () {
    test('provider year suffix does not break the match', () {
      final withYear = MultimediaItem(
        title: 'The Garden of Words (2013)',
        url: 'https://example.invalid/garden',
        posterUrl: '',
        contentType: MultimediaContentType.movie,
        tmdbId: 999001,
        provider: 'MovieSubLK',
      );
      expect(pickSearchMatch([withYear], gardenMedia), isNotNull);
      expect(
        pickSearchMatch([withYear], gardenMedia)?.url,
        'https://example.invalid/garden',
      );
    });

    test('same title + same provider share one open key', () {
      expect(
        guestAutoOpenKey(gardenMedia),
        togetherTitleKey(gardenMedia),
      );
      const otherSource = TogetherMediaIdentity(
        title: 'The Garden of Words',
        tmdbType: 'movie',
        tmdbId: 999001,
        posterUrl: 'https://example.invalid/garden.jpg',
        provider: 'MovieSubLK',
        itemUrl: 'https://example.invalid/garden',
        episodeUrl: 'https://example.invalid/garden-play',
        source: 'Server 2',
      );
      expect(
        guestAutoOpenKey(gardenMedia) == guestAutoOpenKey(otherSource),
        isFalse,
      );
    });
  });
}
