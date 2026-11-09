import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/core/storage/history_repository.dart';
import 'package:yumeflix/features/together/guest_auto_open.dart';
import 'package:yumeflix/features/together/guest_title_resolver.dart';
import 'package:yumeflix/features/together/history_pick.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.12.0 host picks from history: a Continue Watching entry becomes
/// the Together title — same title/episode, same provider, resumed at
/// the saved position — and Start then shares exactly that with every
/// guest. Pure mapping is pinned here; the player resume itself is the
/// existing `resolveResumePoint` lookup on the same stored position,
/// and the service half (attach + go-live publishes the saved
/// position) is pinned through the test seams. No relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  HistoryItem historyMovie({
    int position = 1800000,
    int duration = 7200000,
    String? provider = 'MovieSubLK',
  }) => HistoryItem(
    item: MultimediaItem(
      title: 'Dune',
      url: 'https://example.invalid/dune',
      posterUrl: 'https://example.invalid/dune.jpg',
      contentType: MultimediaContentType.movie,
      provider: provider,
      tmdbId: 438631,
    ),
    position: position,
    duration: duration,
    timestamp: 1700000000000,
  );

  HistoryItem historyEpisode({
    int position = 900000,
    int duration = 3000000,
    String? provider = 'MovieSubLK',
  }) => HistoryItem(
    item: MultimediaItem(
      title: 'Dexter',
      url: 'https://example.invalid/dexter',
      posterUrl: 'https://example.invalid/dexter.jpg',
      contentType: MultimediaContentType.series,
      provider: provider,
      tmdbId: 427049,
    ),
    position: position,
    duration: duration,
    lastEpisodeUrl: 'https://example.invalid/dexter-s1-e2',
    season: 1,
    episode: 2,
    episodeTitle: 'Episode 2',
    episodePosterUrl: 'https://example.invalid/dexter-s1-e2.jpg',
    timestamp: 1700000000000,
  );

  group('history -> Together identity', () {
    test('movie keeps title, provider, poster and resume position', () {
      final pick = togetherPickForHistory(historyMovie());
      expect(pick, isNotNull);
      expect(pick!.identity.title, 'Dune');
      expect(pick.identity.tmdbType, 'movie');
      expect(pick.identity.tmdbId, 438631);
      expect(pick.identity.provider, 'MovieSubLK');
      expect(pick.identity.itemUrl, 'https://example.invalid/dune');
      expect(pick.identity.posterUrl, 'https://example.invalid/dune.jpg');
      expect(pick.identity.season, isNull);
      expect(pick.identity.episode, isNull);
      expect(pick.episode, isNull);
      expect(pick.resumePositionMs, 1800000);
      expect(pick.providerFallbackNotice, isNull);
    });

    test('series keeps the exact episode, never another one', () {
      final pick = togetherPickForHistory(historyEpisode());
      expect(pick, isNotNull);
      expect(pick!.identity.title, 'Dexter · S1 E2');
      expect(pick.identity.tmdbType, 'tv');
      expect(pick.identity.episodeLabel, 'S1 E2');
      expect(pick.identity.season, 1);
      expect(pick.identity.episode, 2);
      expect(pick.identity.provider, 'MovieSubLK');
      expect(pick.identity.episodeUrl, 'https://example.invalid/dexter-s1-e2');
      // The player opens with this episode token — the guest resolves
      // the same token, so it gets S1 E2, never S1 E1.
      expect(pick.episode, isNotNull);
      expect(pick.episode!.url, 'https://example.invalid/dexter-s1-e2');
      expect(pick.episode!.season, 1);
      expect(pick.episode!.episode, 2);
      expect(pick.resumePositionMs, 900000);
    });

    test('series resume uses the episode poster', () {
      final pick = togetherPickForHistory(historyEpisode());
      expect(
        pick!.identity.posterUrl,
        'https://example.invalid/dexter-s1-e2.jpg',
      );
    });

    test('no provider: still opens, with a notice, on the best source', () {
      final pick = togetherPickForHistory(historyMovie(provider: null));
      expect(pick, isNotNull);
      expect(pick!.identity.provider, isNull);
      expect(pick.providerFallbackNotice, isNotNull);
      expect(pick.providerFallbackNotice, contains('best available source'));
      expect(pick.resumePositionMs, 1800000);
    });

    test('no provider on a series entry also carries the notice', () {
      final pick = togetherPickForHistory(historyEpisode(provider: ''));
      expect(pick!.providerFallbackNotice, isNotNull);
      expect(pick.identity.season, 1);
      expect(pick.identity.episode, 2);
    });
  });

  group('resume position', () {
    test('mid-title resumes at the saved position', () {
      expect(historyResumePositionMs(historyMovie()), 1800000);
    });

    test('past 90% does not resume — the title is finished', () {
      expect(historyResumePositionMs(historyMovie(position: 7000000)), 0);
    });

    test('under 1% does not resume — barely started', () {
      expect(historyResumePositionMs(historyMovie(position: 1000)), 0);
    });

    test('a clip under 30 s does not resume', () {
      final item = historyMovie(position: 10000, duration: 20000);
      expect(historyResumePositionMs(item), 0);
    });

    test('no stored position resumes at 0', () {
      expect(historyResumePositionMs(historyMovie(position: 0)), 0);
    });
  });

  group('stale entries', () {
    test('empty title is stale, with a search message', () {
      final item = HistoryItem(
        item: MultimediaItem(
          title: '',
          url: 'https://example.invalid/x',
          posterUrl: '',
        ),
        position: 1000,
        duration: 60000,
        timestamp: 0,
      );
      expect(historyPickProblem(item), HistoryPickProblem.emptyTitle);
      expect(togetherPickForHistory(item), isNull);
      expect(historyItemIsPlayable(item), isFalse);
    });

    test('empty URL is stale', () {
      final item = HistoryItem(
        item: MultimediaItem(title: 'Dune', url: '', posterUrl: ''),
        position: 1000,
        duration: 60000,
        timestamp: 0,
      );
      expect(historyPickProblem(item), HistoryPickProblem.emptyUrl);
      expect(togetherPickForHistory(item), isNull);
    });

    test('a live stream cannot be shared in Together', () {
      final item = HistoryItem(
        item: MultimediaItem(
          title: 'News 24',
          url: 'https://example.invalid/live',
          posterUrl: '',
          contentType: MultimediaContentType.livestream,
        ),
        position: 0,
        duration: 0,
        timestamp: 0,
      );
      expect(historyPickProblem(item), HistoryPickProblem.livestream);
      expect(togetherPickForHistory(item), isNull);
    });

    test('stale message offers search instead of a dead tap', () {
      expect(
        historyPickProblemMessage(HistoryPickProblem.emptyUrl),
        contains('searching'),
      );
    });
  });

  group('host Start shares the history pick', () {
    TogetherService newService() =>
        TogetherService(random: Random(42), preferences: null);

    test('go-live publishes the saved position with the stored provider', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final pick = togetherPickForHistory(historyMovie())!;
      host.attachMedia(pick.identity);
      // The host's player is at the saved position when Start is
      // tapped; go-live publishes exactly that, with the stored
      // provider and source — the guest auto-opens the same title on
      // the same provider at the host's position.
      host.goLive(
        positionMs: pick.resumePositionMs,
        durationMs: 7200000,
        playing: true,
      );
      host.debugGuestReadyForTest();
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, isNotEmpty);
      final state = states.last;
      expect(state['positionMs'], 1800000);
      expect(state['playing'], isTrue);
      final media = Map<String, dynamic>.from(state['media'] as Map);
      expect(media['title'], 'Dune');
      expect(media['provider'], 'MovieSubLK');
      expect(media['tmdbId'], 438631);
    });

    test('series history pick goes live on the exact episode', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final pick = togetherPickForHistory(historyEpisode())!;
      host.attachMedia(pick.identity);
      host.goLive(
        positionMs: pick.resumePositionMs,
        durationMs: 3000000,
        playing: true,
      );
      final states = published.where((p) => p['kind'] == 'state').toList();
      final media = Map<String, dynamic>.from(states.last['media'] as Map);
      expect(media['title'], 'Dexter · S1 E2');
      expect(media['season'], 1);
      expect(media['episode'], 2);
      expect(media['episodeUrl'], 'https://example.invalid/dexter-s1-e2');
      expect(states.last['positionMs'], 900000);
    });

    test('guest auto-open policy opens the history title on go-live', () {
      final pick = togetherPickForHistory(historyEpisode())!;
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: pick.identity,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
      // And the open key separates episodes: S1 E2 is not S1 E1.
      const other = TogetherMediaIdentity(
        title: 'Dexter · S1 E1',
        tmdbType: 'tv',
        tmdbId: 427049,
        episodeLabel: 'S1 E1',
        season: 1,
        episode: 1,
        provider: 'MovieSubLK',
        itemUrl: 'https://example.invalid/dexter',
        episodeUrl: 'https://example.invalid/dexter-s1-e1',
      );
      expect(
        guestAutoOpenKey(pick.identity) != guestAutoOpenKey(other),
        isTrue,
      );
    });
  });

  group('guest resolution carries the live start position', () {
    test('resolveGuestTitle threads startPositionMs through tier 1', () async {
      const identity = TogetherMediaIdentity(
        title: 'Dune',
        tmdbType: 'movie',
        tmdbId: 438631,
        provider: 'MovieSubLK',
        itemUrl: 'https://example.invalid/dune',
        episodeUrl: 'https://example.invalid/dune-play',
        source: 'Server 1',
      );
      final resolution = await resolveGuestTitle(
        identity: identity,
        loadDetails: (_) async => null,
        loadStreams: (_, _) async => const [
          StreamResult(url: 'https://example.invalid/a', source: 'Server 1'),
        ],
        searchTitles: (_) => const Stream<List<MultimediaItem>>.empty(),
        startPositionMs: 2700000,
      );
      expect(resolution.videoUrl, 'https://example.invalid/dune-play');
      expect(resolution.startPositionMs, 2700000);
      expect(resolution.preloadedStreams.first.source, 'Server 1');
    });

    test('resolveGuestTitle without a start position defaults to 0', () async {
      const identity = TogetherMediaIdentity(
        title: 'Dune',
        tmdbType: 'movie',
        tmdbId: 438631,
        provider: 'MovieSubLK',
        itemUrl: 'https://example.invalid/dune',
        episodeUrl: 'https://example.invalid/dune-play',
        source: 'Server 1',
      );
      final resolution = await resolveGuestTitle(
        identity: identity,
        loadDetails: (_) async => null,
        loadStreams: (_, _) async => const [
          StreamResult(url: 'https://example.invalid/a', source: 'Server 1'),
        ],
        searchTitles: (_) => const Stream<List<MultimediaItem>>.empty(),
      );
      expect(resolution.startPositionMs, 0);
    });
  });
}
