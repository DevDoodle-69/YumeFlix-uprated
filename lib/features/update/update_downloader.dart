// In-app updates (YumeFlix 2.11.0) — APK download + verification.
//
// Download engine: background_downloader, already a project dependency
// and already the engine behind the app's media downloads. It runs the
// ~120 MB APK download in the background (foreground service on Android),
// shows a real Android progress notification with a progress bar, retries
// a failed download, and — for the automatic 3-day download — enforces
// the Wi-Fi-only rule natively via `requiresWiFi` (a second gate behind
// the Dart-side check in update_decision.dart).
//
// Monitoring deliberately does NOT subscribe to `FileDownloader().updates`:
// that is a single-subscription stream owned by DownloadService. This
// feature registers group callbacks for its own 'app-update' group
// instead — the pattern background_downloader documents for exactly this
// case — so the two features never interfere.
//
// Verification (the install gate): a download is only offered for install
// after [verifyDownloadedFile] passes. Today the release publishes no
// checksum file, so the gate is the size GitHub reports for the asset; the
// SHA-256 is computed and recorded whenever it is available, and checked
// whenever an expected value is supplied. A failed or interrupted download
// never yields an installable file: the partial file is deleted and the
// next attempt starts clean (see [deleteFileQuietly] and the backend's
// failure path) — a corrupt partial is never resumed into an install.

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'update_models.dart';

/// Result of [verifyDownloadedFile].
class DownloadVerification {
  /// True only when the file exists and passes every check that applies
  /// (size always, SHA-256 when an expected value was supplied).
  final bool valid;

  /// Actual size on disk, or -1 when the file does not exist.
  final int actualSize;

  /// SHA-256 hex of the file on disk, or null when it could not be read.
  final String? sha256;

  const DownloadVerification({
    required this.valid,
    required this.actualSize,
    this.sha256,
  });
}

/// Verifies a downloaded APK before it is ever offered for install.
///
///   * the file must exist;
///   * when [expectedSize] > 0, its length must match exactly — this is
///     the gate today, since the release publishes no checksum file;
///   * when [expectedSha256] is supplied, the file's SHA-256 must match.
///     (Not supplied today — see UpdateRelease.apkSha256 — but the check
///     is implemented so a future checksum file is verified, not ignored.)
///
/// The file's own SHA-256 is always computed and returned, so the caller
/// can record it for audit even when there is nothing to compare against.
Future<DownloadVerification> verifyDownloadedFile({
  required File file,
  required int expectedSize,
  String? expectedSha256,
}) async {
  if (!await file.exists()) {
    return const DownloadVerification(valid: false, actualSize: -1);
  }
  final actualSize = await file.length();
  if (expectedSize > 0 && actualSize != expectedSize) {
    return DownloadVerification(valid: false, actualSize: actualSize);
  }
  String? digest;
  try {
    digest = (await sha256.bind(file.openRead()).first).toString();
  } catch (_) {
    return DownloadVerification(valid: false, actualSize: actualSize);
  }
  if (expectedSha256 != null &&
      expectedSha256.isNotEmpty &&
      digest.toLowerCase() != expectedSha256.toLowerCase()) {
    return DownloadVerification(
      valid: false,
      actualSize: actualSize,
      sha256: digest,
    );
  }
  return DownloadVerification(
    valid: true,
    actualSize: actualSize,
    sha256: digest,
  );
}

/// Deletes [file] if it exists. Never throws: cleanup must not crash the
/// app, and a file that cannot be deleted is simply left for the next
/// cleanup pass.
Future<void> deleteFileQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {
    // Best effort only.
  }
}

/// Deletes stale APKs in the updates directory, keeping [keepFileName]
/// (the current pending version) when given. Run before a fresh download
/// and on coordinator start so an interrupted download from a previous
/// version can never be offered for install.
Future<void> cleanupStaleDownloads({
  required Directory updatesDir,
  String? keepFileName,
}) async {
  try {
    if (!await updatesDir.exists()) return;
    await for (final entity in updatesDir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.toLowerCase().endsWith('.apk')) continue;
      if (keepFileName != null && name == keepFileName) continue;
      await deleteFileQuietly(entity);
    }
  } catch (_) {
    // Best effort only.
  }
}

