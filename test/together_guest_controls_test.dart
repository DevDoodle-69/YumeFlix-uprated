import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/sync_math.dart';
import 'package:yumeflix/features/together/together_player_hook.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.11.0 guest controls — local only. A guest gets brightness, volume
/// and play/pause for themselves alone; episode, language, server and
/// title stay host-only, and the guest UI must not even offer them.
///
/// What is pinned here is the enforceable half: the hook + service.
/// The widget half (no episode buttons, no panel tabs, no startup source
/// rows for a guest) is gating in `vlc_player_screen.dart` + the play/
/// pause allowance in `vlc_player_controls.dart`, verified by code
/// inspection — widget tests cannot drive the real VLC engine, and the
/// method-level guards below refuse the same actions anyway.
///
/// Offline through the service's test seams — no relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  TogetherService newService([int seed = 42]) =>
      TogetherService(random: Random(seed), preferences: null);

  const mediaA = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
    provider: 'MovieSubLK',
    itemUrl: 'https://example.invalid/dune',
    episodeUrl: 'https://example.invalid/dune-play',
    source: 'Server 1',
  );

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    String hostId = 'host-1',
  }) => jsonEncode(<String, dynamic>{
    'kind': 'state',
    ...TogetherRoomState(
      media: media,
      positionMs: positionMs,
      durationMs: 600000,
      playing: playing,
      hostTimestampMs: DateTime.now().millisecondsSinceEpoch,
      sequence: sequence,
      hostId: hostId,
    ).toJson(),
  });

  /// Guest in a live room, host playing Dune at 12000 ms.
  TogetherService liveGuest() {
    final guest = newService();
    guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
    guest.debugReceivePayloadForTest(
      statePayload(media: mediaA, sequence: 1, positionMs: 12000, playing: true),
    );
    expect(guest.isLive, isTrue);
    return guest;
  }

  group('guest pause publishes nothing', () {
    test('reportLocalPlayback from a guest never reaches the room', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final published = <Map<String, dynamic>>[];
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      // Pause, play, and a position report — the guest's engine talking
      // about itself. None of it is the room's business.
      guest.reportLocalPlayback(positionMs: 12000, durationMs: 600000, playing: false);
      guest.reportLocalPlayback(positionMs: 12000, durationMs: 600000, playing: true);
      guest.reportLocalPlayback(positionMs: 13000, durationMs: 600000, playing: true);
      expect(published, isEmpty);
    });

    test('the host publishing on the same actions is the contrast', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(mediaA);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();
      published.clear();
      host.reportLocalPlayback(positionMs: 12000, durationMs: 600000, playing: false);
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, hasLength(1));
      expect(states.single['playing'], isFalse);
    });
  });

  group('host playback speed rides the live payload', () {
    test('host engine at 2x publishes playbackSpeed 2.0', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(mediaA);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      published.clear();

      // The engine is now playing at 2x — the hook must carry the speed
      // into the live payload (Worker B's end-to-end speed wiring), so
      // the guest's drift correction aims at a 2x target, not a 1x one.
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.playing,
          position: Duration(milliseconds: 12000),
          duration: Duration(milliseconds: 600000),
          playbackSpeed: 2,
        ),
      );
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, hasLength(1));
      expect(states.single['playbackSpeed'], 2.0);
      expect(states.single['positionMs'], 12000);
    });

    test('guest drift correction aims at the host speed (2x target)', () {
      // No prior live state: the first forced evaluation must be the
      // 2x one (a prior evaluation would arm the 250 ms floor and the
      // second forced evaluation would be skipped).
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);

      // Host state stamped 5 s ago at 12000 ms, playing at 2x: the live
      // target is 12000 + 5000 * 2 = 22000 ms — not the 17000 ms a 1x
      // target would give. The hook's forced evaluation on the incoming
      // state must use the host's speed (Worker B's wiring).
      final stamp = DateTime.now().millisecondsSinceEpoch - 5000;
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'state',
          ...TogetherRoomState(
            media: mediaA,
            positionMs: 12000,
            durationMs: 600000,
            playing: true,
            hostTimestampMs: stamp,
            sequence: 2,
            hostId: 'host-1',
            playbackSpeed: 2.0,
          ).toJson(),
        }),
      );
      expect(guest.isLive, isTrue);
      final decision = hook.lastAppliedDecisionForTest;
      expect(decision, isNotNull);
      expect(decision!.action, SyncAction.seek);
      expect(decision.targetPositionMs, closeTo(22000, 500));
    });
  });

  group('guest lock scope', () {
    test('locked exactly while live with the host present', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      expect(hook.guestControlsLocked, isTrue);
      // Host leaves: the lock opens, playback carries on locally.
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(hook.guestControlsLocked, isFalse);
    });

    test('host is never locked', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      final hook = TogetherPlayerHook(
        service: host,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      expect(hook.guestControlsLocked, isFalse);
    });

    test('guest is not locked before the host goes live', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      expect(hook.guestControlsLocked, isFalse);
    });
  });

  group('guest cannot move the room', () {
    test('a guest source report never publishes', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final published = <Map<String, dynamic>>[];
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      // The screen only calls this for the host; if a guest path ever
      // reached it, the room must still hear nothing.
      hook.updateSource('Server 2');
      expect(published, isEmpty);
      expect(guest.roomState?.media.source, 'Server 1');
    });

    test('guest resume seeks to the host position, never to where they stopped', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
      );
      hook.attach();
      addTearDown(hook.dispose);
      // Guest paused far behind the host (position 2000 vs host 12000).
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.paused,
          position: Duration(milliseconds: 2000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isTrue);
      // Play again from the stale position: the resume decision is a
      // seek to the host's live position, not a resume at 2000.
      hook.onLocalPlayback(
        const VlcPlayerValue(
          state: VlcPlaybackState.playing,
          position: Duration(milliseconds: 2000),
          duration: Duration(milliseconds: 600000),
        ),
      );
      expect(hook.guestLocallyPaused, isFalse);
      final decision = hook.lastAppliedDecisionForTest;
      expect(decision, isNotNull);
      expect(decision!.action, SyncAction.seek);
      expect(decision.targetPositionMs, closeTo(12000, 2000));
    });

    test('incoming host state never snaps a locally-paused guest back', () {
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final hook = TogetherPlayerHook(
        service: guest,
        controller: VlcPlayerController(),
        media: mediaA,
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
      final decisionBefore = hook.lastAppliedDecisionForTest;
      // Host seeks forward; the guest is holding a pause.
      guest.debugReceivePayloadForTest(
        statePayload(media: mediaA, sequence: 2, positionMs: 60000, playing: true),
      );
      expect(hook.guestLocallyPaused, isTrue);
      expect(hook.lastAppliedDecisionForTest, decisionBefore);
    });
  });

  group('host source pick keeps the position; title change restarts at 0', () {
    test('source-only re-share keeps the live position', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(mediaA);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();
      published.clear();
      host.attachMedia(mediaA.withSource('Server 2'));
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, hasLength(1));
      expect((states.single['media'] as Map)['source'], 'Server 2');
      expect(states.single['positionMs'], 12000);
    });

    test('title change re-shares at position 0', () {
      final host = newService();
      addTearDown(host.dispose);
      final published = <Map<String, dynamic>>[];
      host.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.attachMedia(mediaA);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(positionMs: 0, durationMs: 600000, playing: true);
      host.goLive(positionMs: 12000, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();
      published.clear();
      const other = TogetherMediaIdentity(
        title: 'Interstellar',
        tmdbType: 'movie',
        tmdbId: 157336,
      );
      host.attachMedia(other);
      final states = published.where((p) => p['kind'] == 'state').toList();
      expect(states, hasLength(1));
      expect((states.single['media'] as Map)['title'], 'Interstellar');
      expect(states.single['positionMs'], 0);
    });
  });

  group('brightness / volume are local only', () {
    test('there is no room channel for them: a guest engine report publishes nothing', () {
      // Brightness and volume live on the player engine, not in the
      // Together service — there is no publish path for them to leak
      // through. The strongest offline statement of that: every local
      // engine report a guest can make (pause, play, position) leaves
      // the sink empty, and the room state is byte-identical afterwards.
      final guest = liveGuest();
      addTearDown(guest.dispose);
      final published = <Map<String, dynamic>>[];
      guest.debugPublishSinkForTest = (json, {bool retain = false}) {
        published.add(<String, dynamic>{...json});
      };
      final before = jsonEncode(guest.roomState?.toJson());
      guest.reportLocalPlayback(positionMs: 12000, durationMs: 600000, playing: false);
      guest.reportLocalPlayback(positionMs: 12000, durationMs: 600000, playing: true);
      expect(published, isEmpty);
      expect(jsonEncode(guest.roomState?.toJson()), before);
    });
  });
}
