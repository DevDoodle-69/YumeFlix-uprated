import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/core/providers/device_info_provider.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/together_screen.dart';
import 'package:yumeflix/features/together/presentation/together_waiting_state.dart';
import 'package:yumeflix/features/together/together_provider.dart';
import 'package:yumeflix/features/together/together_service.dart';

/// 2.9.0 Bug 1 — the giant broken overlay.
///
/// The guest waiting state ("Host is still finding a movie…" + the picked
/// title + the room code) must never appear on the host's own phone, and
/// when it does show (guest side) it must be a normal-sized bounded card:
/// small title, small body text, white/grey on dark, no red, no yellow,
/// no underline, no giant font, never overlapping other content.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const movieMedia = TogetherMediaIdentity(
    title: "Harry Potter and the Philosopher's Stone",
    tmdbType: 'movie',
    tmdbId: 671,
  );

  TogetherService serviceInRoom(TogetherRole role) {
    // No tearDown here: the widget-only tests dispose it themselves, and
    // the screen tests hand ownership to the ProviderScope (Riverpod
    // disposes the override's notifier; disposing twice throws).
    final service = TogetherService(random: Random(42), preferences: null);
    service.debugEnterRoomForTest(role: role, otp: '529605');
    service.attachMedia(movieMedia);
    return service;
  }

  Future<void> pumpWaiting(
    WidgetTester tester,
    TogetherService service, {
    double textScale = 1.0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              // A huge system text scale, on top of the real phone metrics:
              // copy the ambient MediaQuery and only change the scaler.
              final mediaQuery = MediaQuery.of(context);
              return MediaQuery(
                data: mediaQuery.copyWith(
                  textScaler: TextScaler.linear(textScale),
                ),
                child: TogetherGuestWaitingState(
                  service: service,
                  onRetry: () {},
                  onLeave: () {},
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
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
    await tester.pump(const Duration(milliseconds: 100));
  }

  bool isRedOrYellow(Color? color) {
    if (color == null) return false;
    // Red / yellow text or decoration: any strongly red or yellow hue.
    // (Theme greys and the slate-blue accent are not in this range.)
    final r = color.r;
    final g = color.g;
    final b = color.b;
    final isRed = r > 0.6 && g < 0.45 && b < 0.45;
    final isYellow = r > 0.7 && g > 0.55 && b < 0.45;
    return isRed || isYellow;
  }

  group('TogetherGuestWaitingState is guest-only', () {
    testWidgets('host never sees the waiting state', (tester) async {
      final host = serviceInRoom(TogetherRole.host);
      addTearDown(host.dispose);
      await pumpWaiting(tester, host);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(find.text(movieMedia.title), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('guest sees the waiting state', (tester) async {
      final guest = serviceInRoom(TogetherRole.guest);
      addTearDown(guest.dispose);
      await pumpWaiting(tester, guest);
      expect(find.text('Host is still finding a movie…'), findsOneWidget);
      expect(find.text(movieMedia.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('TogetherScreen gates the waiting card by role', () {
    testWidgets('host sees their own card, never the guest text', (
      tester,
    ) async {
      final host = serviceInRoom(TogetherRole.host);
      await pumpScreen(tester, host);
      expect(find.text('Host is still finding a movie…'), findsNothing);
      expect(
        find.text('Waiting for your friend to join with the code…'),
        findsOneWidget,
      );
      expect(find.text('529605'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('guest sees the waiting state, not the host card', (
      tester,
    ) async {
      final guest = serviceInRoom(TogetherRole.guest);
      await pumpScreen(tester, guest);
      expect(find.text('Host is still finding a movie…'), findsOneWidget);
      expect(
        find.text('Waiting for your friend to join with the code…'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('waiting state stays bounded', () {
    testWidgets('huge system text scale: no overflow, no giant text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final guest = serviceInRoom(TogetherRole.guest);
      addTearDown(guest.dispose);
      await pumpWaiting(tester, guest, textScale: 2.5);
      // A layout overflow surfaces as an exception in widget tests.
      expect(tester.takeException(), isNull);

      final status = find.text('Host is still finding a movie…');
      expect(status, findsOneWidget);
      // The status line fits inside the phone width instead of exploding
      // across the screen.
      final statusSize = tester.getSize(status);
      expect(statusSize.width, lessThanOrEqualTo(390.0));

      // No red/yellow styling, no underline, no giant font anywhere in
      // the waiting state.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final style = text.style;
        expect(
          isRedOrYellow(style?.color),
          isFalse,
          reason: 'red/yellow text: "${text.data}"',
        );
        expect(
          isRedOrYellow(style?.decorationColor),
          isFalse,
          reason: 'red/yellow underline: "${text.data}"',
        );
        expect(
          style?.decoration,
          isNot(TextDecoration.underline),
          reason: 'underlined text: "${text.data}"',
        );
        expect(
          style?.fontSize ?? 14.0,
          lessThanOrEqualTo(20.0),
          reason: 'giant font: "${text.data}"',
        );
      }
    });
  });

  group('reconnecting state (2.11.0)', () {
    testWidgets('relay drop shows the honest reconnecting line, not a '
        'stale room status', (tester) async {
      final guest = serviceInRoom(TogetherRole.guest);
      addTearDown(guest.dispose);
      guest.debugSetReconnectingForTest(true);
      await pumpWaiting(tester, guest);
      expect(find.text('Connection lost — reconnecting…'), findsOneWidget);
      // The last known status is stale the moment the relay drops: it
      // must not keep saying "Host is still finding a movie…".
      expect(find.text('Host is still finding a movie…'), findsNothing);
      // The attempt line says the room re-syncs on its own.
      expect(find.textContaining('Attempt 1 of 5'), findsOneWidget);
      expect(find.textContaining('re-syncs automatically'), findsOneWidget);
      // The picked title still shows: the guest knows what the room
      // is about while the relay comes back.
      expect(find.text(movieMedia.title), findsOneWidget);
      // No red/yellow styling on the reconnecting line either.
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          isRedOrYellow(text.style?.color),
          isFalse,
          reason: 'red/yellow text: "${text.data}"',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('stale card shows after 30 s of silence, and hides '
        'while a reconnect is already running', (tester) async {
      final guest = serviceInRoom(TogetherRole.guest);
      addTearDown(guest.dispose);
      guest.debugSetWaitingStaleForTest(true);
      await pumpWaiting(tester, guest);
      expect(find.text('No signal from the host yet'), findsOneWidget);

      // The same stale room, now with the relay being retried: the
      // reconnecting line replaces the stale card — its Retry would
      // cancel the loop that is already retrying.
      guest.debugSetReconnectingForTest(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('No signal from the host yet'), findsNothing);
      expect(find.text('Connection lost — reconnecting…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