/// Where the APK for [release] is stored on disk.
Future<File> updateApkFile(UpdateRelease release) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, kAppUpdateDownloadDir));
  return File(p.join(dir.path, release.localFileName));
}

/// One progress event for an in-progress update download.
class UpdateDownloadProgress {
  /// 0.0–1.0 while running; -1 when the total size is not known yet.
  final double progress;

  /// Bytes received so far.
  final int receivedBytes;

  /// Total bytes when known, else -1.
  final int totalBytes;

  const UpdateDownloadProgress({
    required this.progress,
    required this.receivedBytes,
    required this.totalBytes,
  });
}

/// Pluggable download engine. The production implementation below drives
/// background_downloader; tests inject a fake that emits canned progress.
abstract class UpdateDownloadBackend {
  /// Downloads [release]'s APK, emitting progress until it completes,
  /// fails or is cancelled. [wifiOnly] is true for the automatic 3-day
  /// download (never mobile data) and false when the user tapped
  /// "Update now" themselves.
  Stream<UpdateDownloadProgress> download(
    UpdateRelease release, {
    required bool wifiOnly,
  });

  /// Cancels the in-flight download, if any. Deletes the partial file:
  /// a cancelled download is never resumed into an install.
  Future<void> cancel();
}

/// background_downloader implementation of [UpdateDownloadBackend].
class BackgroundDownloaderBackend implements UpdateDownloadBackend {
  static bool _callbacksRegistered = false;
  static bool _notificationConfigured = false;

  /// Called when the user taps the system progress notification.
  /// The coordinator sets this to re-show the progress dialog (with its
  /// Cancel button) — the in-app way to stop an automatic download.
  void Function()? onNotificationTap;

  BackgroundDownloaderBackend({this.onNotificationTap});

  StreamController<UpdateDownloadProgress>? _progressController;
  String? _activeTaskId;
  File? _activeFile;
  UpdateRelease? _activeRelease;

  void _ensureRegistered() {
    if (!_callbacksRegistered) {
      _callbacksRegistered = true;
      // The callbacks dispatch through instance fields, not through a
      // controller captured at registration time: registration happens
      // once, but every download gets its own stream, and progress for
      // download N must never land in download N-1's closed controller.
      FileDownloader().registerCallbacks(
        group: kAppUpdateDownloadGroup,
        taskProgressCallback: (update) {
          if (update.task.taskId != _activeTaskId) return;
          final controller = _progressController;
          if (controller == null || controller.isClosed) return;
          controller.add(
            UpdateDownloadProgress(
              progress: update.progress,
              receivedBytes: update.progress < 0 || update.expectedFileSize <= 0
                  ? -1
                  : (update.progress * update.expectedFileSize).round(),
              totalBytes: update.expectedFileSize,
            ),
          );
        },
        taskStatusCallback: (update) {
          if (update.task.taskId != _activeTaskId) return;
          final controller = _progressController;
          final release = _activeRelease;
          if (controller == null || release == null) return;
          unawaited(_onStatusUpdate(update, controller, release));
        },
        // Tapping the progress notification brings the user back to the
        // app; the coordinator re-shows the progress UI if a download is
        // still running (see update_coordinator.dart).
        taskNotificationTapCallback: (_, _) => onNotificationTap?.call(),
      );
    }
    if (!_notificationConfigured) {
      _notificationConfigured = true;
      // The visible progress notification: title + live progress bar
      // while running, a plain line when done / failed. Group-scoped, so
      // it never touches the media-download notification config.
      FileDownloader().configureNotificationForGroup(
        kAppUpdateDownloadGroup,
        running: const TaskNotification(
          '{displayName}',
          '{progress} • {networkSpeed} • {timeRemaining}',
        ),
        complete: const TaskNotification(
          '{displayName}',
          'Download complete — tap to install',
        ),
        error: const TaskNotification('{displayName}', 'Download failed'),
        canceled: const TaskNotification('{displayName}', 'Download canceled'),
        progressBar: true,
      );
    }
  }

