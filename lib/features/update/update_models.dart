// In-app updates (YumeFlix 2.11.0) — pure data model + version logic.
//
// No Flutter, no platform channels, no I/O in this file: everything here
// is unit-testable in isolation (see test/app_update_test.dart).
//
// Update source: the project's public GitHub releases, latest-release API:
//   https://api.github.com/repos/DevDoodle-69/YumeFlix-uprated/releases/latest
// No auth, no token — the endpoint is public. The user never opens GitHub;
// the app fetches this itself (see update_service.dart).

/// GitHub releases API endpoint for the latest YumeFlix release.
const String kUpdateReleasesApiUrl =
    'https://api.github.com/repos/DevDoodle-69/YumeFlix-uprated/releases/latest';

/// Group name for the APK download inside background_downloader. A group of
/// its own (not the 'downloads' group DownloadService uses) so the update
/// download gets its own system notification and its own callbacks, and so
/// its tasks never appear in the app's download list.
const String kAppUpdateDownloadGroup = 'app-update';

/// Subdirectory of the application documents directory where the update APK
/// lives. Application documents (getApplicationDocumentsDirectory(), i.e.
/// Android getFilesDir()) — NOT external storage — because:
///
///   * it needs no storage permission on any API level, and
///   * the FileProvider already declared in AndroidManifest.xml serves it
///     via its `<files-path>` entry, which is what the install intent needs.
///
/// See update_downloader.dart for the download itself.
const String kAppUpdateDownloadDir = 'updates';

/// A parsed GitHub release that carries a usable universal APK.
class UpdateRelease {
  /// Version from the release tag, without the leading "v" ("2.11.0").
  final String version;

  /// Raw tag as published ("v2.11.0").
  final String tag;

  /// Short "What's new" text derived from the release body (see
  /// [shortReleaseNotes]). May be empty when the release has no body.
  final String notes;

  /// Direct download URL (browser_download_url) of the universal APK asset.
  final String apkUrl;

  /// File name of the universal APK asset.
  final String apkName;

  /// Size in bytes the release reports for the asset, or -1 when unknown.
  /// Used to verify the download (see verifyDownloadedFile).
  final int apkSize;

  /// SHA-256 of the asset when the release publishes one. GitHub releases
  /// do not currently publish a checksum file for YumeFlix, so this is
  /// null in practice and size verification is the gate; when a checksum
  /// becomes available it is verified too (see verifyDownloadedFile).
  final String? apkSha256;

  const UpdateRelease({
    required this.version,
    required this.tag,
    required this.notes,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    this.apkSha256,
  });

  /// Local file name for the downloaded APK. Derived from the asset name so
  /// a stale file for another version can never be mistaken for this one.
  String get localFileName => apkName;
}

/// Parses a `major.minor.patch` version into its numeric parts, or null
/// when the text is not a plain release version.
///
/// Rules (all covered by tests):
///   * an optional leading "v" and surrounding whitespace are stripped;
///   * build metadata ("+2100") is dropped;
///   * a pre-release suffix ("-beta.1", "-rc.1") makes the whole tag
///     unusable — pre-release tags are never offered as updates;
///   * missing parts default to 0 ("2.11" == "2.11.0");
///   * non-numeric parts fail the parse (null).
List<int>? parseVersion(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  // Build metadata is irrelevant to "is this newer".
  final plus = text.indexOf('+');
  if (plus != -1) text = text.substring(0, plus);
  // Pre-release tags are ignored entirely — never offered as an update.
  if (text.contains('-')) return null;
  if (text.isEmpty) return null;
  final parts = text.split('.');
  if (parts.length > 3) return null;
  final numbers = <int>[];
  for (final part in parts) {
    if (part.isEmpty) return null;
    final value = int.tryParse(part);
    if (value == null || value < 0) return null;
    numbers.add(value);
  }
  while (numbers.length < 3) {
    numbers.add(0);
  }
  return numbers;
}

