import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/features/together/guest_auto_open.dart';
import 'package:yumeflix/features/together/guest_title_resolver.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';
import 'package:yumeflix/features/together/together_player_hook.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.11.0 guest auto-open, offline through the service's test seams
/// (publish sink + inbound payload feed) — no relay, no network.
///
/// The contract: the moment the host goes live, the guest's phone opens
/// the SAME title on the SAME source — no tap — whether the guest was
/// already in the room or joins a room that is already live. A title or
/// source change mid-session switches the guest to it; a duplicate
/// go-live, a re-publish or a rejoin never stacks a second player; a
/// guest who backs out of a title is not forced back into it, but a new
/// title still opens. When the title cannot be resolved at all, the
/// guest gets the honest fallback line — never a silent stuck screen.
/// The policy itself is pure ([GuestAutoOpenPolicy.decide]) and pinned
/// here without a widget; the resolver's tiers are pinned through
/// [resolveGuestTitle] with stubbed providers.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService([int seed = 42]) =>
      TogetherService(random: Random(seed), preferences: null);

  const movieMedia = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/dune',
    episodeUrl: 'https://example.invalid/dune-play',
    source: 'Server 1',
  );

  const episodeMedia = TogetherMediaIdentity(
    title: 'Dexter: Resurrection · S1 E2',
    tmdbType: 'tv',
    tmdbId: 427049,
    posterUrl: 'https://example.invalid/dexter.jpg',
    episodeLabel: 'S1 E2',
    season: 1,
    episode: 2,
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/dexter',
    episodeUrl: 'https://example.invalid/dexter-s1-e2',
    source: 'Server 1',
  );

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    String hostId = 'host-1',
  }) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 600000,
        playing: playing,
        hostTimestampMs: stamp,
        sequence: sequence,
        hostId: hostId,
      ).toJson(),
    });
  }

  group('GuestAutoOpenPolicy', () {
    test('opens on go-live for a guest in the room', () {
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
    });

    test('opens when the guest joins an already-live room', () {
      // Join-if-already-live is the same room snapshot as go-live: a
      // guest, a live phase, a live title, no player yet. The coordinator
      // evaluates on the join notification itself — no heartbeat wait.
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: episodeMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
    });

    test('does not double-open the same title + source', () {
      final key = guestAutoOpenKey(movieMedia);
      // The player is still settling in after the push.
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: key,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
      // The player is open on exactly this title + source (a duplicate
      // go-live, a 1 s re-publish, a rejoin).
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: false,
          playerOpen: true,
          playerOpenMedia: movieMedia,
          openedKey: key,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
    });

    test('switches when the host changes title or source mid-session', () {
      final oldKey = guestAutoOpenKey(movieMedia);
      // New title, old player still up.
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: episodeMedia,
          hostGone: false,
          playerOpen: true,
          playerOpenMedia: movieMedia,
          openedKey: oldKey,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
      // Same title, host picked another source.
      final otherSource = movieMedia.withSource('Server 2');
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: otherSource,
          hostGone: false,
          playerOpen: true,
          playerOpenMedia: movieMedia,
          openedKey: oldKey,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
    });

    test('opt-out suppresses the same title but not a new one', () {
      final key = guestAutoOpenKey(movieMedia);
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: key,
        ),
        GuestAutoOpenAction.none,
      );
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: episodeMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: key,
        ),
        GuestAutoOpenAction.open,
      );
    });

    test('closes the auto-opened player when the host leaves', () {
      final key = guestAutoOpenKey(movieMedia);
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: true,
          playerOpen: true,
          playerOpenMedia: movieMedia,
          openedKey: key,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.closeToTogether,
      );
      // No auto-opened player up: nothing to close.
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: true,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
      // A player on another title is not ours to close.
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: movieMedia,
          hostGone: true,
          playerOpen: true,
          playerOpenMedia: episodeMedia,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
    });

    test('never opens for the host, before live, or with no title', () {
      for (final role in [TogetherRole.host, null]) {
        expect(
          GuestAutoOpenPolicy.decide(
            role: role,
            phase: TogetherPhase.live,
            liveMedia: movieMedia,
            hostGone: false,
            playerOpen: false,
            playerOpenMedia: null,
            openedKey: null,
            optedOutKey: null,
          ),
          GuestAutoOpenAction.none,
        );
      }
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.waitingGuest,
          liveMedia: movieMedia,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
      expect(
        GuestAutoOpenPolicy.decide(
          role: TogetherRole.guest,
          phase: TogetherPhase.live,
          liveMedia: null,
          hostGone: false,
          playerOpen: false,
          playerOpenMedia: null,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.none,
      );
    });
  });

  group('guestAutoOpenKey + resolver pure helpers', () {
    test('key separates titles, episodes, sources and tokens', () {
      expect(guestAutoOpenKey(movieMedia), isNot(guestAutoOpenKey(episodeMedia)));
      expect(
        guestAutoOpenKey(movieMedia),
        isNot(guestAutoOpenKey(movieMedia.withSource('Server 2'))),
      );
      expect(guestAutoOpenKey(movieMedia), guestAutoOpenKey(movieMedia));
    });

    test('base title strips the episode suffix; titles normalise', () {
      expect(baseTitleOf(episodeMedia), 'Dexter: Resurrection');
      expect(baseTitleOf(movieMedia), 'Dune');
      expect(normalizeTitle('  Dexter:  Resurrection '), 'dexter: resurrection');
    });

    test('buildItemForIdentity carries URL, provider and TMDB id', () {
      final item = buildItemForIdentity(episodeMedia);
      expect(item.title, 'Dexter: Resurrection');
      expect(item.url, 'https://example.invalid/dexter');
      expect(item.provider, 'MovieSubLK');
      expect(item.tmdbId, 427049);
      expect(item.contentType, MultimediaContentType.series);
      expect(
        buildItemForIdentity(movieMedia).contentType,
        MultimediaContentType.movie,
      );
    });

    test('pickEpisodeForIdentity matches exact S/E, never the wrong one', () {
      final episodes = <Episode>[
        Episode(name: 'S1 E1', url: 'https://example.invalid/e1', season: 1, episode: 1),
        Episode(name: 'S1 E2', url: 'https://example.invalid/e2', season: 1, episode: 2),
        Episode(name: 'S2 E1', url: 'https://example.invalid/s2e1', season: 2, episode: 1),
      ];
      expect(pickEpisodeForIdentity(episodes, episodeMedia)?.episode, 2);
      expect(pickEpisodeForIdentity(episodes, episodeMedia)?.season, 1);
      const missing = TogetherMediaIdentity(
        title: 'Dexter: Resurrection · S1 E9',
        tmdbType: 'tv',
        season: 1,
        episode: 9,
      );
      expect(pickEpisodeForIdentity(episodes, missing), isNull);
      // A film takes the first entry.
      expect(pickEpisodeForIdentity(episodes, movieMedia), episodes.first);
      expect(pickEpisodeForIdentity(<Episode>[], movieMedia), isNull);
    });

    test('pickSearchMatch needs the exact title + type, prefers TMDB id', () {
      final results = <MultimediaItem>[
        MultimediaItem(
          title: 'Dune',
          url: 'https://example.invalid/dune-other',
          posterUrl: '',
          contentType: MultimediaContentType.movie,
          tmdbId: 999,
        ),
        MultimediaItem(
          title: 'Dune',
          url: 'https://example.invalid/dune',
          posterUrl: '',
          contentType: MultimediaContentType.movie,
          tmdbId: 438631,
        ),
        MultimediaItem(
          title: 'Dune: Part Two',
          url: 'https://example.invalid/dune2',
          posterUrl: '',
          contentType: MultimediaContentType.movie,
          tmdbId: 693134,
        ),
        MultimediaItem(
          title: 'Dune',
          url: 'https://example.invalid/dune-series',
          posterUrl: '',
          contentType: MultimediaContentType.series,
        ),
      ];
      // The TMDB-id match wins over the first exact-title match.
      expect(pickSearchMatch(results, movieMedia)?.url, 'https://example.invalid/dune');
      // A near match is not the host's title.
      const other = TogetherMediaIdentity(
        title: 'Dune: Part Three',
        tmdbType: 'movie',
      );
      expect(pickSearchMatch(results, other), isNull);
      // A series result never answers for a film.
      const filmOnlySeries = TogetherMediaIdentity(
        title: 'Dune',
        tmdbType: 'movie',
      );
      final seriesOnly = results.where((r) => r.contentType == MultimediaContentType.series).toList();
      expect(pickSearchMatch(seriesOnly, filmOnlySeries), isNull);
    });

    test('orderStreamsForHostSource puts the host source first', () {
      final streams = <StreamResult>[
        const StreamResult(url: 'https://example.invalid/a', source: 'Server 2'),
        const StreamResult(url: 'https://example.invalid/b', source: 'Server 1'),
        const StreamResult(url: 'https://example.invalid/c', source: 'Server 3'),
      ];
      final ordered = orderStreamsForHostSource(streams, 'Server 1');
      expect(ordered.found, isTrue);
      expect(ordered.streams.first.source, 'Server 1');
      expect(ordered.streams.map((s) => s.source), ['Server 1', 'Server 2', 'Server 3']);
      final missing = orderStreamsForHostSource(streams, 'Server 9');
      expect(missing.found, isFalse);
      expect(missing.streams.map((s) => s.source), ['Server 2', 'Server 1', 'Server 3']);
      expect(orderStreamsForHostSource(streams, null).found, isFalse);
      final alreadyFirst = orderStreamsForHostSource(streams, 'Server 2');
      expect(alreadyFirst.found, isTrue);
      expect(alreadyFirst.streams.first.source, 'Server 2');
    });
  });

  group('resolveGuestTitle tiers', () {
    Future<List<StreamResult>> noStreams(
      MultimediaItem item,
      String episodeUrl,
    ) async => const <StreamResult>[];

    Stream<List<MultimediaItem>> noSearch(String query) =>
        Stream<List<MultimediaItem>>.value(const <MultimediaItem>[]);

    test('tier 1: exact token + host source first, no fallback note', () async {
      final resolution = await resolveGuestTitle(
        identity: episodeMedia,
        loadDetails: (_) async => null,
        loadStreams: (_, _) async => const <StreamResult>[
          StreamResult(url: 'https://example.invalid/s2', source: 'Server 2'),
          StreamResult(url: 'https://example.invalid/s1', source: 'Server 1'),
        ],
        searchTitles: noSearch,
      );
      expect(resolution.videoUrl, 'https://example.invalid/dexter-s1-e2');
      expect(resolution.episode?.episode, 2);
      expect(resolution.preloadedStreams.first.source, 'Server 1');
      expect(resolution.sourceFallbackNotice, isNull);
    });

    test('tier 1: host source absent → best available + honest note', () async {
      final resolution = await resolveGuestTitle(
        identity: episodeMedia,
        loadDetails: (_) async => null,
        loadStreams: (_, _) async => const <StreamResult>[
          StreamResult(url: 'https://example.invalid/s2', source: 'Server 2'),
        ],
        searchTitles: noSearch,
      );
      expect(resolution.videoUrl, 'https://example.invalid/dexter-s1-e2');
      expect(resolution.preloadedStreams.single.source, 'Server 2');
      expect(resolution.sourceFallbackNotice, contains('Server 1'));
    });

    test('tier 2: detail URL resolves the exact episode', () async {
      // No episode token on this identity, so tier 1 cannot fire: the
      // resolution must come from the detail URL (tier 2).
      const noTokenEpisode = TogetherMediaIdentity(
        title: 'Dexter: Resurrection · S1 E2',
        tmdbType: 'tv',
        tmdbId: 427049,
        season: 1,
        episode: 2,
        provider: 'MovieSubLK',
        itemUrl: 'https://example.invalid/dexter',
        source: 'Server 1',
      );
      final resolution = await resolveGuestTitle(
        identity: noTokenEpisode,
        loadDetails: (_) async => MultimediaItem(
          title: 'Dexter: Resurrection',
          url: 'https://example.invalid/dexter',
          posterUrl: '',
          contentType: MultimediaContentType.series,
          tmdbId: 427049,
          provider: 'MovieSubLK',
          episodes: <Episode>[
            Episode(name: 'S1 E1', url: 'https://example.invalid/e1', season: 1, episode: 1),
            Episode(name: 'S1 E2', url: 'https://example.invalid/e2', season: 1, episode: 2),
          ],
        ),
        // The episode token resolves to the host's source.
        loadStreams: (_, _) async => const <StreamResult>[
          StreamResult(url: 'https://example.invalid/s1', source: 'Server 1'),
        ],
        searchTitles: noSearch,
      );
      expect(resolution.episode?.episode, 2);
      expect(resolution.videoUrl, 'https://example.invalid/e2');
      expect(resolution.preloadedStreams.single.source, 'Server 1');
      expect(resolution.sourceFallbackNotice, isNull);
    });

    test('tier 3: title search opens the exact match', () async {
      const noToken = TogetherMediaIdentity(
        title: 'Dune',
        tmdbType: 'movie',
        tmdbId: 438631,
        provider: 'MovieSubLK',
      );
      final resolution = await resolveGuestTitle(
        identity: noToken,
        // The search match loads details (one episode, as a film files
        // itself), and that episode's token resolves to a stream.
        loadDetails: (item) async => item.copyWith(
          episodes: <Episode>[
            Episode(name: 'Dune', url: 'https://example.invalid/dune-play'),
          ],
        ),
        loadStreams: (_, _) async => const <StreamResult>[
          StreamResult(url: 'https://example.invalid/s1', source: 'Server 1'),
        ],
        searchTitles: (_) => Stream<List<MultimediaItem>>.value(<MultimediaItem>[
          MultimediaItem(
            title: 'Dune',
            url: 'https://example.invalid/dune',
            posterUrl: '',
            contentType: MultimediaContentType.movie,
            tmdbId: 438631,
            provider: 'MovieSubLK',
          ),
        ]),
      );
      expect(resolution.videoUrl, 'https://example.invalid/dune-play');
      expect(resolution.episode, isNotNull);
    });

    test('all tiers fail → honest fallback message, never a wrong title', () async {
      const unknown = TogetherMediaIdentity(
        title: 'A Title That Does Not Exist · S1 E1',
        tmdbType: 'tv',
        season: 1,
        episode: 1,
      );
      await expectLater(
        resolveGuestTitle(
          identity: unknown,
          loadDetails: (_) async => null,
          loadStreams: noStreams,
          searchTitles: noSearch,
        ),
        throwsA(
          isA<GuestTitleResolutionFailure>().having(
            (e) => e.message,
            'message',
            kGuestTitleNotFoundMessage,
          ),
        ),
      );
    });
  });

  group('go-live payload carries everything the guest needs', () {
    test('host go-live state carries provider + source + episode URL + S/E', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json, '_retain': retain});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(episodeMedia);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, isNotEmpty);
      final media = states.last['media'] as Map<String, dynamic>;
      expect(media['provider'], 'MovieSubLK');
      expect(media['source'], 'Server 1');
      expect(media['episodeUrl'], 'https://example.invalid/dexter-s1-e2');
      expect(media['itemUrl'], 'https://example.invalid/dexter');
      expect(media['season'], 1);
      expect(media['episode'], 2);
      expect(media['tmdbId'], 427049);
      expect(media['episodeLabel'], 'S1 E2');
      expect(states.last['playing'], isTrue);
      expect(states.last['positionMs'], 12000);
      expect(states.last['_retain'], isTrue);
    });

    test('guest receives the live state intact and lands live', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(episodeMedia);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      final state = published.lastWhere((p) => p['kind'] == 'state');

      final guest = newService(43);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.phase, TogetherPhase.waitingGuest);
      guest.debugReceivePayloadForTest(jsonEncode(state));
      expect(guest.isLive, isTrue);
      expect(guest.roomState?.media.title, 'Dexter: Resurrection · S1 E2');
      expect(guest.roomState?.media.source, 'Server 1');
      expect(guest.roomState?.media.provider, 'MovieSubLK');
      expect(guest.roomState?.media.season, 1);
      expect(guest.roomState?.media.episode, 2);
      expect(guest.roomState?.positionMs, 12000);
    });

    test('host title change re-shares the new title at position 0', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        statePayload(media: movieMedia, sequence: 1, positionMs: 12000, playing: true),
      );
      expect(guest.roomState?.media.title, 'Dune');
      guest.debugReceivePayloadForTest(
        statePayload(media: episodeMedia, sequence: 2, positionMs: 0, playing: true),
      );
      expect(guest.roomState?.media.title, 'Dexter: Resurrection · S1 E2');
      expect(guest.roomState?.positionMs, 0);
    });

    test('guest join shows the waiting state until the host starts', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.phase, TogetherPhase.waitingGuest);
      expect(guest.isLive, isFalse);
      expect(guest.presenceLabel, 'Waiting for the other phone…');
    });
  });

  group('togetherMediaIdentityFor populates the payload', () {
    test('film carries its open URL as the episode token', () {
      final item = MultimediaItem(
        title: 'Dune',
        url: 'https://example.invalid/dune',
        posterUrl: 'https://example.invalid/dune.jpg',
        contentType: MultimediaContentType.movie,
        tmdbId: 438631,
        provider: 'MovieSubLK',
      );
      final identity = togetherMediaIdentityFor(
        item: item,
        videoUrl: 'https://example.invalid/dune-play',
      );
      expect(identity.episodeUrl, 'https://example.invalid/dune-play');
      expect(identity.provider, 'MovieSubLK');
      expect(identity.itemUrl, 'https://example.invalid/dune');
      expect(identity.episodeLabel, isNull);
    });

    test('series episode carries S/E, episode URL and provider', () {
      final item = MultimediaItem(
        title: 'Dexter: Resurrection',
        url: 'https://example.invalid/dexter',
        posterUrl: 'https://example.invalid/dexter.jpg',
        contentType: MultimediaContentType.series,
        tmdbId: 427049,
        provider: 'MovieSubLK',
      );
      final ep = Episode(
        name: 'S1 E2',
        url: 'https://example.invalid/dexter-s1-e2',
        season: 1,
        episode: 2,
      );
      final identity = togetherMediaIdentityFor(item: item, episode: ep);
      expect(identity.season, 1);
      expect(identity.episode, 2);
      expect(identity.episodeUrl, 'https://example.invalid/dexter-s1-e2');
      expect(identity.episodeLabel, 'S1 E2');
    });

    test('a local file is never shared as an episode token', () {
      final item = MultimediaItem(
        title: 'Dune',
        url: '/storage/emulated/0/Movies/dune.mp4',
        posterUrl: '',
        contentType: MultimediaContentType.movie,
      );
      final identity = togetherMediaIdentityFor(
        item: item,
        videoUrl: '/storage/emulated/0/Movies/dune.mp4',
      );
      expect(identity.episodeUrl, isNull);
    });
  });

  group('guest local pause + catch-up resume (hook)', () {
    TogetherService liveGuest() {
      final guest = newService();
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        statePayload(media: movieMedia, sequence: 1, positionMs: 12000, playing: true),
      );
      expect(guest.isLive, isTrue);
      return guest;
    }

    test('guest pause holds only that phone: flag set, nothing published', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final published = <Map<String, dynamic>>[];
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: movieMedia,
      );
      hook.attach();
      addTearDown(hook.dispose);

      // The guest's engine pauses while the host is playing.
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.paused,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isTrue);
      // A guest never publishes: the room learns nothing.
      expect(published, isEmpty);
      // And the host state on the guest is untouched — still playing.
      expect(guest.roomState?.playing, isTrue);
    });

    test('guest resume jumps straight to the host live position', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: movieMedia,
      );
      hook.attach();
      addTearDown(hook.dispose);

      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.paused,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isTrue);

      // Play again: the hold clears and the forced evaluation seeks to
      // the host's current live position (host state: 12000 ms playing,
      // stamped just now — the target is ~12000 ms).
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.playing,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isFalse);
      final decision = hook.lastAppliedDecisionForTest;
      expect(decision, isNotNull);
      expect(decision!.action, SyncAction.seek);
      expect(decision.targetPositionMs, closeTo(12000, 2000));
    });

    test('a stalled (buffering) guest is not a local pause', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: movieMedia,
      );
      hook.attach();
      addTearDown(hook.dispose);
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.buffering,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isFalse);
    });

    test('host pause while the guest is paused is in sync, not a hold', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: movieMedia,
      );
      hook.attach();
      addTearDown(hook.dispose);
      // Host pauses too.
      guest.debugReceivePayloadForTest(
        statePayload(media: movieMedia, sequence: 2, positionMs: 12000, playing: false),
      );
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.paused,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isFalse);
    });
  });
}
