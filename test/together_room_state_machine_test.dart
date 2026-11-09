import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/floating_together_orb.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// Regression test for the Together room-state machine, driven offline
/// through the service's test seams ([TogetherService.debugEnterRoomForTest]
/// + [TogetherService.debugReceivePayloadForTest]) — no relay, no network.
///
/// The sequence under test is the user flow from the 2.7.0 brief:
/// created -> browsing -> picked -> playing -> started -> mirrored, and a
/// clean re-share when the host picks a different title while live. The
/// guest side is fed the exact JSON the relay would deliver, and every
/// transition the guest renders is asserted off the service state.
///
/// The real two-phone round-trip (host publishes over MQTT, guest receives
/// the same title + position within tolerance) is NOT provable here — it
/// needs the live relay and is the coordinator's `live_check` job.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const mediaA = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
  );
  const mediaB = TogetherMediaIdentity(
    title: 'Interstellar',
    tmdbType: 'movie',
    tmdbId: 157336,
    posterUrl: 'https://example.invalid/interstellar.jpg',
  );

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
  }) {
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 600000,
        playing: playing,
        hostTimestampMs: 1_700_000_000_000,
        sequence: sequence,
        hostId: 'host-1',
      ).toJson(),
    });
  }

  String statusPayload(
    TogetherRoomStatus status, [
    TogetherMediaIdentity? media,
  ]) {
    return jsonEncode(
      TogetherRoomStatusMessage(
        status: status,
        media: media,
        senderId: 'host-1',
        timestampMs: 1_700_000_000_000,
      ).toJson(),
    );
  }

  group('host: created -> picked -> started -> re-shared', () {
    test('host goes live with the picked title and re-shares cleanly',
        () async {
      final host = newService();
      addTearDown(host.dispose);

      // Created: a room exists, the host is still finding a movie.
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      expect(host.phase, TogetherPhase.pendingHost);
      expect(host.isSessionActive, isTrue);
      expect(host.isLive, isFalse);
      expect(host.roomStatus, TogetherRoomStatus.hostBrowsing);
      expect(host.currentMedia, isNull);

      // Picked: attaching a title makes it the room's title.
      host.attachMedia(mediaA);
      expect(host.pendingMedia, mediaA);
      expect(host.currentMedia, mediaA);

      // Started: Start publishes the live phase for the picked title.
      host.goLive(positionMs: 0, durationMs: 600000, playing: true);
      host.debugGuestReadyForTest();
      expect(host.phase, TogetherPhase.live);
      expect(host.isLive, isTrue);
      expect(host.currentMedia, mediaA);

      // Playing: ticks record the position the room is at.
      host.reportLocalPlayback(
        positionMs: 120000,
        durationMs: 600000,
        playing: true,
      );
      expect(host.lastLocalPositionMs, 120000);

      // Re-shared: picking a different title while live clears the old
      // title's position — the new title must start at 0, never at
      // 120 000 ms into the previous film.
      host.attachMedia(mediaB);
      expect(host.currentMedia, mediaB);
      expect(host.lastLocalPositionMs, 0);
      expect(host.phase, TogetherPhase.live);
    });

    test('goLive is a no-op without a picked title or a host role', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      host.goLive(positionMs: 0, durationMs: 600000);
      expect(host.phase, TogetherPhase.pendingHost);
      expect(host.isLive, isFalse);

      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.attachMedia(mediaA);
      guest.goLive(positionMs: 0, durationMs: 600000);
      expect(guest.phase, TogetherPhase.waitingGuest);
      expect(guest.isLive, isFalse);
    });

    test('orb Start / chat actions are a register-and-clear slot', () {
      final host = newService();
      addTearDown(host.dispose);
      expect(host.orbStartAction, isNull);
      expect(host.orbOpenChatAction, isNull);
      var started = false;
      host.registerOrbStartAction(() => started = true);
      host.orbStartAction?.call();
      expect(started, isTrue);
      host.registerOrbStartAction(null);
      expect(host.orbStartAction, isNull);
    });
  });

  group('guest: mirrors every host transition, in order', () {
    test('browsing -> picked -> playing -> paused -> new title -> host left',
        () async {
      final guest = newService();
      addTearDown(guest.dispose);

      // Joined: waiting, host still finding a movie.
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      expect(guest.phase, TogetherPhase.waitingGuest);
      expect(guest.roomStatus, TogetherRoomStatus.hostBrowsing);

      // Picked: the status push carries the title; the guest sees it
      // while still waiting — no "still searching" once picked.
      guest.debugReceivePayloadForTest(
        statusPayload(TogetherRoomStatus.hostPickedTitle, mediaA),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPickedTitle);
      expect(guest.currentMedia, mediaA);
      expect(guest.phase, TogetherPhase.waitingGuest);

      // Started: the retained state flips the guest live with the same
      // title, position and transport state the host published.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.isLive, isTrue);
      expect(guest.roomState?.media, mediaA);
      expect(guest.roomState?.positionMs, 12000);
      expect(guest.roomState?.playing, isTrue);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      expect(guest.currentMedia, mediaA);

      // Stale delivery: the same sequence again is ignored, not applied.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 1,
          positionMs: 999000,
          playing: true,
        ),
      );
      expect(guest.roomState?.positionMs, 12000);

      // Paused: the next state flips the transport, same title.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 2,
          positionMs: 20000,
          playing: false,
        ),
      );
      expect(guest.roomState?.playing, isFalse);
      expect(guest.roomStatus, TogetherRoomStatus.hostPaused);
      expect(guest.currentMedia, mediaA);

      // Re-shared: the host started a different title. The guest's live
      // state — and the title it renders — is the new one, cleanly.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaB,
          sequence: 3,
          positionMs: 0,
          playing: true,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.roomState?.media, mediaB);
      expect(guest.currentMedia, mediaB);
      expect(guest.roomState?.positionMs, 0);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);

      // Host left: the guest is told, and keeps the last synced state.
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(guest.currentMedia, mediaB);
    });

    test('a late guest learns the title from the retained state alone', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      // No status push ever arrived — the retained state is the first
      // thing the guest hears, and it still lands live on the right title.
      guest.debugReceivePayloadForTest(
        statePayload(
          media: mediaA,
          sequence: 7,
          positionMs: 45000,
          playing: true,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.currentMedia, mediaA);
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
    });
  });

  group('floating orb visibility', () {
    testWidgets('orb appears when a room is active and hides when idle',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final service = TogetherService(random: Random(42), preferences: prefs);
      // No addTearDown here: the ProviderScope override owns this service
      // and disposes it (via togetherServiceProvider's onDispose) when the
      // pumped tree goes away — disposing it twice throws.

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            togetherServiceProvider.overrideWith((ref) => service),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: <Widget>[
                  Placeholder(),
                  FloatingTogetherOrb(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Idle: no room, no orb.
      expect(find.text('Enjoy Together'), findsNothing);

      // Created: the orb appears immediately, before any title is picked.
      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      await tester.pump();
      expect(find.text('Enjoy Together'), findsOneWidget);

      // Start on the orb uses the player-registered action when one is
      // registered, and the room goes live from it. Expand the pill first
      // (its label is 'Enjoy Together' while browsing — there is no
      // 'Ready to start' anywhere), then open the player (register the
      // Start action), pick the title and press play.
      await tester.tap(find.text('Enjoy Together'));
      await tester.pump();
      expect(find.text('Pick a title to watch'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      var started = false;
      service.registerOrbStartAction(() => started = true);
      service.attachMedia(mediaA);
      await tester.pump();
      // Picked but not playing yet: still no Start.
      expect(find.text('Start'), findsNothing);
      expect(
        find.text('Play the movie first — the Start button appears once '
            'it’s playing.'),
        findsOneWidget,
      );
      service.reportLocalPlayback(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
      );
      await tester.pump();
      await tester.pump(); // post-frame collapse of the card
      // 2.9.0: the card never renders a Start button — it collapses
      // itself when the room becomes ready, and the collapsed pill is
      // the single Start control in the app.
      expect(find.text('Pick a title to watch'), findsNothing);
      expect(find.text('Start'), findsOneWidget);
      await tester.tap(find.text('Start'));
      await tester.pump();
      expect(started, isTrue);
    });
  });
}
