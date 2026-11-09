import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/guest_auto_open.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.12.0 guest visibility + late joiners (service + policy half).
///
/// Host Start reaches every guest automatically with the host's
/// settings (title/episode, provider/source, position, speed); a guest
/// joining late — long after the movie started — auto-opens at the
/// host's CURRENT live position, not from 0 and not stuck on a waiting
/// screen; a slow resolve shows the loading state while it works; and
/// a late joiner to a full room gets the clean room-full message.
/// Offline through the service's test seams — no relay, no network.
/// (The widget half — the coordinator pushing the player, the waiting
/// screen's loading line — is the other worker's surface; the pending
/// flag and the start position it reads are pinned here.)
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
    int? hostTimestampMs,
    double playbackSpeed = 1.0,
  }) => jsonEncode(<String, dynamic>{
    'kind': 'state',
    ...TogetherRoomState(
      media: media,
      positionMs: positionMs,
      durationMs: 5400000,
      playing: playing,
      hostTimestampMs: hostTimestampMs ?? DateTime.now().millisecondsSinceEpoch,
      sequence: sequence,
      hostId: 'host-1',
      playbackSpeed: playbackSpeed,
    ).toJson(),
  });

  group('host Start reaches every guest with the host settings', () {
    test('go-live publishes title, provider, source, position and speed', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(episodeMedia);
      host.goLive(positionMs: 120000, durationMs: 5400000, playing: true);
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, isNotEmpty);
      final state = states.last;
      expect(state['positionMs'], 120000);
      expect(state['playing'], isTrue);
      expect(state['playbackSpeed'], 1.0);
      final media = Map<String, dynamic>.from(state['media'] as Map);
      expect(media['title'], 'Dexter: Resurrection · S1 E2');
      expect(media['season'], 1);
      expect(media['episode'], 2);
      expect(media['provider'], 'MovieSubLK');
      expect(media['source'], 'Server 1');
      expect(media['episodeUrl'], 'https://example.invalid/dexter-s1-e2');
    });

    test('a host speed change publishes at once, with the new speed', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(json);
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(movieMedia);
      host.goLive(positionMs: 60000, durationMs: 5400000, playing: true);
      published.clear();
      host.reportLocalPlayback(
        positionMs: 61000,
        durationMs: 5400000,
        playing: true,
        playbackSpeed: 2.0,
      );
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, isNotEmpty);
      expect(states.last['playbackSpeed'], 2.0);
    });

    test('a speed-only state notifies the guest at once', () {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: movieMedia,
          sequence: 1,
          positionMs: 100000,
          playing: true,
          hostTimestampMs: stamp,
          playbackSpeed: 1.0,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      var notifies = 0;
      guest.addListener(() => notifies++);
      // Same target, same transport, same title — only the speed
      // changed. Before 2.12.0 this state notified nobody.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: movieMedia,
          sequence: 2,
          positionMs: 101000,
          playing: true,
          hostTimestampMs: stamp + 1000,
          playbackSpeed: 2.0,
        ),
      );
      expect(guest.roomState?.playbackSpeed, 2.0);
      expect(notifies, greaterThan(0));
    });
  });

  group('late joiners', () {
    test('a late joiner lands live at the host current position, not 0', () {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.phase, TogetherPhase.waitingGuest);
      // The movie started 45 minutes ago: the retained state says so.
      final stamp = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: episodeMedia,
          sequence: 1,
          positionMs: 2700000,
          playing: true,
          hostTimestampMs: stamp,
          playbackSpeed: 1.0,
        ),
      );
      // No heartbeat wait: the retained state itself flips the phase,
      // and the coordinator's listener fires on this same notification.
      expect(guest.phase, TogetherPhase.live);
      expect(guest.roomState, isNotNull);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final target = guest.roomState!.targetPositionMs(nowMs: nowMs);
      expect(target, greaterThanOrEqualTo(2700000));
      expect(target, lessThan(2700000 + 5000));
      // And the auto-open policy says open — the exact episode, at
      // that position — with no tap.
      expect(
        GuestAutoOpenPolicy.decide(
          role: guest.role,
          phase: guest.phase,
          liveMedia: guest.roomState?.media,
          hostGone: guest.hostGone,
          playerOpen: guest.isPlayerOpen,
          playerOpenMedia: guest.playerOpenMedia,
          openedKey: null,
          optedOutKey: null,
        ),
        GuestAutoOpenAction.open,
      );
      expect(guest.roomState?.media.episode, 2);
    });

    test('a late joiner at 2x speed targets where the host is going', () {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final stamp = DateTime.now().millisecondsSinceEpoch - 10000;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: movieMedia,
          sequence: 1,
          positionMs: 100000,
          playing: true,
          hostTimestampMs: stamp,
          playbackSpeed: 2.0,
        ),
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final target = guest.roomState!.targetPositionMs(nowMs: nowMs);
      // 10 s at 2x past 100000: ~120000, not ~110000 (1x) and not 0.
      expect(target, greaterThanOrEqualTo(118000));
      expect(target, lessThan(123000));
    });

    test('a slow resolve shows the loading state, then clears it', () {
      final guest = newService(7);
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.guestAutoOpenPending, isFalse);
      var notifies = 0;
      guest.addListener(() => notifies++);
      // What the coordinator sets the moment a live title starts
      // resolving (before any provider round-trip) and clears when the
      // open lands or fails: the Together screen reads this for its
      // "Opening…" line, so a slow connection never looks stuck.
      guest.setGuestAutoOpenPending(true);
      expect(guest.guestAutoOpenPending, isTrue);
      expect(notifies, greaterThan(0));
      guest.setGuestAutoOpenPending(false);
      expect(guest.guestAutoOpenPending, isFalse);
      guest.setGuestAutoOpenFailure('Couldn’t open this title automatically');
      expect(guest.guestAutoOpenFailure, isNotNull);
      guest.setGuestAutoOpenFailure(null);
      expect(guest.guestAutoOpenFailure, isNull);
    });

    test(
      'a late joiner to a full live room gets the room-full message',
      () async {
        final guest = newService(7);
        addTearDown(guest.dispose);
        guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
        guest.debugReceivePayloadForTest(
          statePayload(
            media: movieMedia,
            sequence: 1,
            positionMs: 2700000,
            playing: true,
          ),
        );
        expect(guest.phase, TogetherPhase.live);
        guest.debugReceivePayloadForTest(
          jsonEncode(<String, dynamic>{
            'kind': 'room-full',
            'targetId': guest.clientId,
            'senderId': 'host-1',
            'timestampMs': DateTime.now().millisecondsSinceEpoch,
            'message': kTogetherRoomFullMessage,
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(guest.phase, TogetherPhase.error);
        expect(guest.error, kTogetherRoomFullMessage);
      },
    );
  });
}
