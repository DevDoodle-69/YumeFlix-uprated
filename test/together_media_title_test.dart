import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/core/providers/device_info_provider.dart';
import 'package:yumeflix/core/services/discord_presence_service.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/together_screen.dart';
import 'package:yumeflix/features/together/together_player_hook.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.9.0 Bug 2 — a movie must never carry an "S1 E1" suffix anywhere.
///
/// The room title used to be built in [togetherMediaIdentityFor] from the
/// raw route episode, which for a film is the plugin's dummy one-episode
/// show (S1 E1): the room card then read
/// "Harry Potter and the Philosopher's Stone · S1 E1" with a second
/// "S1 E1" line underneath from `episodeLabel`. The one title rule
/// ([DiscordPresenceService.formatWatchingTitle]) already protected the
/// Discord title and the player titles; the room identity now reuses it,
/// the wire boundary sanitises poisoned 2.8.0 payloads, and the room card
/// prints the S/E line at most once.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const movieTitle = "Harry Potter and the Philosopher's Stone";

  MultimediaItem movieItem() => MultimediaItem(
    title: movieTitle,
    url: 'https://example.invalid/hp',
    posterUrl: 'https://example.invalid/hp.jpg',
    contentType: MultimediaContentType.movie,
    tmdbId: 671,
  );

  MultimediaItem seriesItem() => MultimediaItem(
    title: 'Breaking Bad',
    url: 'https://example.invalid/bb',
    posterUrl: 'https://example.invalid/bb.jpg',
    contentType: MultimediaContentType.series,
    tmdbId: 1396,
  );

  /// The dummy episode plugins file a film as: season 1, episode 1.
  Episode dummyMovieEpisode() => Episode(
    name: movieTitle,
    url: 'https://example.invalid/hp-ep',
    season: 1,
    episode: 1,
  );

  Episode seriesEpisode() => Episode(
    name: 'Cat\'s in the Bag...',
    url: 'https://example.invalid/bb-s2e3',
    season: 2,
    episode: 3,
  );

  group('togetherMediaIdentityFor', () {
    test('movie with a dummy S1 E1 episode -> clean title, no label', () {
      final media = togetherMediaIdentityFor(
        item: movieItem(),
        episode: dummyMovieEpisode(),
      );
      expect(media.title, movieTitle);
      expect(media.episodeLabel, isNull);
      expect(media.tmdbType, 'movie');
    });

    test('movie with no episode -> clean title, no label', () {
      final media = togetherMediaIdentityFor(item: movieItem());
      expect(media.title, movieTitle);
      expect(media.episodeLabel, isNull);
    });

    test('movie with S0 E0 episode -> clean title, no label', () {
      final media = togetherMediaIdentityFor(
        item: movieItem(),
        episode: Episode(
          name: movieTitle,
          url: 'https://example.invalid/hp-ep0',
          season: 0,
          episode: 0,
        ),
      );
      expect(media.title, movieTitle);
      expect(media.episodeLabel, isNull);
    });

    test('series S2 E3 -> suffix once in title, once as label', () {
      final media = togetherMediaIdentityFor(
        item: seriesItem(),
        episode: seriesEpisode(),
      );
      expect(media.title, 'Breaking Bad · S2 E3');
      expect(media.episodeLabel, 'S2 E3');
      expect(media.tmdbType, 'tv');
    });

    test('series with S0 E0 episode -> clean title, no label', () {
      final media = togetherMediaIdentityFor(
        item: seriesItem(),
        episode: Episode(
          name: 'Pilot',
          url: 'https://example.invalid/bb-ep0',
          season: 0,
          episode: 0,
        ),
      );
      expect(media.title, 'Breaking Bad');
      expect(media.episodeLabel, isNull);
    });

    test('anime episode keeps its suffix', () {
      final media = togetherMediaIdentityFor(
        item: MultimediaItem(
          title: 'Naruto',
          url: 'https://example.invalid/naruto',
          posterUrl: 'https://example.invalid/naruto.jpg',
          contentType: MultimediaContentType.anime,
        ),
        episode: Episode(
          name: 'Enter: Naruto Uzumaki!',
          url: 'https://example.invalid/naruto-e1',
          season: 1,
          episode: 1,
        ),
      );
      expect(media.title, 'Naruto · S1 E1');
      expect(media.episodeLabel, 'S1 E1');
    });
  });

  group('the one title rule (Discord)', () {
    test('movie + dummy S1 E1 -> clean Discord title', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: movieTitle,
          isSeries: false,
          season: 1,
          episode: 1,
        ),
        movieTitle,
      );
    });

    test('series S2 E3 -> suffix exactly once', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Breaking Bad',
          isSeries: true,
          season: 2,
          episode: 3,
        ),
        'Breaking Bad · S2 E3',
      );
    });
  });

  group('TogetherMediaIdentity.fromJson (wire boundary)', () {
    test('poisoned 2.8.0 movie payload -> clean title, no label', () {
      final media = TogetherMediaIdentity.fromJson(<String, dynamic>{
        'title': '$movieTitle · S1 E1',
        'tmdbType': 'movie',
        'tmdbId': 671,
        'posterUrl': 'https://example.invalid/hp.jpg',
        'episodeLabel': 'S1 E1',
      });
      expect(media.title, movieTitle);
      expect(media.episodeLabel, isNull);
    });

    test('clean movie payload is unchanged', () {
      final media = TogetherMediaIdentity.fromJson(<String, dynamic>{
        'title': movieTitle,
        'tmdbType': 'movie',
        'tmdbId': 671,
      });
      expect(media.title, movieTitle);
      expect(media.episodeLabel, isNull);
    });

    test('series payload keeps title and label', () {
      final media = TogetherMediaIdentity.fromJson(<String, dynamic>{
        'title': 'Breaking Bad · S2 E3',
        'tmdbType': 'tv',
        'tmdbId': 1396,
        'episodeLabel': 'S2 E3',
      });
      expect(media.title, 'Breaking Bad · S2 E3');
      expect(media.episodeLabel, 'S2 E3');
      expect(media.titleCarriesEpisodeLabel, isTrue);
    });

    test('titleCarriesEpisodeLabel is false for a bare title', () {
      const media = TogetherMediaIdentity(
        title: 'Breaking Bad',
        tmdbType: 'tv',
        episodeLabel: 'S2 E3',
      );
      expect(media.titleCarriesEpisodeLabel, isFalse);
    });
  });

  group('Together room card', () {
    TogetherService hostWith(TogetherMediaIdentity media) {
      // Owned by the ProviderScope in pumpScreen: Riverpod disposes the
      // override's notifier when the scope goes away, so no tearDown here
      // (disposing twice throws).
      final service = TogetherService(
        random: Random(42),
        preferences: null,
      );
      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '529605');
      service.attachMedia(media);
      return service;
    }

    Future<void> pumpScreen(
      WidgetTester tester,
      TogetherService service,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            togetherServiceProvider.overrideWith((ref) => service),
            deviceProfileProvider.overrideWith(
              (ref) async => const DeviceProfile(),
            ),
          ],
          child: const MaterialApp(home: TogetherScreen()),
        ),
      );
      await tester.pump();
    }

    /// Every `Text` in the pumped tree, joined — the S/E suffix must
    /// appear in the room card exactly this many times in total.
    int countOccurrences(WidgetTester tester, String needle) {
      final texts = tester.widgetList<Text>(find.byType(Text));
      var count = 0;
      for (final text in texts) {
        final data = text.data ?? '';
        var index = data.indexOf(needle);
        while (index >= 0) {
          count++;
          index = data.indexOf(needle, index + needle.length);
        }
      }
      return count;
    }

    testWidgets('movie room card shows no S1 E1 anywhere', (tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = hostWith(
        togetherMediaIdentityFor(
          item: movieItem(),
          episode: dummyMovieEpisode(),
        ),
      );
      await pumpScreen(tester, service);
      expect(find.text(movieTitle), findsOneWidget);
      expect(countOccurrences(tester, 'S1 E1'), 0);
    });

    testWidgets('series room card shows S2 E3 exactly once', (tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = hostWith(
        togetherMediaIdentityFor(
          item: seriesItem(),
          episode: seriesEpisode(),
        ),
      );
      await pumpScreen(tester, service);
      expect(find.text('Breaking Bad · S2 E3'), findsOneWidget);
      expect(countOccurrences(tester, 'S2 E3'), 1);
    });
  });
}
