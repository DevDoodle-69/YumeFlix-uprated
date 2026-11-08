// In-app updates (YumeFlix 2.11.0) — the prompt / snooze / auto-download
// decision, as a pure function of (release, stored state, clock, network).
//
// Kept free of I/O so every rule is unit-testable with an injectable clock
// (see test/app_update_test.dart). The coordinator (update_coordinator.dart)
// is the only caller; it supplies the inputs and acts on the result.

import 'update_models.dart';
import 'update_store.dart';

/// How often the app may check GitHub for a new release.
const Duration kUpdateCheckInterval = Duration(days: 1);

/// How long after the user first sees (or dismisses) a version the app
/// waits before downloading it on its own, in the background.
const Duration kUpdateAutoDownloadAfter = Duration(days: 3);

/// What the app should do about a release right now.
enum UpdateAction {
  /// Nothing to do: no newer release, or the user dismissed this version
  /// and the 3-day window has not elapsed yet.
  none,

  /// Show the soft prompt ("Update now" / "Later"). At most once per
  /// version per day.
  prompt,

  /// The user dismissed this version 3+ days ago: download the APK in the
  /// background now, without asking again. Only ever chosen on Wi-Fi —
  /// see [decideUpdateAction].
  autoDownload,

  /// A verified APK for this version is already on disk: offer install.
  offerInstall,
}

/// Whether the last check is old enough that a new one is due.
bool isUpdateCheckDue(DateTime? lastCheck, DateTime now) {
  if (lastCheck == null) return true;
  return now.difference(lastCheck) >= kUpdateCheckInterval;
}

/// Decides what to do about [release] (null = no newer release known).
///
/// [isWifi] is true only on an unmetered connection (Wi-Fi or Ethernet).
/// The 3-day auto-download is deliberately Wi-Fi-only: a ~120 MB APK must
/// never silently consume the user's mobile data. On mobile data the
/// decision falls back to [UpdateAction.prompt] so the user can choose to
/// download on mobile data themselves — the prompt is re-shown in that
/// case, once per day, because the auto-download is still pending.
///
/// [downloadedFileValid] is true only when a verified APK for this version
/// is already on disk (the coordinator checks the file + size first).
UpdateAction decideUpdateAction({
  required UpdateRelease? release,
  required UpdateStore store,
  required DateTime now,
  required bool isWifi,
  required bool downloadedFileValid,
}) {
  if (release == null) return UpdateAction.none;
  final version = release.version;

  // A verified download beats every other state: offer the install.
  if (downloadedFileValid) return UpdateAction.offerInstall;

  final dismissed = store.dismissedVersion == version;
  final firstSeen = store.firstSeen(version);

  if (dismissed && firstSeen != null) {
    final sinceFirstSeen = now.difference(firstSeen);
    if (sinceFirstSeen >= kUpdateAutoDownloadAfter) {
      // 3 days are up: download by ourselves — but only on Wi-Fi.
      // On mobile data, re-show the prompt instead of silently
      // downloading ~120 MB on the user's data plan.
      return isWifi ? UpdateAction.autoDownload : UpdateAction.prompt;
    }
    // Dismissed and inside the 3-day window: respected, stay silent.
    return UpdateAction.none;
  }

  // Not dismissed: prompt at most once per version per day.
  final lastPrompt = store.lastPrompt(version);
  if (lastPrompt != null &&
      now.difference(lastPrompt) < const Duration(days: 1)) {
    return UpdateAction.none;
  }
  return UpdateAction.prompt;
}
