// In-app updates (YumeFlix 2.11.0) — unit tests.
//
// Covers the pure, testable layers: version comparison, release parsing +
// universal-asset selection, the prompt / snooze / auto-download decision
// (injectable clock), dismissed-state persistence, the silent-failure
// check, download verification + stale-file cleanup, and the install
// MethodChannel wrapper (mock channel — no device needed).
//
// The coordinator itself is not unit-tested here: it wires
// SharedPreferences / PackageInfo / platform channels and is exercised
// by `flutter analyze` plus the live check in tools/live_check.dart.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yumeflix/features/update/app_update_installer.dart';
import 'package:yumeflix/features/update/update_decision.dart';
import 'package:yumeflix/features/update/update_downloader.dart';
import 'package:yumeflix/features/update/update_models.dart';
import 'package:yumeflix/features/update/update_service.dart';
import 'package:yumeflix/features/update/update_store.dart';

Map<String, dynamic> releaseJson({
  String tag = 'v2.11.0',
  String? body = '## What\'s new\n- Faster search\n- Bug fixes',
  List<Map<String, dynamic>>? assets,
  bool prerelease = false,
  bool draft = false,
}) {
  return {
    'tag_name': tag,
    'body': body,
    'prerelease': prerelease,
    'draft': draft,
    'assets': assets ??
        [
          {
            'name': 'yumeflix-android-universal-v2.11.0.apk',
            'browser_download_url':
                'https://github.com/DevDoodle-69/YumeFlix-uprated/releases/download/v2.11.0/yumeflix-android-universal-v2.11.0.apk',
            'size': 120000000,
          },
          {
            'name': 'yumeflix-android-arm64-v8a-v2.11.0.apk',
            'browser_download_url': 'https://example.invalid/arm64.apk',
            'size': 60000000,
          },
        ],
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseVersion / compareVersions', () {
    test('newer / equal / older', () {
      expect(compareVersions('2.10.0', '2.11.0'), lessThan(0));
      expect(compareVersions('2.11.0', '2.11.0'), 0);
      expect(compareVersions('2.11.0', '2.10.0'), greaterThan(0));
      expect(compareVersions('2.9.0', '2.10.0'), lessThan(0));
    });

    test('"v" prefix and missing parts', () {
      expect(compareVersions('v2.10.0', '2.11.0'), lessThan(0));
      expect(compareVersions('2.11', '2.11.0'), 0);
      expect(compareVersions('2.10.0+2100', '2.10.0'), 0);
    });

    test('pre-release tags are ignored, never newer', () {
      expect(parseVersion('v2.11.0-beta.1'), isNull);
      expect(parseVersion('2.11.0-rc.1'), isNull);
      expect(isNewerVersion('2.10.0', 'v2.11.0-beta.1'), isFalse);
      expect(isNewerVersion('2.10.0', 'v2.11.0'), isTrue);
      expect(isNewerVersion('2.11.0', '2.11.0'), isFalse);
      expect(isNewerVersion('2.12.0', '2.11.0'), isFalse);
    });

    test('garbage does not parse and never counts as newer', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('banana'), isNull);
      expect(parseVersion('2.x.0'), isNull);
      expect(isNewerVersion('2.10.0', 'banana'), isFalse);
    });
  });

  group('parseLatestRelease / selectUniversalApkAsset', () {
    test('picks the exact universal asset, not a split APK', () {
      final release = parseLatestRelease(releaseJson());
      expect(release, isNotNull);
      expect(release!.version, '2.11.0');
      expect(release.apkName, 'yumeflix-android-universal-v2.11.0.apk');
      expect(release.apkSize, 120000000);
      expect(release.notes, contains('Faster search'));
    });

    test('falls back to any "universal" .apk name', () {
      final release = parseLatestRelease(
        releaseJson(
          assets: [
            {
              'name': 'YumeFlix-2.11.0-Universal.apk',
              'browser_download_url': 'https://example.invalid/u.apk',
              'size': 114000000,
            },
          ],
        ),
      );
      expect(release, isNotNull);
      expect(release!.apkName, 'YumeFlix-2.11.0-Universal.apk');
    });

    test('split APKs only: no release is offered', () {
      final release = parseLatestRelease(
        releaseJson(
          assets: [
            {
              'name': 'yumeflix-android-arm64-v8a-v2.11.0.apk',
              'browser_download_url': 'https://example.invalid/a.apk',
              'size': 60000000,
            },
            {
              'name': 'yumeflix-android-armeabi-v7a-v2.11.0.apk',
              'browser_download_url': 'https://example.invalid/b.apk',
              'size': 55000000,
            },
          ],
        ),
      );
      expect(release, isNull);
    });

    test('pre-release, draft, and pre-release tags are skipped', () {
      expect(parseLatestRelease(releaseJson(prerelease: true)), isNull);
      expect(parseLatestRelease(releaseJson(draft: true)), isNull);
      expect(parseLatestRelease(releaseJson(tag: 'v2.11.0-beta.1')), isNull);
    });

    test('malformed payloads are skipped', () {
      expect(parseLatestRelease({}), isNull);
      expect(parseLatestRelease({'tag_name': 'v2.11.0'}), isNull);
      expect(
        parseLatestRelease(releaseJson(assets: [])),
        isNull,
      );
    });

    test('shortReleaseNotes strips markdown and caps length', () {
      final notes = shortReleaseNotes(
        '# Big title\n\n- One\n- Two\n\n[link](https://example.invalid)',
      );
      expect(notes, contains('One'));
      expect(notes, isNot(contains('#')));
      expect(notes, isNot(contains('[link]')));
      expect(shortReleaseNotes(null), isEmpty);
      expect(shortReleaseNotes('x' * 1000).length, lessThanOrEqualTo(481));
    });
  });

  group('checkForUpdate (silent failures)', () {
    test('newer release is returned', () async {
      final release = await checkForUpdate(
        currentVersion: '2.10.0',
        fetchReleaseJson: (_) async => releaseJson(),
      );
      expect(release?.version, '2.11.0');
    });

    test('equal / older release is not an update', () async {
      expect(
        await checkForUpdate(
          currentVersion: '2.11.0',
          fetchReleaseJson: (_) async => releaseJson(),
        ),
        isNull,
      );
      expect(
        await checkForUpdate(
          currentVersion: '2.12.0',
          fetchReleaseJson: (_) async => releaseJson(),
        ),
        isNull,
      );
    });

    test('no network / bad response / malformed JSON → null, no throw', () async {
      expect(
        await checkForUpdate(
          currentVersion: '2.10.0',
          fetchReleaseJson: (_) async => null,
        ),
        isNull,
      );
      expect(
        await checkForUpdate(
          currentVersion: '2.10.0',
          fetchReleaseJson: (_) async =>
              throw const SocketException('no network'),
        ),
        isNull,
      );
      // A fetcher that returns a non-map payload cannot happen through
      // the typed signature; an empty map stands in for malformed JSON.
      expect(
        await checkForUpdate(
          currentVersion: '2.10.0',
          fetchReleaseJson: (_) async => <String, dynamic>{},
        ),
        isNull,
      );
    });
  });

  group('isUpdateCheckDue', () {
    test('never checked → due; <1 day → not due; >1 day → due', () {
      final now = DateTime.utc(2026, 11, 9, 12);
      expect(isUpdateCheckDue(null, now), isTrue);
      expect(
        isUpdateCheckDue(now.subtract(const Duration(hours: 23)), now),
        isFalse,
      );
      expect(
        isUpdateCheckDue(now.subtract(const Duration(hours: 25)), now),
        isTrue,
      );
    });
  });

  group('decideUpdateAction + UpdateStore (injectable clock)', () {
    late DateTime fakeNow;
    late UpdateStore store;

    setUp(() async {
      fakeNow = DateTime.utc(2026, 11, 9, 12);
      SharedPreferences.setMockInitialValues({});
      store = UpdateStore(
        await SharedPreferences.getInstance(),
        clock: () => fakeNow,
      );
    });

    UpdateRelease release() => parseLatestRelease(releaseJson())!;

    UpdateAction decide({required bool isWifi, bool downloaded = false}) {
      return decideUpdateAction(
        release: release(),
        store: store,
        now: fakeNow,
        isWifi: isWifi,
        downloadedFileValid: downloaded,
      );
    }

    test('no release → none', () {
      expect(
        decideUpdateAction(
          release: null,
          store: store,
          now: fakeNow,
          isWifi: true,
          downloadedFileValid: false,
        ),
        UpdateAction.none,
      );
    });

    test('prompt shown once per version per day, not on every launch', () async {
      expect(decide(isWifi: true), UpdateAction.prompt);
      await store.recordPrompt('2.11.0');
      expect(decide(isWifi: true), UpdateAction.none);
      // Next day the prompt may show again (if never dismissed).
      fakeNow = fakeNow.add(const Duration(days: 1, minutes: 1));
      expect(decide(isWifi: true), UpdateAction.prompt);
    });

    test('dismiss → snoozed: no prompt again within the window', () async {
      await store.recordFirstSeen('2.11.0');
      await store.recordDismissed('2.11.0');
      expect(decide(isWifi: true), UpdateAction.none);
      fakeNow = fakeNow.add(const Duration(days: 2));
      expect(decide(isWifi: true), UpdateAction.none);
    });

    test('dismiss + 3 days + Wi-Fi → auto-download', () async {
      await store.recordFirstSeen('2.11.0');
      await store.recordDismissed('2.11.0');
      fakeNow = fakeNow.add(const Duration(days: 3));
      expect(decide(isWifi: true), UpdateAction.autoDownload);
    });

    test('dismiss + 3 days on mobile data → prompt again, never silent', () async {
      await store.recordFirstSeen('2.11.0');
      await store.recordDismissed('2.11.0');
      fakeNow = fakeNow.add(const Duration(days: 3));
      expect(decide(isWifi: false), UpdateAction.prompt);
    });

    test('verified download on disk → offer install', () async {
      expect(decide(isWifi: true, downloaded: true), UpdateAction.offerInstall);
    });

    test('dismissal is persisted across store instances', () async {
      await store.recordFirstSeen('2.11.0');
      await store.recordDismissed('2.11.0');
      final reopened = UpdateStore(
        await SharedPreferences.getInstance(),
        clock: () => fakeNow,
      );
      expect(reopened.dismissedVersion, '2.11.0');
      expect(reopened.firstSeen('2.11.0'), isNotNull);
      // firstSeen is recorded once and never moves.
      final first = reopened.firstSeen('2.11.0')!;
      fakeNow = fakeNow.add(const Duration(days: 1));
      await reopened.recordFirstSeen('2.11.0');
      expect(reopened.firstSeen('2.11.0'), first);
    });

    test('recordCheck gates the daily check', () async {
      expect(store.lastCheckMs, isNull);
      await store.recordCheck();
      expect(isUpdateCheckDue(store.lastCheckMs, fakeNow), isFalse);
      fakeNow = fakeNow.add(const Duration(days: 1));
      expect(isUpdateCheckDue(store.lastCheckMs, fakeNow), isTrue);
    });
  });

  group('verifyDownloadedFile', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('yumeflix_update_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('correct size verifies, and its SHA-256 is reported', () async {
      final file = File('${tempDir.path}/a.apk');
      final bytes = utf8.encode('fake apk bytes');
      await file.writeAsBytes(bytes);
      final expectedSha = sha256.convert(bytes).toString();
      final result = await verifyDownloadedFile(
        file: file,
        expectedSize: bytes.length,
      );
      expect(result.valid, isTrue);
      expect(result.actualSize, bytes.length);
      expect(result.sha256, expectedSha);
    });

    test('wrong size fails verification', () async {
      final file = File('${tempDir.path}/a.apk');
      await file.writeAsBytes(utf8.encode('short'));
      final result = await verifyDownloadedFile(
        file: file,
        expectedSize: 120000000,
      );
      expect(result.valid, isFalse);
      expect(result.actualSize, 5);
    });

    test('missing file fails verification', () async {
      final result = await verifyDownloadedFile(
        file: File('${tempDir.path}/missing.apk'),
        expectedSize: 10,
      );
      expect(result.valid, isFalse);
      expect(result.actualSize, -1);
    });

    test('SHA-256 is enforced when an expected value is supplied', () async {
      final file = File('${tempDir.path}/a.apk');
      final bytes = utf8.encode('fake apk bytes');
      await file.writeAsBytes(bytes);
      final good = await verifyDownloadedFile(
        file: file,
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );
      expect(good.valid, isTrue);
      final bad = await verifyDownloadedFile(
        file: file,
        expectedSize: bytes.length,
        expectedSha256: '0' * 64,
      );
      expect(bad.valid, isFalse);
    });
  });

  group('cleanupStaleDownloads', () {
    test('keeps the current file, deletes other APKs, ignores the rest', () async {
      final dir = await Directory.systemTemp.createTemp('yumeflix_update_');
      try {
        final keep = File('${dir.path}/yumeflix-android-universal-v2.11.0.apk');
        final stale = File('${dir.path}/yumeflix-android-universal-v2.10.0.apk');
        final note = File('${dir.path}/readme.txt');
        await keep.writeAsString('keep');
        await stale.writeAsString('stale');
        await note.writeAsString('note');
        await cleanupStaleDownloads(
          updatesDir: dir,
          keepFileName: 'yumeflix-android-universal-v2.11.0.apk',
        );
        expect(await keep.exists(), isTrue);
        expect(await stale.exists(), isFalse);
        expect(await note.exists(), isTrue);
        // And a pass with nothing to keep deletes every APK.
        await cleanupStaleDownloads(updatesDir: dir);
        expect(await keep.exists(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('missing directory is a no-op, not a throw', () async {
      await cleanupStaleDownloads(
        updatesDir: Directory('/nonexistent/yumeflix_update_test_dir'),
      );
    });
  });

  group('AppUpdateInstaller (mock MethodChannel)', () {
    const channel = MethodChannel('yume.flix.by.nzr/app_update');
    final messenger = TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger;
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'canRequestInstall':
            return true;
          case 'requestInstallPermission':
            return true;
          case 'installApk':
            return true;
          default:
            throw PlatformException(code: 'NOT_IMPLEMENTED');
        }
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('install flow calls the native methods with the APK path', () async {
      final installer = AppUpdateInstaller();
      expect(await installer.canRequestInstall(), isTrue);
      expect(await installer.installApk('/docs/updates/app.apk'), isTrue);
      expect(
        calls.last.arguments,
        {'path': '/docs/updates/app.apk'},
      );
      expect(await installer.requestInstallPermission(), isTrue);
    });

    test('a native error degrades to false, never throws', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'BOOM');
      });
      final installer = AppUpdateInstaller();
      expect(await installer.canRequestInstall(), isFalse);
      expect(await installer.installApk('/docs/updates/app.apk'), isFalse);
      expect(await installer.requestInstallPermission(), isFalse);
    });
  });
}
