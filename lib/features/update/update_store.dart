// In-app updates (YumeFlix 2.11.0) — persisted update state.
//
// Everything the snooze / auto-download rules need to remember across
// launches, in SharedPreferences. Keys are namespaced `app_update.*` so
// they never collide with the app's other preferences.
//
// Rules implemented here (decided in update_decision.dart, stored here):
//   * the update check runs at most once a day;
//   * a dismissed prompt is never shown again for that version — the
//     3-day clock (from first sight) is what brings the update back, as
//     an automatic background download, not as another prompt;
//   * a verified downloaded APK is remembered so the "tap to install"
//     prompt survives a restart.

import 'package:shared_preferences/shared_preferences.dart';

/// Injectable clock: `DateTime.now` in production, a controllable fake in
/// tests (see test/app_update_test.dart).
typedef UpdateClock = DateTime Function();

class UpdateStore {
  static const String _lastCheckKey = 'app_update.last_check_ms';
  static const String _dismissedVersionKey = 'app_update.dismissed_version';
  static const String _downloadedVersionKey =
      'app_update.downloaded_version';
  static const String _downloadedPathKey = 'app_update.downloaded_path';
  static const String _downloadedSizeKey = 'app_update.downloaded_size';
  static const String _downloadedSha256Key = 'app_update.downloaded_sha256';

  static String _firstSeenKey(String version) =>
      'app_update.first_seen_ms.$version';
  static String _lastPromptKey(String version) =>
      'app_update.last_prompt_ms.$version';

  final SharedPreferences _prefs;
  final UpdateClock _clock;

  UpdateStore(this._prefs, {UpdateClock? clock})
    : _clock = clock ?? DateTime.now;

  DateTime get now => _clock();

  // -- check scheduling ---------------------------------------------------

  DateTime? get lastCheckMs {
    final ms = _prefs.getInt(_lastCheckKey);
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> recordCheck() async {
    await _prefs.setInt(
      _lastCheckKey,
      now.toUtc().millisecondsSinceEpoch,
    );
  }

  // -- first sight / prompt / dismiss -------------------------------------

  /// When the user first saw the prompt (or the release) for [version].
  /// Recorded once and never moved — it anchors the 3-day auto-download.
  DateTime? firstSeen(String version) {
    final ms = _prefs.getInt(_firstSeenKey(version));
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> recordFirstSeen(String version) async {
    if (firstSeen(version) != null) return;
    await _prefs.setInt(
      _firstSeenKey(version),
      now.toUtc().millisecondsSinceEpoch,
    );
  }

  DateTime? lastPrompt(String version) {
    final ms = _prefs.getInt(_lastPromptKey(version));
    return ms == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> recordPrompt(String version) async {
    await _prefs.setInt(
      _lastPromptKey(version),
      now.toUtc().millisecondsSinceEpoch,
    );
  }

  /// The version the user dismissed with "Later", or null. Dismissing is
  /// respected: no further prompt for that version (see update_decision).
  String? get dismissedVersion => _prefs.getString(_dismissedVersionKey);

  Future<void> recordDismissed(String version) async {
    await _prefs.setString(_dismissedVersionKey, version);
  }

  /// Clears the dismissal — used when the user taps "Update now" after all
  /// (or when a newer version supersedes the dismissed one).
  Future<void> clearDismissed(String version) async {
    if (dismissedVersion == version) {
      await _prefs.remove(_dismissedVersionKey);
    }
  }

  // -- verified download --------------------------------------------------

  /// The version whose APK has been downloaded and verified on disk.
  String? get downloadedVersion => _prefs.getString(_downloadedVersionKey);
  String? get downloadedPath => _prefs.getString(_downloadedPathKey);
  int? get downloadedSize => _prefs.getInt(_downloadedSizeKey);
  String? get downloadedSha256 => _prefs.getString(_downloadedSha256Key);

  Future<void> recordDownloaded({
    required String version,
    required String path,
    required int size,
    String? sha256,
  }) async {
    await _prefs.setString(_downloadedVersionKey, version);
    await _prefs.setString(_downloadedPathKey, path);
    await _prefs.setInt(_downloadedSizeKey, size);
    if (sha256 != null) {
      await _prefs.setString(_downloadedSha256Key, sha256);
    } else {
      await _prefs.remove(_downloadedSha256Key);
    }
  }

  Future<void> clearDownloaded() async {
    await _prefs.remove(_downloadedVersionKey);
    await _prefs.remove(_downloadedPathKey);
    await _prefs.remove(_downloadedSizeKey);
    await _prefs.remove(_downloadedSha256Key);
  }
}