  @override
  Stream<UpdateDownloadProgress> download(
    UpdateRelease release, {
    required bool wifiOnly,
  }) {
    final controller = StreamController<UpdateDownloadProgress>();
    _progressController = controller;
    final taskId = 'app-update-${release.version}';
    _activeTaskId = taskId;
    _activeRelease = release;

    _ensureRegistered();

    unawaited(_start(release, taskId: taskId, wifiOnly: wifiOnly));
    return controller.stream;
  }

  Future<void> _start(
    UpdateRelease release, {
    required String taskId,
    required bool wifiOnly,
  }) async {
    final controller = _progressController;
    if (controller == null || controller.isClosed) return;
    try {
      // A stale or partial file for this version must not survive into
      // a fresh attempt: delete it and let the downloader start clean.
      // (background_downloader retries a failed task up to `retries`
      // times itself; a task that still fails after that is re-enqueued
      // fresh on the next attempt, never resumed from a corrupt file.)
      final file = await updateApkFile(release);
      _activeFile = file;
      await deleteFileQuietly(file);

      final task = DownloadTask(
        taskId: taskId,
        url: release.apkUrl,
        filename: release.localFileName,
        directory: kAppUpdateDownloadDir,
        baseDirectory: BaseDirectory.applicationDocuments,
        group: kAppUpdateDownloadGroup,
        updates: Updates.statusAndProgress,
        requiresWiFi: wifiOnly,
        retries: 3,
        displayName: 'YumeFlix ${release.version} update',
      );
      final enqueued = await FileDownloader().enqueue(task);
      if (!enqueued && !controller.isClosed) {
        controller.addError(
          StateError('Could not start the update download'),
        );
        await controller.close();
      }
    } catch (e) {
      if (!controller.isClosed) {
        controller.addError(e);
        await controller.close();
      }
    }
  }

  Future<void> _onStatusUpdate(
    TaskStatusUpdate update,
    StreamController<UpdateDownloadProgress> controller,
    UpdateRelease release,
  ) async {
    switch (update.status) {
      case TaskStatus.complete:
        final file = _activeFile ?? await updateApkFile(release);
        final verification = await verifyDownloadedFile(
          file: file,
          expectedSize: release.apkSize,
          expectedSha256: release.apkSha256,
        );
        if (!verification.valid) {
          // Wrong size (truncated / corrupt) must never be installed.
          await deleteFileQuietly(file);
          if (!controller.isClosed) {
            controller.addError(
              StateError(
                'Downloaded file failed verification '
                '(expected ${release.apkSize} bytes, '
                'got ${verification.actualSize})',
              ),
            );
            await controller.close();
          }
          return;
        }
        if (!controller.isClosed) {
          // 1.0 so the progress UI lands on full before it closes.
          controller.add(
            UpdateDownloadProgress(
              progress: 1.0,
              receivedBytes: verification.actualSize,
              totalBytes: verification.actualSize,
            ),
          );
          await controller.close();
        }
      case TaskStatus.failed:
      case TaskStatus.canceled:
        // Interrupted / cancelled: delete the partial file so it can
        // never be mistaken for a finished download.
        if (_activeFile != null) await deleteFileQuietly(_activeFile!);
        if (!controller.isClosed) {
          if (update.status == TaskStatus.canceled) {
            await controller.close();
          } else {
            controller.addError(
              StateError(
                'Update download failed'
                '${update.exception != null ? ': ${update.exception}' : ''}',
              ),
            );
            await controller.close();
          }
        }
      case TaskStatus.enqueued:
      case TaskStatus.running:
      case TaskStatus.paused:
      case TaskStatus.notFound:
      case TaskStatus.waitingToRetry:
        // Progress arrives via the progress callback; nothing to do here.
        break;
    }
  }

  @override
  Future<void> cancel() async {
    final taskId = _activeTaskId;
    if (taskId != null) {
      await FileDownloader().cancelTaskWithId(taskId);
    }
    if (_activeFile != null) await deleteFileQuietly(_activeFile!);
    _activeTaskId = null;
    _activeFile = null;
    _activeRelease = null;
  }
}
