import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:yumeflix/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/floating_together_orb.dart';
import 'package:yumeflix/features/together/presentation/together_live_indicator.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';
import 'package:yumeflix/l10n/generated/app_localizations.dart';

/// 2.10.0, Bug 1: the floating "Live" pill is gone, and Live is a
/// playback fact, not a session fact.
///
/// The user live-tested 2.9.0 and saw a "Live" pill on the home screen
/// (and in the landscape player) while NOT watching anything. Root cause:
/// the orb read the sticky session phase (`isLive` — flips to live on
/// Start and nothing flips it back except leaving the room), and the orb
/// is mounted above the router, so it outlived the player on every
/// screen. The fix: [TogetherService.isShowingLive] requires the phase
/// live AND the host present AND a player open AND the shared title
/// actually playing, the orb hides entirely while it holds, and the only
/// Live indicator left is [TogetherLiveIndicator] in the player control
/// panel — green while healthy, orange while degraded.
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

  void play(TogetherService service, {int positionMs = 0}) {
    service.reportLocalPlayback(
      positionMs: positionMs,
      durationMs: 600000,
      playing: true,
    );
  }

  void pause(TogetherService service, {int positionMs = 5000}) {
    service.reportLocalPlayback(
      positionMs: positionMs,
      durationMs: 600000,
      playing: false,
    );
  }

  void goLive(TogetherService service) {
    service.goLive(positionMs: 1000, durationMs: 600000, playing: true);
    // 2.13.0: Start holds until the first guest is ready — release it,
    // so these tests exercise a live-playing room as before.
    service.debugGuestReadyForTest();
  }

  String statePayload({
    required TogetherMediaIdentity media,
    required int sequence,
    required int positionMs,
    required bool playing,
    int? hostTimestampMs,
  }) {
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: positionMs,
        durationMs: 600000,
        playing: playing,
        hostTimestampMs:
            hostTimestampMs ?? DateTime.now().millisecondsSinceEpoch,
        sequence: sequence,
        hostId: 'host-1',
      ).toJson(),
    });
  }

  group('isShowingLive (service): Live is a playback fact', () {
    test('not live before Start, even with a player open and playing', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      expect(host.startState, TogetherStartState.ready);
      expect(host.isShowingLive, isFalse);
      expect(host.liveHealth, TogetherLiveHealth.healthy);
    });

    test('live + playing + player open -> showing; Start gone', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(host.phase, TogetherPhase.live);
      expect(host.isShowingLive, isTrue);
      expect(host.startState, TogetherStartState.live);
      expect(host.showStartButton, isFalse);
    });

    test('leaving the player hides Live at once; the session survives', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(host.isShowingLive, isTrue);

      // Player dispose: the hook clears its Start action (and with it
      // the playing flag) — the exact path vlc_player_screen's dispose
      // takes on every pop.
      host.registerOrbStartAction(null);
      expect(host.isPlayerOpen, isFalse);
      expect(host.isLocallyPlaying, isFalse);
      expect(host.isShowingLive, isFalse);
      expect(host.startState, TogetherStartState.browsing);
      // The session itself is untouched: re-open the player, press play,
      // and Live is back with no second Start tap.
      expect(host.phase, TogetherPhase.live);
      host.registerOrbStartAction(() {});
      play(host);
      expect(host.isShowingLive, isTrue);
      expect(host.startState, TogetherStartState.live);
    });

    test('pausing hides Live at once; resuming brings it back', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(host.isShowingLive, isTrue);

      pause(host);
      expect(host.phase, TogetherPhase.live);
      expect(host.isShowingLive, isFalse);
      expect(host.startState, TogetherStartState.browsing);
      expect(host.showStartButton, isFalse);

      play(host, positionMs: 5000);
      expect(host.isShowingLive, isTrue);
      expect(host.startState, TogetherStartState.live);
    });

    test('leaving the room hides Live and the session', () async {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(host.isShowingLive, isTrue);

      await host.leaveRoom();
      expect(host.phase, TogetherPhase.idle);
      expect(host.isShowingLive, isFalse);
      expect(host.startState, TogetherStartState.hidden);
    });

    test('guest: live phase alone is NOT showing — no player, no Live', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      guest.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      expect(guest.phase, TogetherPhase.live);
      expect(guest.isLive, isTrue);
      // The guest has not opened the title: no player, no playback.
      expect(guest.isShowingLive, isFalse);
      expect(guest.startState, TogetherStartState.browsing);
    });

    test('guest: player open and playing the shared title -> showing', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final now = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 12000,
          playing: true,
          hostTimestampMs: now,
        ),
      );
      guest.registerOrbStartAction(() {});
      guest.attachMedia(media);
      play(guest, positionMs: 12000);
      expect(guest.isShowingLive, isTrue);
      expect(guest.startState, TogetherStartState.live);
    });

    test('guest: host leaves -> Live hides at once (host gone)', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final now = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 12000,
          playing: true,
          hostTimestampMs: now,
        ),
      );
      guest.registerOrbStartAction(() {});
      play(guest, positionMs: 12000);
      expect(guest.isShowingLive, isTrue);

      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      expect(guest.hostGone, isTrue);
      expect(guest.isShowingLive, isFalse);
      expect(guest.startState, TogetherStartState.browsing);
      // The guest keeps the last synced title and watches on locally.
      expect(guest.currentMedia, media);
    });
  });

  group('liveHealth (service): green / orange thresholds', () {
    test('healthy with no measurements yet — no signal is not a failure', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(host.roundTripMs, isNull);
      expect(host.liveDriftMs, 0);
      expect(host.liveHealth, TogetherLiveHealth.healthy);
    });

    test('round-trip: 800 ms is healthy, 801 ms is degraded', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      expect(kTogetherLiveDegradedRttMs, 800);

      host.debugSetRoundTripMsForTest(800);
      expect(host.liveHealth, TogetherLiveHealth.healthy);
      host.debugSetRoundTripMsForTest(801);
      expect(host.liveHealth, TogetherLiveHealth.degraded);
      host.debugSetRoundTripMsForTest(2500);
      expect(host.liveHealth, TogetherLiveHealth.degraded);
      host.debugSetRoundTripMsForTest(null);
      expect(host.liveHealth, TogetherLiveHealth.healthy);
    });

    test('reconnecting is degraded, even with a good round-trip', () {
      final host = hostReadyToPlay();
      addTearDown(host.dispose);
      play(host);
      goLive(host);
      host.debugSetRoundTripMsForTest(120);
      expect(host.liveHealth, TogetherLiveHealth.healthy);

      host.debugSetReconnectingForTest(true);
      expect(host.liveHealth, TogetherLiveHealth.degraded);
      host.debugSetReconnectingForTest(false);
      expect(host.liveHealth, TogetherLiveHealth.healthy);
    });

    test('guest drift: within 750 ms healthy, beyond it degraded', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final now = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 60000,
          playing: true,
          hostTimestampMs: now,
        ),
      );
      guest.registerOrbStartAction(() {});
      expect(kTogetherLiveDegradedDriftMs, 750);

      // On the host's clock: in sync.
      play(guest, positionMs: 60000);
      expect(guest.liveDriftMs, lessThanOrEqualTo(750));
      expect(guest.liveHealth, TogetherLiveHealth.healthy);

      // 5 s behind the host: drift far past the seek threshold.
      guest.reportLocalPlayback(
        positionMs: 55000,
        durationMs: 600000,
        playing: true,
      );
      expect(guest.liveDriftMs, greaterThan(750));
      expect(guest.liveHealth, TogetherLiveHealth.degraded);
    });

    test('guest: a fresh host heartbeat is healthy, not degraded', () {
      final guest = newService();
      addTearDown(guest.dispose);
      guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      final now = DateTime.now().millisecondsSinceEpoch;
      guest.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 12000,
          playing: true,
          hostTimestampMs: now,
        ),
      );
      guest.registerOrbStartAction(() {});
      play(guest, positionMs: 12000);
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'heartbeat',
          'senderId': 'host-1',
          'positionMs': 12000,
          'timestampMs': now,
          'status': 'host-playing',
        }),
      );
      expect(guest.liveHealth, TogetherLiveHealth.healthy);
    });
  });

  group('floating orb (widget): no Live pill on any screen', () {
    Future<void> pumpOrb(WidgetTester tester, TogetherService service) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [togetherServiceProvider.overrideWith((ref) => service)],
          child: const MaterialApp(
            home: Scaffold(
              body: Stack(
                children: <Widget>[Placeholder(), FloatingTogetherOrb()],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('live + playing in the player: the orb renders nothing', (
      tester,
    ) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      goLive(service);
      await tester.pump();

      expect(service.isShowingLive, isTrue);
      expect(find.text('Live'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Enjoy Together'), findsNothing);
    });

    testWidgets('pausing a live room brings the neutral pill back — '
        'never a Live pill', (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      goLive(service);
      await tester.pump();
      expect(find.text('Live'), findsNothing);

      pause(service);
      await tester.pump();
      expect(find.text('Live'), findsNothing);
      expect(find.text('Enjoy Together'), findsOneWidget);
    });

    testWidgets('leaving the player (home screen): no Live pill, '
        'only the neutral pill for the still-open room', (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      goLive(service);
      await tester.pump();
      expect(find.text('Live'), findsNothing);

      // The player route pops: hook dispose clears the Start action.
      service.registerOrbStartAction(null);
      await tester.pump();
      expect(find.text('Live'), findsNothing);
      expect(find.text('Enjoy Together'), findsOneWidget);
    });

    testWidgets('guest live on the wire but not watching: no pill at '
        'all — never a Live pill, never the neutral pill', (tester) async {
      final service = newService();
      await pumpOrb(tester, service);
      service.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
      service.debugReceivePayloadForTest(
        statePayload(
          media: media,
          sequence: 1,
          positionMs: 12000,
          playing: true,
        ),
      );
      await tester.pump();

      expect(service.phase, TogetherPhase.live);
      expect(service.isShowingLive, isFalse);
      expect(find.text('Live'), findsNothing);
      // 2.12.0 guest rule: no floating pill for guests, ever — the
      // guest's live playback is driven by the auto-open coordinator,
      // never by this orb. (This used to expect the neutral pill here.)
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
    });

    testWidgets('leaving the room removes the orb entirely', (tester) async {
      final service = hostReadyToPlay();
      await pumpOrb(tester, service);
      play(service);
      goLive(service);
      await tester.pump();
      expect(find.text('Live'), findsNothing);

      await service.leaveRoom();
      await tester.pump();
      expect(find.text('Live'), findsNothing);
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Start'), findsNothing);
    });
  });

  group('VlcPlayerControls bottom row: Live sits next to the chat icon', () {
    Future<void> pumpControls(
      WidgetTester tester, {
      TogetherLiveHealth? health,
    }) async {
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: VlcPlayerControls(
                controller: controller,
                title: 'Dune',
                onTogetherChat: () {},
                togetherLiveHealth: health,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('degraded health: Live chip renders immediately left '
        'of the chat button', (tester) async {
      await pumpControls(tester, health: TogetherLiveHealth.degraded);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
      // Left of, and next to, the chat icon — the chip's right edge is
      // at or before the chat button's centre.
      final liveRight = tester.getRect(find.text('Live')).right;
      final chatCentre = tester
          .getCenter(find.byIcon(Icons.chat_bubble_outline_rounded))
          .dx;
      expect(liveRight, lessThanOrEqualTo(chatCentre));
    });

    testWidgets('healthy: the same chip, green', (tester) async {
      await pumpControls(tester, health: TogetherLiveHealth.healthy);
      expect(find.text('Live'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    });

    testWidgets('null health (not showing live): no indicator at all, '
        'chat button still there', (tester) async {
      await pumpControls(tester);
      expect(find.text('Live'), findsNothing);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
    });
  });

  group('TogetherLiveIndicator (widget)', () {
    Finder dotWithColor(Color color) => find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          (widget.decoration as BoxDecoration?)?.color == color,
    );

    testWidgets('healthy: green blinking dot + Live + healthy semantics', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TogetherLiveIndicator(health: TogetherLiveHealth.healthy),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Live'), findsOneWidget);
      expect(dotWithColor(const Color(0xFF4CAF50)), findsOneWidget);
      expect(dotWithColor(const Color(0xFFED8A3C)), findsNothing);
      // The label lives on the Semantics widget itself (checked here
      // rather than via the assembled semantics tree, which widget
      // tests do not build without ensureSemantics).
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Live, connection healthy',
        ),
        findsOneWidget,
      );
      // At least a 44 dp touch-height row, like the icon buttons beside it.
      expect(
        tester.getSize(find.byType(TogetherLiveIndicator)).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('degraded: orange dot + Live + degraded semantics', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TogetherLiveIndicator(health: TogetherLiveHealth.degraded),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Live'), findsOneWidget);
      expect(dotWithColor(const Color(0xFFED8A3C)), findsOneWidget);
      expect(dotWithColor(const Color(0xFF4CAF50)), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              widget.properties.label == 'Live, connection degraded',
        ),
        findsOneWidget,
      );
    });
  });
}
