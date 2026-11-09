import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/core/providers/device_info_provider.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/floating_together_orb.dart';
import 'package:yumeflix/features/together/presentation/together_screen.dart';
import 'package:yumeflix/features/together/presentation/together_start_button.dart';
import 'package:yumeflix/features/together/presentation/together_waiting_state.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// YumeFlix 2.12.0 (Worker A) — the giant yellow-underlined overlay.
///
/// ROOT CAUSE (proved here, not assumed). `main.dart` mounts the orb in
/// `MaterialApp.router`'s `builder`, as a sibling of the Navigator — OUTSIDE
/// every `Scaffold`/`Material` in the app. `MaterialApp` configures its
/// `WidgetsApp.textStyle` with the SDK's `_errorTextStyle`
/// (flutter 3.47.9, `packages/flutter/lib/src/material/app.dart:45`):
/// red `0xD0FF0000`, monospace, **48 pt**, w900, **double yellow underline**
/// (`decorationColor 0xFFFFFF00`). That is the ambient `DefaultTextStyle`
/// for everything above the router. A `Text` whose own style sets only a
/// colour merges over it and inherits the 48 pt monospace w900 yellow
/// double underline; a `Text` that sets a size still inherits the
/// underline (and the red, when it sets no colour) — exactly the
/// screenshot: giant grey/red text, yellow underlines, "Enjoy Together"
/// itself red and underlined. The 2.9.0 text-scale clamp could not fix
/// this: the size came from the ambient error style, not from the system
/// scale, and the earlier tests pumped the orb INSIDE a `Scaffold`, where
/// the `Material` ancestor hides the error style — so they never saw it.
///
/// The repro below pumps the orb the way `main.dart` mounts it (sibling
/// of the `Scaffold`, no `Material` ancestor) and asserts the RESOLVED
/// style of the rendered lines. It FAILS on the pre-fix card and PASSES
/// after the fix.
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

  TogetherService hostBrowsing() {
    final host = newService();
    host.debugEnterRoomForTest(role: TogetherRole.host, otp: '123456');
    return host;
  }

  TogetherService guestWaiting() {
    final guest = newService();
    guest.debugEnterRoomForTest(role: TogetherRole.guest, otp: '123456');
    return guest;
  }

  String statePayload({required bool playing, int sequence = 1}) {
    return jsonEncode(<String, dynamic>{
      'kind': 'state',
      ...TogetherRoomState(
        media: media,
        positionMs: 12000,
        durationMs: 600000,
        playing: playing,
        hostTimestampMs: DateTime.now().millisecondsSinceEpoch,
        sequence: sequence,
        hostId: 'host-1',
      ).toJson(),
    });
  }

  String statusPayload(TogetherRoomStatus status) {
    return jsonEncode(<String, dynamic>{
      'kind': 'status',
      'status': status.wireValue,
      'senderId': 'host-1',
      'timestampMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Pumps the orb exactly the way `main.dart` mounts it: a `Stack`
  /// directly under `MaterialApp`, the orb a SIBLING of the `Scaffold`
  /// (the app's routes) — never inside a `Scaffold`/`Material`.
  Future<void> pumpOrbAsMounted(
    WidgetTester tester,
    TogetherService service, {
    double textScale = 1.0,
    Size surface = const Size(390, 844),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [togetherServiceProvider.overrideWith((ref) => service)],
        child: MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: surface,
              textScaler: TextScaler.linear(textScale),
            ),
            child: const Stack(
              children: <Widget>[
                Scaffold(body: Placeholder()),
                FloatingTogetherOrb(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> expandCard(WidgetTester tester) async {
    await tester.tap(find.text('Enjoy Together'));
    await tester.pump();
  }

  Future<void> pumpWaiting(WidgetTester tester, TogetherService service) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: TogetherGuestWaitingState(
            service: service,
            onRetry: () {},
            onLeave: () {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> pumpScreen(WidgetTester tester, TogetherService service) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          togetherServiceProvider.overrideWith((ref) => service),
          deviceProfileProvider.overrideWith(
            (ref) async => const DeviceProfile(),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const TogetherScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  /// The style a `Text` actually renders with: its own style merged over
  /// the ambient `DefaultTextStyle` — the merge that produced the bug.
  TextStyle effectiveStyle(WidgetTester tester, Finder finder) {
    final text = tester.widget<Text>(finder);
    final ambient = DefaultTextStyle.of(tester.element(finder)).style;
    return ambient.merge(text.style);
  }

  group('root cause: overlay card text style (fails on old code)', () {
    testWidgets('mounted as main.dart mounts it, the ambient text style is the '
        'SDK error style — 48 pt, red, yellow double underline', (
      tester,
    ) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host);

      // The mount fact itself: above the router there is no Material
      // ancestor, so DefaultTextStyle.of at the orb IS the error style.
      // (This documents the cause; the fix lives inside the orb, so this
      // stays 48 pt even after the fix — the rendered lines below are
      // what must change.)
      final ambient = DefaultTextStyle.of(
        tester.element(find.byType(FloatingTogetherOrb)),
      ).style;
      expect(ambient.fontSize, 48.0);
      expect(ambient.color, const Color(0xD0FF0000));
      expect(ambient.decoration, TextDecoration.underline);
      expect(ambient.decorationColor, const Color(0xFFFFFF00));
    });

    testWidgets('expanded card lines render small, grey, with NO underline '
        'and NO red — never the 48 pt error style', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);

      // The host must never see the guest's waiting line about
      // themselves — and no line may carry the error style.
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Enjoy Together'), findsOneWidget);
      expect(find.text('Room 123456'), findsOneWidget);

      for (final finder in <Finder>[
        find.text('Enjoy Together'),
        find.text('Room 123456'),
        find.text('Pick a title to get started'),
      ]) {
        final style = effectiveStyle(tester, finder);
        expect(style.fontSize, isNotNull);
        expect(style.fontSize, lessThanOrEqualTo(16.0));
        expect(style.decoration, TextDecoration.none);
        expect(style.color, isNot(const Color(0xD0FF0000)));
        expect(style.decorationColor, isNot(const Color(0xFFFFFF00)));
      }
      // No yellow anywhere in the card's rendered text: check every
      // Text element's resolved style directly.
      for (final element in find.byType(Text).evaluate()) {
        final widget = element.widget as Text;
        final style = DefaultTextStyle.of(element).style.merge(widget.style);
        expect(style.decoration, TextDecoration.none);
        expect(style.decorationColor, isNot(const Color(0xFFFFFF00)));
        expect(style.color, isNot(const Color(0xD0FF0000)));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('expanded card at 1.3x text scale: no overflow, '
        'room code fully visible', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host, textScale: 1.3);
      await expandCard(tester);

      expect(find.text('Room 123456'), findsOneWidget);
      // Fully visible: the code text fits inside the 300 dp card.
      final codeRect = tester.getRect(find.text('Room 123456'));
      expect(codeRect.width, greaterThan(0));
      expect(codeRect.right, lessThanOrEqualTo(390));
      expect(codeRect.width, lessThanOrEqualTo(300));
      expect(tester.takeException(), isNull);
    });
  });

  group('guest never sees the orb/pill, in any phase', () {
    testWidgets('guest waiting: no pill, no "Waiting for host…", '
        'no Start, no orb icon', (tester) async {
      final guest = guestWaiting();
      await pumpOrbAsMounted(tester, guest);

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Waiting for host…'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.byType(TogetherStartButton), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
      expect(find.byType(FloatingTogetherOrb), findsOneWidget);
    });

    testWidgets('guest live (late joiner, state arrived): no pill', (
      tester,
    ) async {
      final guest = guestWaiting();
      guest.debugReceivePayloadForTest(statePayload(playing: true));
      expect(guest.phase, TogetherPhase.live);
      await pumpOrbAsMounted(tester, guest);

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Waiting for host…'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
    });

    testWidgets('guest live but paused: no pill', (tester) async {
      final guest = guestWaiting();
      guest.debugReceivePayloadForTest(statePayload(playing: true));
      guest.debugReceivePayloadForTest(
        statePayload(playing: false, sequence: 2),
      );
      expect(guest.phase, TogetherPhase.live);
      await pumpOrbAsMounted(tester, guest);

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
    });

    testWidgets('guest ended (left the room): no pill', (tester) async {
      final guest = guestWaiting();
      await pumpOrbAsMounted(tester, guest);
      expect(find.text('Enjoy Together'), findsNothing);

      await guest.leaveRoom();
      await tester.pump();
      expect(guest.phase, TogetherPhase.idle);
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
    });

    testWidgets('host still sees the pill in the same mount', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host);
      expect(find.text('Enjoy Together'), findsOneWidget);
    });
  });

  group('late joiner: waiting card never traps a live room', () {
    testWidgets('live status arrived (hostPlaying) but state not yet '
        'flipped: loading, never the waiting text', (tester) async {
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      guest.debugReceivePayloadForTest(
        statusPayload(TogetherRoomStatus.hostPlaying),
      );
      expect(guest.roomStatus, TogetherRoomStatus.hostPlaying);
      expect(guest.phase, TogetherPhase.waitingGuest);
      await pumpWaiting(tester, guest);

      expect(find.text('Joining the live session…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Host is playing'), findsNothing);
      expect(tester.takeException(), isNull);
      // The status payload armed the service's host-silence timer: end
      // the room here so no timer is pending when the binding checks
      // (tearDown disposal runs after that check).
      await guest.leaveRoom();
    });

    testWidgets('live room paused (hostPaused): loading, never waiting', (
      tester,
    ) async {
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      guest.debugReceivePayloadForTest(
        statusPayload(TogetherRoomStatus.hostPaused),
      );
      await pumpWaiting(tester, guest);

      expect(find.text('Joining the live session…'), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      await guest.leaveRoom();
    });

    testWidgets('auto-open already resolving: loading, never waiting', (
      tester,
    ) async {
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      guest.setGuestAutoOpenPending(true);
      await pumpWaiting(tester, guest);

      expect(find.text('Joining the live session…'), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
    });

    testWidgets('genuinely browsing host: the waiting copy is unchanged', (
      tester,
    ) async {
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      await pumpWaiting(tester, guest);

      expect(find.text('Host is still finding a movie…'), findsOneWidget);
      expect(find.text('Joining the live session…'), findsNothing);
    });

    testWidgets('host leaves while guest waits: honest short state, '
        'never a stuck wait', (tester) async {
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      // The bye only counts from a host id the guest has learned —
      // presence first, then the bye from that same host. A second
      // guest is present too: with the guest alone, the service's
      // empty-room auto-close ends the room at once (and clears
      // hostGone); with another guest still here, the honest
      // host-left state is what the waiting guest sees.
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'presence',
          'senderId': 'host-1',
          'role': 'host',
          'joined': true,
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{
          'kind': 'presence',
          'senderId': 'guest-2',
          'role': 'guest',
          'joined': true,
          'timestampMs': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      guest.debugReceivePayloadForTest(
        jsonEncode(<String, dynamic>{'kind': 'bye', 'senderId': 'host-1'}),
      );
      await tester.pump();
      expect(guest.hostGone, isTrue);
      await pumpWaiting(tester, guest);

      expect(find.text('Host left the room'), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Joining the live session…'), findsNothing);
      await guest.leaveRoom();
    });
  });

  group('redesigned panel layout', () {
    testWidgets('all actions present, touch targets >= 44 dp, '
        'no overflow at 1.3x, portrait', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host, textScale: 1.3);
      await expandCard(tester);

      expect(find.text('Enjoy Together'), findsOneWidget);
      expect(find.text('Room 123456'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Pick a title to watch'), findsOneWidget);
      expect(find.text('Leave room'), findsOneWidget);
      expect(find.text('Start'), findsNothing);

      // Touch targets: measure the BUTTONS, not their labels.
      expect(
        tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(44.0),
      );
      expect(
        tester.getSize(find.byType(OutlinedButton)).height,
        greaterThanOrEqualTo(44.0),
      );
      expect(
        tester.getSize(find.byType(TextButton)).height,
        greaterThanOrEqualTo(44.0),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1.3x in landscape, card fits the '
        'short window', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(
        tester,
        host,
        textScale: 1.3,
        surface: const Size(800, 360),
      );
      await expandCard(tester);

      expect(find.text('Room 123456'), findsOneWidget);
      expect(find.text('Pick a title to watch'), findsOneWidget);
      expect(find.text('Leave room'), findsOneWidget);
      final card = tester.getRect(find.text('Room 123456'));
      expect(card.bottom, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
    });

    testWidgets('host with a picked title sees the picked hint, '
        'never the guest waiting line', (tester) async {
      final host = hostBrowsing();
      host.attachMedia(media);
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);

      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Host picked a title'), findsNothing);
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('Pick a title to watch'), findsNothing);
    });
  });
  group('remaining-time indicator (2.12.0 room lifetime)', () {
    test('formatRoomRemaining: boundaries read correctly', () {
      expect(formatRoomRemaining(const Duration(minutes: 45)), '45:00');
      expect(
        formatRoomRemaining(const Duration(minutes: 44, seconds: 59)),
        '44:59',
      );
      expect(formatRoomRemaining(const Duration(seconds: 60)), '01:00');
      expect(formatRoomRemaining(const Duration(seconds: 1)), '00:01');
      expect(formatRoomRemaining(Duration.zero), '00:00');
      // A room that ended between the service read and this frame
      // never shows a negative display.
      expect(formatRoomRemaining(const Duration(seconds: -5)), '00:00');
    });

    testWidgets('indicator renders small, neutral, no red/orange, '
        'no underline', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: TogetherRoomRemainingIndicator(
                remaining: Duration(minutes: 44, seconds: 59),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Room ends in 44:59'), findsOneWidget);
      final style = effectiveStyle(tester, find.text('Room ends in 44:59'));
      expect(style.fontSize, 12);
      expect(style.decoration, TextDecoration.none);
      expect(style.color, isNot(const Color(0xD0FF0000)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('indicator at 00:00 still reads neutral, never alarming', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: TogetherRoomRemainingIndicator(remaining: Duration.zero),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Room ends in 00:00'), findsOneWidget);
      final style = effectiveStyle(tester, find.text('Room ends in 00:00'));
      expect(style.decoration, TextDecoration.none);
      expect(style.fontSize, lessThanOrEqualTo(12.0));
    });

    testWidgets('panel shows the indicator and ticks it down on '
        'the service heartbeat tick', (tester) async {
      // Real service clock: the room was created 1 s ago, so 44:59
      // is left. The tick is the service's own 1 s heartbeat work
      // (debugTickLifetimeForTest), which notifies when the displayed
      // second changes — the panel runs no timer of its own.
      final fixedNow = DateTime(2026, 11, 9, 12, 0, 0);
      var now = fixedNow;
      final host = newService();
      host.debugSetClockForTest(() => now);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs:
            fixedNow.millisecondsSinceEpoch -
            const Duration(seconds: 1).inMilliseconds,
      );
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);
      expect(find.text('Room ends in 44:59'), findsOneWidget);

      now = fixedNow.add(const Duration(seconds: 1));
      host.debugTickLifetimeForTest();
      await tester.pump();
      expect(find.text('Room ends in 44:58'), findsOneWidget);
      expect(find.text('Room ends in 44:59'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('panel hides the indicator while the service exposes '
        'no remaining time', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);

      expect(find.textContaining('Room ends in'), findsNothing);
      expect(find.text('Room 123456'), findsOneWidget);
    });

    testWidgets('guest waiting card shows the indicator too', (tester) async {
      final fixedNow = DateTime(2026, 11, 9, 12, 0, 0);
      final guest = newService();
      guest.debugSetClockForTest(() => fixedNow);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs:
            fixedNow.millisecondsSinceEpoch -
            const Duration(minutes: 15).inMilliseconds,
      );
      addTearDown(guest.dispose);
      await pumpWaiting(tester, guest);

      expect(find.text('Room ends in 30:00'), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsOneWidget);
    });
  });

  group('expiry / auto-close: no pill, no ghost Live, no waiting card', () {
    testWidgets('host: room ends with the panel open — panel and pill '
        'are gone, no ghost Live', (tester) async {
      final host = hostBrowsing();
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);
      expect(find.text('Room 123456'), findsOneWidget);

      // The room ending (45-minute limit reached, or auto-close) ends
      // the session the same way leaving does: the service ends the
      // room and the orb unmounts with it.
      await host.leaveRoom();
      await tester.pump();

      expect(host.phase, TogetherPhase.idle);
      expect(find.text('Room 123456'), findsNothing);
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Start'), findsNothing);
      expect(find.text('Live'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('host: live room ends — no ghost Live pill left behind', (
      tester,
    ) async {
      final host = hostBrowsing();
      host.attachMedia(media);
      host.registerOrbStartAction(() {});
      host.reportLocalPlayback(
        positionMs: 0,
        durationMs: 600000,
        playing: true,
      );
      host.goLive(positionMs: 0, durationMs: 600000, playing: true);
      expect(host.phase, TogetherPhase.live);
      await pumpOrbAsMounted(tester, host);
      expect(find.text('Enjoy Together'), findsNothing);

      await host.leaveRoom();
      await tester.pump();

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Live'), findsNothing);
      expect(find.byType(TogetherStartButton), findsNothing);
    });

    testWidgets('guest: room ends while waiting — no pill', (tester) async {
      final guest = guestWaiting();
      await pumpOrbAsMounted(tester, guest);
      expect(find.text('Enjoy Together'), findsNothing);

      await guest.leaveRoom();
      await tester.pump();

      expect(guest.phase, TogetherPhase.idle);
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('guest: waiting card renders nothing once the room '
        'has ended — never a stuck wait', (tester) async {
      // No orb mount here: the service is ended BEFORE pumping, so the
      // waiting card is judged on its own (a second pump in the test
      // above would hand the service to a new ProviderScope).
      final guest = guestWaiting();
      addTearDown(guest.dispose);
      await guest.leaveRoom();
      expect(guest.phase, TogetherPhase.idle);
      await pumpWaiting(tester, guest);

      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Joining the live session…'), findsNothing);
      expect(find.text('Host left the room'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('guest: room ends while live — no pill, no waiting card', (
      tester,
    ) async {
      final guest = guestWaiting();
      guest.debugReceivePayloadForTest(statePayload(playing: true));
      expect(guest.phase, TogetherPhase.live);
      await pumpOrbAsMounted(tester, guest);
      expect(find.text('Enjoy Together'), findsNothing);

      await guest.leaveRoom();
      await tester.pump();

      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Live'), findsNothing);
      expect(find.byIcon(Icons.group_rounded), findsNothing);
    });
    testWidgets('host: 45 minutes up on the heartbeat tick — the panel '
        'is gone, no ghost Live, no stale 00:00', (tester) async {
      final fixedNow = DateTime(2026, 11, 9, 12, 0, 0);
      final host = newService();
      host.debugSetClockForTest(() => fixedNow);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs:
            fixedNow.millisecondsSinceEpoch -
            kTogetherRoomLifetime.inMilliseconds,
      );
      await pumpOrbAsMounted(tester, host);
      await expandCard(tester);
      expect(find.text('Room ends in 00:00'), findsOneWidget);

      // The heartbeat tick ends the expired room (async in the
      // service); a few pumps let it land.
      host.debugTickLifetimeForTest();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(host.phase, TogetherPhase.error);
      expect(host.error, kTogetherRoomEndedMessage);
      expect(find.text('Room 123456'), findsNothing);
      expect(find.text('Enjoy Together'), findsNothing);
      expect(find.text('Room ends in 00:00'), findsNothing);
      expect(find.text('Live'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Together screen shows the ended message after expiry, '
        'never the waiting card (host)', (tester) async {
      final fixedNow = DateTime(2026, 11, 9, 12, 0, 0);
      final host = newService();
      host.debugSetClockForTest(() => fixedNow);
      host.debugEnterRoomForTest(
        role: TogetherRole.host,
        otp: '123456',
        createdAtMs:
            fixedNow.millisecondsSinceEpoch -
            kTogetherRoomLifetime.inMilliseconds,
      );
      host.debugTickLifetimeForTest();
      // Let the service's async expiry land before pumping.
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(host.phase, TogetherPhase.error);
      expect(host.error, kTogetherRoomEndedMessage);

      await pumpScreen(tester, host);
      expect(find.text(kTogetherRoomEndedMessage), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Joining the live session…'), findsNothing);
      expect(find.text('Room 123456'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Together screen shows the expired message after expiry '
        'while a guest is still waiting', (tester) async {
      final fixedNow = DateTime(2026, 11, 9, 12, 0, 0);
      final guest = newService();
      guest.debugSetClockForTest(() => fixedNow);
      guest.debugEnterRoomForTest(
        role: TogetherRole.guest,
        otp: '123456',
        createdAtMs:
            fixedNow.millisecondsSinceEpoch -
            kTogetherRoomLifetime.inMilliseconds,
      );
      guest.debugTickLifetimeForTest();
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      // A guest still waiting never entered the movie: the service
      // gives them the join-rejection line, not the ended line.
      expect(guest.phase, TogetherPhase.error);
      expect(guest.error, kTogetherRoomExpiredMessage);

      await pumpScreen(tester, guest);
      expect(find.text(kTogetherRoomExpiredMessage), findsOneWidget);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text('Joining the live session…'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
