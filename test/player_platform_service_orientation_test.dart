import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/features/player/presentation/player_platform_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('player orientation', () {
    test('a pending mobile profile resolves to phone', () {
      expect(
        playerFormFactorOf(null, targetPlatform: TargetPlatform.android),
        PlayerFormFactor.phone,
      );
    });

    testWidgets('requests landscape immediately without video metadata', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      service.applyLandscapeOrientation();
      await tester.pump();

      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      ]);
    });

    testWidgets('restore is applied after an in-flight landscape request', (
      tester,
    ) async {
      final landscapeRequest = Completer<void>();
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) {
          requests.add(List<DeviceOrientation>.of(orientations));
          if (orientations.contains(DeviceOrientation.landscapeLeft)) {
            return landscapeRequest.future;
          }
          return Future<void>.value();
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();
      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      ]);

      service.restoreOrientation(PlayerFormFactor.phone);
      await tester.pump();
      expect(requests, hasLength(1));

      landscapeRequest.complete();
      await tester.pump();
      await tester.pump();
      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
        [DeviceOrientation.portraitUp],
      ]);
    });

    testWidgets(
      'closing before a queued request starts skips stale landscape',
      (tester) async {
        final requests = <List<DeviceOrientation>>[];
        final service = PlayerPlatformService(
          targetPlatform: () => TargetPlatform.android,
          setPreferredOrientations: (orientations) async {
            requests.add(List<DeviceOrientation>.of(orientations));
          },
        );

        service.applyLandscapeOrientation();
        service.restoreOrientation(PlayerFormFactor.phone);
        await tester.pump();
        await tester.pump();

        expect(requests, const [
          [DeviceOrientation.portraitUp],
        ]);
      },
    );

    testWidgets('retries a transient platform-channel failure', (tester) async {
      var attempts = 0;
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.android,
        setPreferredOrientations: (orientations) async {
          attempts += 1;
          if (attempts == 1) throw StateError('temporary channel failure');
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();
      await tester.pump();
      service.applyLandscapeOrientation();
      await tester.pump();

      expect(attempts, 2);
      expect(requests, const [
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      ]);
    });

    testWidgets('desktop platforms never receive mobile orientation locks', (
      tester,
    ) async {
      final requests = <List<DeviceOrientation>>[];
      final service = PlayerPlatformService(
        targetPlatform: () => TargetPlatform.linux,
        setPreferredOrientations: (orientations) async {
          requests.add(List<DeviceOrientation>.of(orientations));
        },
      );

      service.applyLandscapeOrientation();
      await tester.pump();

      expect(requests, isEmpty);
    });
  });
}