/// Compares two version strings the way [parseVersion] parses them.
/// Returns <0, 0 or >0. Unparseable input (including pre-release tags)
/// compares as equal to everything — the caller treats it as "not newer".
int compareVersions(String a, String b) {
  final pa = parseVersion(a);
  final pb = parseVersion(b);
  if (pa == null || pb == null) return 0;
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

/// True when [latest] is a plain release version strictly newer than
/// [current]. Pre-release tags are never "newer".
bool isNewerVersion(String current, String latest) {
  if (parseVersion(latest) == null) return false;
  if (parseVersion(current) == null) return false;
  return compareVersions(current, latest) < 0;
}

/// Picks the universal APK asset out of a release's `assets` list.
///
/// Selection order — the first rule that matches wins:
///   1. the exact published name pattern `yumeflix-android-universal-vX.Y.Z.apk`
///   2. any `.apk` whose name contains "universal" (covers a renamed asset,
///      e.g. `YumeFlix-2.10.0-Universal.apk`)
///   3. nothing — a split APK (per-ABI) is never picked. Installing the
///      wrong ABI's split would brick the update on other devices, so when
///      no universal asset exists the release is not offered at all.
Map<String, dynamic>? selectUniversalApkAsset(List<dynamic> assets) {
  final apks = <Map<String, dynamic>>[];
  for (final raw in assets) {
    if (raw is! Map<String, dynamic>) continue;
    final name = raw['name'] as String?;
    final url = raw['browser_download_url'] as String?;
    if (name == null || url == null) continue;
    if (!name.toLowerCase().endsWith('.apk')) continue;
    apks.add(raw);
  }
  final exact = RegExp(
    r'^yumeflix-android-universal-v[\d.]+\.apk$',
    caseSensitive: false,
  );
  for (final apk in apks) {
    if (exact.hasMatch((apk['name'] as String?) ?? '')) return apk;
  }
  for (final apk in apks) {
    if (((apk['name'] as String?) ?? '').toLowerCase().contains('universal')) {
      return apk;
    }
  }
  return null;
}

/// Parses one GitHub latest-release JSON object into an [UpdateRelease],
/// or null when the release must not be offered:
///
///   * a draft or pre-release (`draft: true`, `prerelease: true`, or a
///     pre-release tag) is skipped;
///   * a release with no universal APK asset is skipped (never a split APK);
///   * a malformed payload is skipped — the caller treats null as "no
///     update available" and fails silently.
UpdateRelease? parseLatestRelease(Map<String, dynamic> json) {
  if (json['draft'] == true || json['prerelease'] == true) return null;
  final tag = (json['tag_name'] as String?)?.trim() ?? '';
  final version = tag.startsWith('v') || tag.startsWith('V')
      ? tag.substring(1)
      : tag;
  if (parseVersion(tag) == null) return null;
  final assets = json['assets'];
  if (assets is! List) return null;
  final asset = selectUniversalApkAsset(assets);
  if (asset == null) return null;
  final apkUrl = asset['browser_download_url'] as String?;
  final apkName = asset['name'] as String?;
  if (apkUrl == null || apkUrl.isEmpty || apkName == null || apkName.isEmpty) {
    return null;
  }
  final size = asset['size'];
  return UpdateRelease(
    version: version,
    tag: tag,
    notes: shortReleaseNotes(json['body'] as String?),
    apkUrl: apkUrl,
    apkName: apkName,
    apkSize: size is num ? size.toInt() : -1,
    // The release publishes no checksum file today; when one is added,
    // parse it here and verification in update_downloader.dart picks it up.
    apkSha256: null,
  );
}

/// Turns a release body into the short "What's new" shown in the prompt:
/// first non-empty lines, markdown headings/bullets flattened, capped so
/// the dialog stays a dialog and not a changelog page.
String shortReleaseNotes(String? body, {int maxChars = 480}) {
  if (body == null) return '';
  final lines = <String>[];
  for (final rawLine in body.split('\n')) {
    var line = rawLine.trim();
    if (line.isEmpty) continue;
    // Strip markdown heading markers and list bullets.
    line = line.replaceFirst(RegExp(r'^#{1,6}\s+'), '');
    line = line.replaceFirst(RegExp(r'^[-*]\s+'), '• ');
    // Skip bare links / image embeds — they render as noise in a dialog.
    if (line.startsWith('![') || line.startsWith('[')) continue;
    lines.add(line);
    if (lines.join('\n').length >= maxChars) break;
  }
  var text = lines.join('\n');
  if (text.length > maxChars) {
    text = '${text.substring(0, maxChars).trimRight()}…';
  }
  return text;
}

/// Human-readable size, e.g. "114 MB". Used by the prompt and progress UI.
String formatBytes(int bytes) {
  if (bytes < 0) return '—';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
}
