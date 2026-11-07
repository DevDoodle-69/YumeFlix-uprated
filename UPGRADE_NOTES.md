# YumeFlix 2.3.2 upgrade notes

## YumeFlix 2.3.2 — phone-first refinements

- Renamed the Dart package, Android namespace/method channels, app labels and new download folders to YumeFlix. The Android `applicationId` stays `yume.flix.by.nzr` so app identity and private app data remain stable; existing `Skystream` download folders remain readable and safely cleanable.
- The default extension repository is browsable on first run, but executable extensions are no longer installed automatically. Users install extensions explicitly.
- When no provider choice has ever been saved, an installed, non-debug provider named exactly `4K HD` is selected after extension synchronization. Existing choices—including an explicit `None`—are never overwritten. This does not guarantee actual 4K content or device/network capability.
- Installed extension JavaScript with an install-time SHA-256 mismatch is refused before evaluation. Legacy installs without a recorded hash remain compatible; this check is tamper-evident, not a publisher signature or tamper-proof guarantee.
- The home provider chip has a screen-reader label, tooltip, and a larger phone touch target. New downloads use a YumeFlix folder, while prior offline files stay discoverable in their original folder.
- Release APK builds can be Dart-obfuscated; remember to retain the separate split-debug-info symbols for crash diagnosis. This is not DRM or protection against a determined APK editor.

## Validation for 2.3.2

- Run `flutter analyze --no-fatal-infos` and both unit/widget tests.
- Build one release-mode universal ARM APK (armeabi-v7a and arm64-v8a) using Android API 37.0, Build Tools 37.0.0, NDK 29.0.14206865, and JDK 17.
- The supplied source has no release keystore. Any generated APK is debug-signed for testing only; install-in-place works only if the signing key matches the installed app. No physical device/emulator test is available in this environment.

## Product and visual improvements

- Reworked the dark theme around a calmer midnight-indigo, aurora-indigo, and soft-teal palette.
- Kept the bundled Outfit typography and existing Material 3 architecture.
- Replaced the old Groot no-results art with the supplied transparent PNG; search empty states now share localized text, bounded phone sizing, and a local icon fallback.
- Added a text-free streaming mark designed for launcher-scale legibility.
- Replaced Android phone launcher assets across mdpi–xxxhdpi, iOS AppIcon rasters, and the bundled app asset.

## Phone-only Android behavior

- Android is packaged for touch-enabled phones; the Leanback launcher category, TV banner, and Android TV home-channel method bridge have been removed.
- Android TV provider integration is no longer included in the phone APK.
- Phone navigation, playback, picture-in-picture actions, and external-player handoff remain intact.
- Shared keyboard and accessibility focus behavior is retained where it also benefits phone users.

## Streaming compatibility

- Kept resolver/player User-Agent parity as the primary rule so signed stream URLs do not break.
- Kept a small, explicit compatibility list for browser request headers; resolver and player identities remain consistent and are not rotated per request.
- Existing plugin-provided headers, referers, cookies, DoH, buffering, and VLC playback paths remain intact.

## Validation

- `flutter analyze --no-fatal-infos` and `flutter test test/no_results_state_test.dart` pass.
- Release-mode APKs are built and signature-verified per ABI with Android API 37.0, Build Tools 37.0.0, NDK 29.0.14206865, and JDK 17.
- No release keystore was present in the supplied source. The APK is debug-signed with a new key and cannot update an install signed by the original key; use the matching private key for distribution or in-place updates.
- No Android device/emulator was attached for an install-and-launch smoke test.
