import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_player_hook.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.9.0 confirmed Start flow, offline through the service's test seams
/// (publish sink + inbound payload feed) — no relay, no network.
///
/// The contract, for movies and for series episodes alike: while the host
/// is playing, one tap on Start (1) makes the button vanish in the same
/// synchronous step — the phase flips to live and the playing state is
/// published before `goLive` returns, with no awaited gap — and (2) the
/// guest receives that retained state and lands live on the same title at
/// the same position. For series the shared title is the exact episode
/// the host is playing (correct season/episode); changing episode
/// re-shares cleanly at position 0.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  MultimediaItem movieItem() => MultimediaItem(
    title: 'Dune',
    url: 'https://example.invalid/dune',
    posterUrl: 'https://example.invalid/dune.jpg',
    contentType: MultimediaContentType.movie,
    tmdbId: 438631,
  );

  MultimediaItem seriesItem() => MultimediaItem(
    title: 'Dexter: Resurrection',
    url: 'https://example.invalid/dexter',
    posterUrl: 'https://example.invalid/dexter.jpg',
    contentType: MultimediaContentType.series,
    tmdbId: 427049,
  );

  Episode episode({required int season, required int number}) => Episode(
    name: 'S$season E$number',
    url: 'https://example.invalid/dexter-s${season}e$number',
    season: season,
    episode: number,
  );

  /// Host with the publish sink attached; every publish is captured.
  /// A player is open (the hook's `goLive` registered), so the Start
  /// state machine can reach `ready` while the host is playing.
  (TogetherService, List<Map<String, dynamic>>) hostWithSink() {
    final host = newService();
    final published = <Map<String, dynamic>>[];
    host.debugPublishSinkForTest = (json, {bool retain = false}) {
      published.add(<String, dynamic>{...json, '_retain': retain});
    };
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    host.registerOrbStartAction(() {});
    return (host, published);
  }

  List<Map<String, dynamic>> statesOf(List<Map<String, dynamic>> published) =>
      published.where((p) => p['kind'] == 'state').toList();

  /// Feeds the guest the exact JSON the host published, as the relay
  /// would deliver it.
  void deliverToGuest(
    TogetherService guest,
    Map<String, dynamic> publishedState,
  ) {
    guest.debugReceivePayloadForTest(jsonEncode(publishedState));
  }

  group('goLive flips the phase synchronously', () {
    test('movie: phase, button state and publish all land in one step',
        () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      host.attachMedia(togetherMediaIdentityFor(item: movieItem()));
      host.reportLocalPlayback(
        positionMs: 14000,
        durationMs: 600000,
        playing: true,
      );
      expect(host.startState, TogetherStartState.ready);

      // No await anywhere: the flip and the publish happen before this
      // call returns, so the button vanishes in the same rebuild.
      // 2.13.0: Start publishes HELD (paused at the start position,
      // waiting for the first guest) — the phase is live and the Start
      // control is gone from the first publish; the guest-ready release
      // is the second publish, playing at the same position.
      host.goLive(positionMs: 14000, durationMs: 600000, playing: true);
      expect(host.phase, TogetherPhase.live);
      expect(host.startState, TogetherStartState.live);
      expect(host.showStartButton, isFalse);
      expect(host.isShowingLive, isFalse);

      var states = statesOf(published);
      expect(states.length, 1);
      expect(states.single['playing'], isFalse);
      expect(states.single['held'], isTrue);
      expect(states.single['positionMs'], 14000);
      expect(states.single['_retain'], isTrue);

      host.debugGuestReadyForTest();
      expect(host.isShowingLive, isTrue);
      states = statesOf(published);
      expect(states.length, 2);
      expect(states.last['playing'], isTrue);
      expect(states.last['positionMs'], 14000);
      expect(states.last['_retain'], isTrue);
      final media = states.last['media'] as Map<String, dynamic>;
      expect(media['title'], 'Dune');
      expect(media['tmdbType'], 'movie');
    });

    test('hook goLive goes live from the engine state', () {
      final host = newService();
      addTearDown(host.dispose);
      // A publish sink, so goLive's state publish actually lands and the
      // room state exists to read back (without a relay there is nothing
      // to publish to, and _publishState is a no-op).
      host.debugPublishSinkForTest = (json, {bool retain = false}) {};
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: togetherMediaIdentityFor(item: movieItem()),
      );
      hook.attach();
      addTearDown(hook.dispose);
      hook.goLive();
      expect(host.phase, TogetherPhase.live);
      expect(host.roomState?.media.title, 'Dune');
    });
  });

  group('movie start flow: host -> guest', () {
    test('guest lands live on the bare movie title, same position', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      // A film opened with the plugin's dummy S1 E1 episode: the shared
      // title must still be the bare title — never "Dune · S1 E1".
      final media = togetherMediaIdentityFor(
        item: movieItem(),
        episode: Episode(
          name: 'Dune',
          url: 'https://example.invalid/dune-ep',
          season: 1,
          episode: 1,
        ),
      );
      expect(media.title, 'Dune');
      expect(media.episodeLabel, isNull);
      host.attachMedia(media);
      host.reportLocalPlayback(
        positionMs: 14000,
        durationMs: 600000,
        playing: true,
      );
      host.goLive(positionMs: 14000, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();

      final states = statesOf(published);
      expect(states.length, 2);
      expect(
        (states.last['media'] as Map)['title'],
        isNot(contains(RegExp(r'S\d+ E\d+'))),
      );

      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      deliverToGuest(guest, states.last);
      expect(guest.phase, TogetherPhase.live);
      expect(guest.isLive, isTrue);
      expect(guest.currentMedia?.title, 'Dune');
      expect(guest.currentMedia?.episodeLabel, isNull);
      expect(guest.roomState?.positionMs, 14000);
      expect(guest.roomState?.playing, isTrue);
    });
  });

  group('series episode start flow: host -> guest', () {
    test('guest lands live on the exact episode, same position', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      final media = togetherMediaIdentityFor(
        item: seriesItem(),
        episode: episode(season: 1, number: 1),
      );
      expect(media.title, 'Dexter: Resurrection · S1 E1');
      expect(media.episodeLabel, 'S1 E1');
      host.attachMedia(media);
      host.reportLocalPlayback(
        positionMs: 14000,
        durationMs: 3084000,
        playing: true,
      );
      host.goLive(positionMs: 14000, durationMs: 3084000, playing: true);
      host.debugGuestReadyForTest();

      final states = statesOf(published);
      expect(states.length, 2);
      final stateMedia = states.last['media'] as Map<String, dynamic>;
      expect(stateMedia['title'], 'Dexter: Resurrection · S1 E1');
      expect(stateMedia['episodeLabel'], 'S1 E1');

      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      deliverToGuest(guest, states.last);
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia?.title, 'Dexter: Resurrection · S1 E1');
      expect(guest.currentMedia?.episodeLabel, 'S1 E1');
      expect(guest.roomState?.positionMs, 14000);
      expect(guest.roomState?.playing, isTrue);

      // The guest's own player knows whether it is on this episode: the
      // same show id on a different episode is NOT the same title.
      final sameEpisodeHook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: media,
      );
      expect(sameEpisodeHook.guestNeedsSameTitle, isFalse);
      final otherEpisodeHook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: togetherMediaIdentityFor(
          item: seriesItem(),
          episode: episode(season: 1, number: 2),
        ),
      );
      expect(otherEpisodeHook.guestNeedsSameTitle, isTrue);
      expect(
        otherEpisodeHook.guestJoinHint,
        contains('Dexter: Resurrection · S1 E1'),
      );
    });

    test('changing episode re-shares cleanly at position 0', () {
      final (host, published) = hostWithSink();
      addTearDown(host.dispose);
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: togetherMediaIdentityFor(
          item: seriesItem(),
          episode: episode(season: 1, number: 1),
        ),
      );
      hook.attach();
      addTearDown(hook.dispose);
      host.reportLocalPlayback(
        positionMs: 14000,
        durationMs: 3084000,
        playing: true,
      );
      host.goLive(positionMs: 14000, durationMs: 3084000, playing: true);
      host.debugGuestReadyForTest();
      published.clear();

      // The episode advance: the hook re-points the room at S1 E2.
      hook.retargetMedia(
        togetherMediaIdentityFor(
          item: seriesItem(),
          episode: episode(season: 1, number: 2),
        ),
      );
      expect(hook.media.title, 'Dexter: Resurrection · S1 E2');
      final states = statesOf(published);
      expect(states.length, 1);
      final stateMedia = states.single['media'] as Map<String, dynamic>;
      expect(stateMedia['title'], 'Dexter: Resurrection · S1 E2');
      expect(stateMedia['episodeLabel'], 'S1 E2');
      expect(states.single['positionMs'], 0);
      expect(states.single['playing'], isTrue);

      // The guest follows to the new episode, from the start.
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      deliverToGuest(guest, states.last);
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia?.title, 'Dexter: Resurrection · S1 E2');
      expect(guest.roomState?.positionMs, 0);

      // Re-pointing at the episode already playing publishes nothing and
      // never rewinds.
      published.clear();
      hook.retargetMedia(
        togetherMediaIdentityFor(
          item: seriesItem(),
          episode: episode(season: 1, number: 2),
        ),
      );
      expect(statesOf(published), isEmpty);
    });
  });

  group('togetherSameTitle', () {
    test('same show, different episode -> not the same title', () {
      final s1e1 = togetherMediaIdentityFor(
        item: seriesItem(),
        episode: episode(season: 1, number: 1),
      );
      final s1e2 = togetherMediaIdentityFor(
        item: seriesItem(),
        episode: episode(season: 1, number: 2),
      );
      expect(togetherSameTitle(s1e1, s1e2), isFalse);
      expect(togetherSameTitle(s1e1, s1e1), isTrue);
    });

    test('same movie id -> same title; different movie -> not', () {
      final dune = togetherMediaIdentityFor(item: movieItem());
      final duneAgain = togetherMediaIdentityFor(item: movieItem());
      final other = const TogetherMediaIdentity(
        title: 'Interstellar',
        tmdbType: 'movie',
        tmdbId: 157336,
      );
      expect(togetherSameTitle(dune, duneAgain), isTrue);
      expect(togetherSameTitle(dune, other), isFalse);
    });

    test('no ids: the normalised title decides', () {
      const a = TogetherMediaIdentity(title: 'Dune');
      const b = TogetherMediaIdentity(title: '  dune ');
      const c = TogetherMediaIdentity(title: 'Dune: Part Two');
      expect(togetherSameTitle(a, b), isTrue);
      expect(togetherSameTitle(a, c), isFalse);
    });
  });
}
