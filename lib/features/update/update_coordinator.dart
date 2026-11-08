// In-app updates (YumeFlix 2.11.0) — coordinator.
//
// Owns the whole flow and nothing else: check scheduling (at most once a
// day, plus on foreground after a day has passed), the prompt / snooze /
// auto-download decision, the download, and the install handoff. It never
// blocks startup: [attach] fires the first check fire-and-forget, and
// every failure path is silent — a failed check changes nothing and the
// app works exactly as before.
//
// Wiring (main.dart, a few delimited lines): the app calls [attach] once
// from _MyAppState's post-frame callback, passing a provider for the root
// navigator's context (app_router.dart: rootNavigatorKey) so the dialogs
// can show above any route.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_update_installer.dart';
import 'update_decision.dart';
import 'update_downloader.dart';
import 'update_models.dart';
import 'update_prompt.dart';
import 'update_service.dart';
import 'update_store.dart';

/// True when the device is on an unmetered connection (Wi-Fi or Ethernet).
/// The automatic 3-day download is Wi-Fi-only; mobile data never gets a
/// silent ~120 MB download.
Future<bool> _defaultIsWifi() async {
  try {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
  } catch (_) {
    return false;
  }
}

class UpdateCoordinator with WidgetsBindingObserver {
  static final UpdateCoordinator instance = UpdateCoordinator._internal();

  UpdateCoordinator._internal({
    UpdateDownloadBackend? backend,
    AppUpdateInstaller? installer,
    ReleaseJsonFetcher? fetcher,
    Future<bool> Function()? isWifi,
    UpdateClock? clock,
  }) : _backend = backend ?? BackgroundDownloaderBackend(),
       _installer = installer ?? AppUpdateInstaller(),
       _fetcher = fetcher ?? fetchLatestReleaseJson,
       _isWifi = isWifi ?? _defaultIsWifi,
       _clock = clock ?? DateTime.now {
    // The notification tap re-shows the progress dialog (with Cancel) when
    // the user comes back from an automatic background download.
    if (backend == null) {
      final downloaderBackend = _backend;
      if (downloaderBackend is BackgroundDownloaderBackend) {
        downloaderBackend.onNotificationTap =
            () => unawaited(showProgressDialogIfDownloading());
      }
    }
  }

  final UpdateDownloadBackend _backend;
  final AppUpdateInstaller _installer;
  final ReleaseJsonFetcher _fetcher;
  final Future<bool> Function() _isWifi;
  final UpdateClock _clock;

  BuildContext? Function()? _dialogContextProvider;
  UpdateStore? _store;
  bool _attached = false;
  bool _checking = false;
  bool _dialogOpen = false;
  bool _downloadActive = false;
  UpdateRelease? _activeRelease;
  final ValueNotifier<UpdateDownloadProgress?> _downloadProgress =
      ValueNotifier<UpdateDownloadProgress?>(null);

  /// Mounts the coordinator: starts the foreground observer and fires the
  /// first (debounced, background) check. [dialogContext] supplies a
  /// context under the root Navigator for the dialogs (main.dart passes
  /// `() => rootNavigatorKey.currentContext`). Safe to call once; extra
  /// calls are ignored.
  Future<void> attach({
    BuildContext? Function()? dialogContext,
  }) async {
    if (_attached) return;
    _attached = true;
    _dialogContextProvider = dialogContext;
    WidgetsBinding.instance.addObserver(this);
    try {
      final prefs = await SharedPreferences.getInstance();
      _store = UpdateStore(prefs, clock: _clock);
      // Never offer a stale APK from a previous version or an interrupted
      // download: drop anything that is not the remembered verified file.
      final docs = await getApplicationDocumentsDirectory();
      await cleanupStaleDownloads(
        updatesDir: Directory('${docs.path}/$kAppUpdateDownloadDir'),
        keepFileName: _store!.downloadedPath?.split('/').last,
      );
    } catch (_) {
      // Persistence unavailable: the check simply never runs. Silent.
      _store = null;
    }
    unawaited(maybeCheck());
  }

