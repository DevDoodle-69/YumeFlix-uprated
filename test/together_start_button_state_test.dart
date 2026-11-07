import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/floating_together_orb.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.8.0 Start-button state machine: the orb's Start button exists in
/// exactly one state — host, room pending, title picked, player open, and
/// the movie actually playing. Every other combination shows only the
/// small neutral pill, and going live replaces the button with the tiny
/// Live indicator for good.
///
/// Driven offline through the service's test seams; no relay, no network.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const media = TogetherMediaIdentity(
    title: 'Dune',
    tmdbType: 'movie',
    tmdbId: 438631,
    posterUrl: 'https://example.invalid/dune.jpg',
  );

  TogetherService newService() =>
      TogetherService(random: Random(42), preferences: null);

  /// Host with a picked title and an open player (the player hook's
  /// `goLive` registered), but not playing yet.
  TogetherService hostReadyToPlay() {
    final host = newService();
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    host.registerOrbStartAction(() {});
    host.attachMedia(media);
    return host;
  }

  void play(TogetherService service) {
    service.reportLocalPlayback(
      positionMs: 0,
      durationMs: 600000,
      playing: true,
    );
  }

  void pause(TogetherService service) {
    service.reportLocalPlayback(
      positionMs: 5000,
      durationMs: 600000,
      playing: false,
    );
  }

  group('TogetherStartState (service)', () {
    test('no room -> hidden', () {
      final service = newService();
      addTearDown(service.dispose);
      expect(service.startState, TogetherStartState.hidden);
      expect(service.showStartButton, isFalse);
    });

    test('browsing -> picked -> player open, still paused -> browsing', () {
      final host = newService();
      addTearDown(host.dispose);
      host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      expect(host.startState, TogetherStartState.browsing);

      // Picked a title, still browsing: no player, no playback.
      host.attachMedia(media);
      expect(host.startState, TogetherStartState.browsing);
      expect(host.showStartButton, isFalse);

      // Player open, still paused: still browsing.
      host.registerOrbStartAction(() {});
      expect(host.startState, TogetherStartState.browsing);

      // A paused tick changes nothing.
      pause(host);
      expect(host.startState, TogetherStartState.browsing);
    });

    test('playing -> ready; pausing -> browsing again', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      expect(host.isLocallyPlaying, isTrue);
      expect(host.startState, TogetherStartState.ready);
      expect(host.showStartButton, isTrue);

      pause(host);
      expect(host.isLocallyPlaying, isFalse);
      expect(host.startState, TogetherStartState.browsing);
      expect(host.showStartButton, isFalse);

      // Playing resumes: ready again.
      play(host);
      expect(host.startState, TogetherStartState.ready);
    });

    test('leaving the player without going live -> browsing; '
        're-entering while paused stays browsing until play resumes', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      expect(host.startState, TogetherStartState.ready);

      // Player closed (hook dispose clears the Start action): the stale
      // "playing" tick must not keep the button alive.
      host.registerOrbStartAction(null);
      expect(host.isLocallyPlaying, isFalse);
      expect(host.isPlayerOpen, isFalse);
      expect(host.startState, TogetherStartState.browsing);

      // Player re-opens, movie still paused: no Start until it plays.
      host.registerOrbStartAction(() {});
      expect(host.startState, TogetherStartState.browsing);
      play(host);
      expect(host.startState, TogetherStartState.ready);
    });

    test('going live -> live; Start never comes back while live', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      expect(host.startState, TogetherStartState.ready);

      host.goLive(positionMs: 1000, durationMs: 600000, playing: true);
      expect(host.phase, TogetherPhase.live);
      expect(host.startState, TogetherStartState.live);
      expect(host.showStartButton, isFalse);

      // Pausing a live room does not resurrect Start.
      pause(host);
      expect(host.startState, TogetherStartState.live);
      play(host);
      expect(host.startState, TogetherStartState.live);
    });

    test('guest never reaches ready', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.registerOrbStartAction(() {});
      guest.attachMedia(media);
      guest.reportLocalPlayback(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
      );
      expect(guest.startState, TogetherStartState.browsing);
      expect(guest.showStartButton, isFalse);
    });

    test('leaving the room resets the playing flag for the next room', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      expect(host.startState, TogetherStartState.ready);
      // leaveRoom is async (persist + disconnect); the reset itself is
      // synchronous inside it, but await for the whole leave to settle.
      return host.leaveRoom().then((_) {
        expect(host.startState, TogetherStartState.hidden);
        expect(host.isLocallyPlaying, isFalse);
      });
    });
  });

  group('floating orb (widget)', () {
    Future<void> pumpOrb(
      WidgetTester tester,
      TogetherService service,
    ) async {
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
    }

    testWidgets('browsing shows only the neutral pill — never Start',
        (tester) async {
      final service = newService();
      await pumpOrb(tester, service);

      service.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
      await tester.pump();
      expect(find.text('Enjoy Together'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Ready to start'), findsNothing);

      // Picking a title while browsing changes nothing on the pill.
      service.attachMedia(media);
      await tester.pump();
      expect(find.text('Enjoy Together'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Ready to start'), findsNothing);
    });

    testWidgets('playing shows the compact Start run button — '
        'white text, no red, no underline', (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      await tester.pump();

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Ready to start'), findsNothing);

      final label = tester.widget<Text>(find.text('Start'));
      expect(label.style?.color, const Color(0xFFF2F4F7));
      expect(label.style?.decoration, TextDecoration.none);
      expect(label.style?.fontSize, 13);
      // A play icon sits next to the label: it is a run button, not a
      // text prompt.
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('tapping Start goes live and the button vanishes '
        'into the tiny Live indicator', (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      await tester.pump();
      expect(find.text('Start'), findsOneWidget);

      // The player hook's real goLive: the tap must go live properly.
      service.registerOrbStartAction(
        () => service.goLive(
          positionMs: 0,
          durationMs: 600000,
          playing: true,
        ),
      );
      await tester.tap(find.text('Start'));
      await tester.pump();

      expect(service.phase, TogetherPhase.live);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Ready to start'), findsNothing);
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Enjoy Together'), findsNothing);
    });

    testWidgets('pausing hides Start again; resuming brings it back',
        (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      await tester.pump();
      expect(find.text('Start'), findsOneWidget);

      pause(service);
      await tester.pump();
      expect(find.text('Start'), findsNothing);
      expect(find.text('Enjoy Together'), findsOneWidget);

      play(service);
      await tester.pump();
      expect(find.text('Start'), findsOneWidget);
    });
  });
}
