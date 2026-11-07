import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the first-launch extension setup guide has been shown.
///
/// Keeping this state separate from widget lifecycle makes the one-time rule
/// deterministic across dashboard rebuilds, route changes, and process restarts.
class HomeOnboardingState {
  static const String _extensionGuideSeenKey =
      'home_extension_setup_guide_seen_v1';

  /// Claims the first-launch guide once. Returns false after it was seen.
  static Future<bool> claimExtensionGuideForFirstLaunch() async {
    final preferences = await SharedPreferences.getInstance();
    if (preferences.getBool(_extensionGuideSeenKey) ?? false) return false;
    await preferences.setBool(_extensionGuideSeenKey, true);
    return true;
  }

  /// Marks the guide as seen when the user opens it again from the dashboard.
  static Future<void> markExtensionGuideSeen() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_extensionGuideSeenKey, true);
  }
}