  void detach() {
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _dialogContextProvider = null;
  }

  /// A context that can show dialogs, or null when the root Navigator is
  /// not mounted yet (too early) or gone (detach). Every dialog site goes
  /// through here so a missing navigator fails silent, never throws.
  BuildContext? _dialogContext() {
    final context = _dialogContextProvider?.call();
    if (context == null) return null;
    // A context whose element is unmounted cannot show a dialog.
    try {
      if (context is Element && !context.mounted) return null;
    } catch (_) {
      return null;
    }
    return context;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground after a day has passed re-arms the check; the once-a-day
    // debounce in [maybeCheck] still applies, so this never nags.
    if (state == AppLifecycleState.resumed) {
      unawaited(maybeCheck());
    }
  }

  /// The one debounced check entry point. Fire-and-forget, never throws,
  /// never blocks startup, and at most once a day.
  Future<void> maybeCheck() async {
    final store = _store;
    final context = _dialogContext();
    if (!_attached || store == null || context == null || _checking) return;
    if (_downloadActive || _dialogOpen) return;
    if (!isUpdateCheckDue(store.lastCheckMs, _clock())) return;
    _checking = true;
    try {
      // Record the attempt before fetching: a failed check still counts
      // against the daily budget, so a flaky network cannot make the app
      // hammer GitHub on every launch.
      await store.recordCheck();
      final currentVersion = await _installedVersion();
      if (currentVersion == null) return;
      final release = await checkForUpdate(
        currentVersion: currentVersion,
        fetchReleaseJson: _fetcher,
      );
      if (release == null) return;
      await store.recordFirstSeen(release.version);

      final downloadedValid = await _hasVerifiedDownload(store, release);
      final isWifi = await _isWifi();
      final action = decideUpdateAction(
        release: release,
        store: store,
        now: _clock(),
        isWifi: isWifi,
        downloadedFileValid: downloadedValid,
      );
      switch (action) {
        case UpdateAction.none:
          return;
        case UpdateAction.prompt:
          await _showPrompt(store, release);
        case UpdateAction.autoDownload:
          await _startDownload(release, wifiOnly: true, showDialog: false);
        case UpdateAction.offerInstall:
          await _offerInstall(store, release);
      }
    } catch (_) {
      // Any failure in the whole chain is silent by design.
      if (kDebugMode) debugPrint('[AppUpdate] check failed silently');
    } finally {
      _checking = false;
    }
  }

  Future<String?> _installedVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasVerifiedDownload(
    UpdateStore store,
    UpdateRelease release,
  ) async {
    if (store.downloadedVersion != release.version) return false;
    final path = store.downloadedPath;
    if (path == null) return false;
    final file = File(path);
    final verification = await verifyDownloadedFile(
      file: file,
      expectedSize: release.apkSize,
      expectedSha256: release.apkSha256,
    );
    if (!verification.valid) {
      // The remembered file is gone or corrupt: forget it so a later
      // check can download it again instead of offering a bad install.
      await deleteFileQuietly(file);
      await store.clearDownloaded();
      return false;
    }
    return true;
  }

  Future<void> _showPrompt(UpdateStore store, UpdateRelease release) async {
    if (_dialogContext() == null) return;
    await store.recordPrompt(release.version);
    // Re-fetch after the await: the navigator may have gone away while
    // the write was in flight, and a stale context must never show a
    // dialog (also satisfies use_build_context_synchronously).
    final context = _dialogContext();
    if (context == null || !context.mounted) return;
    _dialogOpen = true;
    bool updateNow = false;
    try {
      updateNow = await showUpdatePrompt(context: context, release: release);
    } finally {
      _dialogOpen = false;
    }
    if (updateNow) {
      await store.clearDismissed(release.version);
      await _startDownload(release, wifiOnly: false, showDialog: true);
    } else {
      // "Later" is respected: no more prompts for this version. The
      // 3-day clock (from first sight) is what brings it back — as an
      // automatic download, not another prompt.
      await store.recordDismissed(release.version);
    }
  }

