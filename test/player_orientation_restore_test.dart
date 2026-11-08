import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/features/player/presentation/player_platform_service.dart';

/// Reproduction of YumeFlix 2.10.0 Bug 2 (orientation stuck in landscape
/// after leaving the player).
///
/// The single restore call in the app lives in `VlcPlayerScreen.dispose()`
/// and funnels every exit path through `PlayerPlatformService`. These tests
/// prove, at the service seam, why that one restore does not hold:
///
/// 1. A playback tick that lands after the restore re-pins landscape and the
///    queued portrait request is dropped as stale — the player route stays
///    mounted through the ~300 ms pop transition while the VLC controller
///    keeps ticking (~4x/s), so this is the normal Back path, not an edge.
/// 2. A failed landscape channel call clears `_pinnedOrientation`, so a
///    later restore early-returns and nothing is ever queued.
/// 3. A failed restore request is never re-issued: the second restore call
///    is a no-op because `_pinnedOrientation` is already null.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('orientation restore defects (Bug 2 repro)', () {
    testWidgets('a tick after restore must not supersede portrait', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      // Playback: landscape pinned.
      service.applyLandscapeOrientation();
      await tester.pump();
      await tester.pump();

      // Back pressed: restore issued (dispose does the same).
      service.restoreOrientation(PlayerFormFactor.phone);
      // A VLC tick lands during the pop transition, before dispose runs.
      service.applyLandscapeOrientation();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Portrait must have been sent, and no landscape after it.
      // `contains` on a List element needs `equals`: list `==` is identity,
      // not deep equality.
      const portrait = [DeviceOrientation.portraitUp];
      const landscape = [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
      expect(
        requests,
        contains(equals(portrait)),
        reason: 'portrait restore must reach the OS',
      );
      final portraitIndex = requests.indexWhere(
        (r) => r.length == portrait.length && r.first == portrait.first,
      );
      expect(
        requests.sublist(portraitIndex + 1),
        isNot(contains(equals(landscape))),
        reason: 'no landscape request may follow the portrait restore',
      );
    });

    testWidgets('restore still runs after a failed landscape request', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      var attempts = 0;
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          attempts += 1;
          // The landscape pin fails at the channel; the OS keeps whatever
          // it last applied, so the restore is still owed.
          if (attempts == 1) throw StateError('channel unavailable');
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();
      await tester.pump();
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();
      await tester.pump();

      expect(
        requests,
        contains(equals(const [DeviceOrientation.portraitUp])),
        reason: 'a failed pin must not cancel the restore',
      );
    });

    testWidgets('a failed restore is re-issued by the next restore call', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      var attempts = 0;
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          attempts += 1;
          // First portrait attempt fails (teardown timing); the screen
          // calls restore again from dispose, which must retry it.
          if (orientations.contains(DeviceOrientation.portraitUp) &&
              attempts == 2) {
            throw StateError('channel unavailable during teardown');
          }
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();
      await tester.pump();
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();
      await tester.pump();
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();
      await tester.pump();

      expect(
        requests,
        contains(equals(const [DeviceOrientation.portraitUp])),
        reason: 'the dispose restore must retry a failed early restore',
      );
    });

    testWidgets('restore with nothing pinned sends nothing', (tester) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      // Opened and closed before the first tick: pinning portraitUp here
      // would freeze rotation app-wide for the rest of the process.
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();

      expect(requests, isEmpty);
    });

    testWidgets('restore is idempotent once delivered', (tester) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();
      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();

      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
        [DeviceOrientation.portraitUp],
      ]);
    });

    testWidgets('tablet and TV restore releases instead of forcing portrait', (
      tester,
    ) async {
      for (final form in [PlayerFormFactor.tablet, PlayerFormFactor.tv]) {
        final requests = <List<DeviceOrientation>>[];
        final service = PlayerPlatformService(
          targetPlatform: () => TargetPlatform.android,
          setPreferredOrientations: (orientations) async {
            requests.add(List<DeviceOrientation>.of(orientations));
          },
        );

        service.applyLandscapeOrientation();
        await tester.pump();
        service.restoreOrientation(form);
        await tester.pump();
        await tester.pump();

        // TV is landscape-native and a tablet is browsable either way up:
        // release, do not force portrait. Unchanged from before the fix.
        expect(requests, const [
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
          <DeviceOrientation>[],
        ]);
      }
    });
  });

  group('PlayerOrientationController', () {
    testWidgets('foreground re-assert is blocked once the player is leaving', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );
      final orientation = PlayerOrientationController(service);

      orientation.onPlaybackTick();
      await tester.pump();
      // Back pressed, then a foreground event lands mid-pop: it must not
      // resurrect the landscape pin.
      orientation.onBack(PlayerFormFactor.phone);
      orientation.onForegrounded();
      await tester.pump();
      await tester.pump();

      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
        [DeviceOrientation.portraitUp],
      ]);
    });

    testWidgets('foreground re-assert is a no-op while already pinned', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );
      final orientation = PlayerOrientationController(service);

      orientation.onPlaybackTick();
      await tester.pump();
      orientation.onForegrounded();
      await tester.pump();

      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      ]);
    });

    testWidgets(
      'pop-transition ticks cannot undo the restore (player dispose path)',
      (tester) async {
        final requests = <List<DeviceOrientation>>[];
        final service = PlayerPlatformService(
          targetPlatform: () => TargetPlatform.android,
          setPreferredOrientations: (orientations) async {
            requests.add(List<DeviceOrientation>.of(orientations));
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => _OrientationHarness(service: service),
                      ),
                    ),
                    child: const Text('Open player'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open player'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(requests, const [
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
        ]);

        // Back, exactly as the screen does it: restore, then pop. The
        // harness keeps ticking every 250 ms through the pop transition,
        // as the VLC controller listener does on the real screen.
        await tester.tap(find.text('Back'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        expect(requests.last, const [
          DeviceOrientation.portraitUp,
        ], reason: 'portrait must be the last orientation request');
        expect(
          requests
              .where((r) => r.contains(DeviceOrientation.landscapeLeft))
              .length,
          1,
          reason: 'landscape must have been requested exactly once',
        );
      },
    );
  });
}

/// The player screen's orientation wiring, minus VLC: a service-owned
/// controller, a 250 ms playback tick, restore on Back before the pop, and
/// restore again from dispose.
///
/// Deliberately not the real `VlcPlayerScreen` (native engine, Riverpod,
/// l10n): the wiring under test is these four one-line calls, and this
/// harness drives the real [PlayerOrientationController] +
/// [PlayerPlatformService] through the real route lifecycle instead of
/// copying them. The Together-live pop follows this same path — the
/// controller takes no Together input, so a live room cannot change it.
class _OrientationHarness extends StatefulWidget {
  const _OrientationHarness({required this.service});

  final PlayerPlatformService service;

  @override
  State<_OrientationHarness> createState() => _OrientationHarnessState();
}

class _OrientationHarnessState extends State<_OrientationHarness> {
  late final PlayerOrientationController _orientation;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _orientation = PlayerOrientationController(widget.service);
    _orientation.onPlaybackTick();
    _tick = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _orientation.onPlaybackTick(),
    );
  }

  void _back() {
    _orientation.onBack(PlayerFormFactor.phone);
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _orientation.dispose(PlayerFormFactor.phone);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(onPressed: _back, child: const Text('Back')),
      ),
    );
  }
}
