// In-app updates (YumeFlix 2.11.0) — the release check.
//
// Fetches the latest public GitHub release and turns it into an
// [UpdateRelease], or null when there is nothing to offer. Every failure
// mode — no network, non-200, malformed JSON, a release with no universal
// APK — returns null: the check fails silently by design (the app works
// exactly as before, no error, no prompt, no crash).
//
// The fetch is injectable ([fetchReleaseJson]) so tests can drive the
// failure paths without a network.

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'update_models.dart';

/// Fetches the latest-release JSON. Production default is a plain
/// `package:http` GET with a short timeout; tests inject a fake.
typedef ReleaseJsonFetcher =
    Future<Map<String, dynamic>?> Function(Uri uri);

Future<Map<String, dynamic>?> fetchLatestReleaseJson(Uri uri) async {
  try {
    final response = await http
        .get(
          uri,
          headers: {
            'Accept': 'application/vnd.github+json',
            // GitHub asks for a User-Agent; anything identifying the app
            // will do. No token — the releases endpoint is public.
            'User-Agent': 'YumeFlix',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    // No network, timeout, bad JSON — all silent, all "no update".
    return null;
  }
}

/// Returns the latest usable release, or null when there is none / the
/// check failed. [currentVersion] is the installed version (e.g. "2.10.0"
/// from package_info_plus); a release is only returned when it is strictly
/// newer — equal and older tags are not updates.
Future<UpdateRelease?> checkForUpdate({
  required String currentVersion,
  ReleaseJsonFetcher fetchReleaseJson = fetchLatestReleaseJson,
}) async {
  Map<String, dynamic>? json;
  try {
    json = await fetchReleaseJson(Uri.parse(kUpdateReleasesApiUrl));
  } catch (_) {
    // A throwing fetch is the same as no network: silent, no update.
    return null;
  }
  if (json == null) return null;
  final release = parseLatestRelease(json);
  if (release == null) return null;
  if (!isNewerVersion(currentVersion, release.version)) return null;
  return release;
}
