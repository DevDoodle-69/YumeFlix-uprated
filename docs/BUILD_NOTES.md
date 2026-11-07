# YumeFlix 2.3.8 build notes

## Android rebuild

Use Flutter 3.47.6 (Dart 3.13.5), JDK 17 or newer, Android SDK Platform 37.0, Build Tools 37.0.0, NDK 29.0.14206865, and CMake 3.22.1. The local `android/local.properties` file is machine-specific and is intentionally not included in the source archive; Flutter can generate it when configured with an Android SDK.

A TMDB key can be entered in the app's Settings, or supplied at build time as a Dart define. To build with a local environment variable:

```sh
export TMDB_API_KEY='your TMDB v3 API key'
flutter pub get
flutter test test/discord_presence_payload_test.dart test/discord_artwork_resolver_test.dart
flutter build apk --release --target-platform android-arm,android-arm64 --dart-define=TMDB_API_KEY="$TMDB_API_KEY"
```

The source archive intentionally does not contain the TMDB key. Keys embedded in client applications can be extracted; use a TMDB key intended for client-side use and manage/restrict it through the account where possible.

## Signing

The shared source does not contain a release keystore. Without `android/key.properties` and its referenced keystore, this project's Gradle configuration signs a local release build with the Android debug key. That APK is for testing only, is not suitable for Play Store or public distribution, and cannot update an installation signed with a different key. For a production release, provide the app owner's release keystore locally, create `android/key.properties` using the sample/configuration expected by `android/app/build.gradle.kts`, and keep both files out of source control and the source archive.

## Discord integration

The implementation, artwork fallback behavior, and account-token compatibility caveat are documented in [DISCORD_PRESENCE.md](DISCORD_PRESENCE.md).