  Future<void> _startDownload(
    UpdateRelease release, {
    required bool wifiOnly,
    required bool showDialog,
  }) async {
    final context = _dialogContext();
    if (context == null || _downloadActive) return;
    _downloadActive = true;
    _activeRelease = release;
    _downloadProgress.value = null;

    if (showDialog) {
      _dialogOpen = true;
      unawaited(
        showUpdateDownloadDialog(
          context: context,
          release: release,
          progress: _downloadProgress,
          onCancel: () => unawaited(_backend.cancel()),
        ).whenComplete(() => _dialogOpen = false),
      );
    }

    try {
      await _backend
          .download(release, wifiOnly: wifiOnly)
          .listen(
            (progress) => _downloadProgress.value = progress,
            onError: (_) {
              // Download failed / was interrupted: silent. The partial
              // file is already deleted by the backend; the update stays
              // available for the next check / prompt cycle.
            },
            cancelOnError: false,
          )
          .asFuture<void>();
    } catch (_) {
      // Listener-level failure: silent, same as a failed check.
    } finally {
      // The stream closing is the download finishing — complete, failed
      // or cancelled. The file on disk is the authority (see below).
      await _onDownloadFinished(release);
      _downloadActive = false;
      _activeRelease = null;
    }
  }

  /// Runs when the download stream closes (complete, failed or cancelled).
  /// The file on disk is the authority: only a file that verifies is
  /// recorded and offered for install.
  Future<void> _onDownloadFinished(UpdateRelease release) async {
    final store = _store;
    if (store == null) return;
    final file = await updateApkFile(release);
    final verification = await verifyDownloadedFile(
      file: file,
      expectedSize: release.apkSize,
      expectedSha256: release.apkSha256,
    );
    if (!verification.valid) return; // Failed / cancelled: stay silent.
    await store.recordDownloaded(
      version: release.version,
      path: file.path,
      size: verification.actualSize,
      sha256: verification.sha256,
    );
    await _offerInstall(store, release);
  }

  Future<void> _offerInstall(UpdateStore store, UpdateRelease release) async {
    final context = _dialogContext();
    if (context == null) return;
    final path = store.downloadedPath;
    if (path == null) return;
    _dialogOpen = true;
    bool install = false;
    try {
      install = await showDownloadCompleteDialog(
        context: context,
        release: release,
      );
    } finally {
      _dialogOpen = false;
    }
    if (install) await _install(path);
  }

  /// Opens the system installer for the verified APK at [apkPath].
  /// Never installs silently: Android always shows the installer screen
  /// and the user taps Install there. If "Install unknown apps" is not
  /// allowed yet, explains once and opens the system settings page for
  /// this app; declining leaves the update available.
  Future<void> _install(String apkPath) async {
    if (_dialogContext() == null) return;
    if (!await _installer.canRequestInstall()) {
      // Re-fetch after the await (see _showPrompt).
      final context = _dialogContext();
      if (context == null || !context.mounted) return;
      final openSettings = await showInstallPermissionDialog(context: context);
      if (!openSettings) return; // Update stays available. Nothing forced.
      await _installer.requestInstallPermission();
      // The user returns from settings and taps Install on the next
      // offer (the verified download is remembered in the store).
      return;
    }
    await _installer.installApk(apkPath);
  }

  /// Re-shows the progress dialog if a download is running — used when the
  /// user taps the system progress notification.
  Future<void> showProgressDialogIfDownloading() async {
    final context = _dialogContext();
    final release = _activeRelease;
    if (context == null || release == null || !_downloadActive) return;
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      await showUpdateDownloadDialog(
        context: context,
        release: release,
        progress: _downloadProgress,
        onCancel: () => unawaited(_backend.cancel()),
      );
    } finally {
      _dialogOpen = false;
    }
  }
}
