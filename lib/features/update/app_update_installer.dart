// In-app updates (YumeFlix 2.11.0) — Android install bridge.
//
// The system installer is the only way to install an APK the app
// downloaded itself, and Android requires the user to confirm the install
// tap: the app can open the installer, it can never install silently.
// Three calls, all implemented in MainActivity.kt on channel
// `yume.flix.by.nzr/app_update`:
//
//   * canRequestInstall — PackageManager.canRequestPackageInstalls():
//     true when the user already allowed "Install unknown apps" for us.
//   * requestInstallPermission — opens the system "Install unknown apps"
//     settings page for this app (ACTION_MANAGE_UNKNOWN_APP_SOURCES).
//     The user flips the switch there; the app cannot do it for them.
//   * installApk — fires ACTION_INSTALL_PACKAGE with a FileProvider URI
//     for the downloaded APK (content://, FLAG_GRANT_READ_URI_PERMISSION).
//     The system installer opens and the user taps Install.
//
// The channel is injectable for tests (a mock MethodChannel answers the
// same three calls in test/app_update_test.dart).

import 'dart:async';

import 'package:flutter/services.dart';

class AppUpdateInstaller {
  static const MethodChannel _defaultChannel = MethodChannel(
    'yume.flix.by.nzr/app_update',
  );

  final MethodChannel _channel;

  AppUpdateInstaller({MethodChannel? channel})
    : _channel = channel ?? _defaultChannel;

  /// True when "Install unknown apps" is already allowed for YumeFlix.
  /// On any platform error, false — the caller then shows the guidance
  /// dialog instead of assuming.
  Future<bool> canRequestInstall() async {
    try {
      final result = await _channel.invokeMethod<bool>('canRequestInstall');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the system "Install unknown apps" settings page for this app.
  /// Returns false only when the settings page could not be opened.
  Future<bool> requestInstallPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'requestInstallPermission',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the Android installer for the APK at [apkPath]. The installer
  /// is a system screen; the user still has to tap Install there.
  /// Returns false only when the intent could not be fired at all.
  Future<bool> installApk(String apkPath) async {
    try {
      final result = await _channel.invokeMethod<bool>('installApk', {
        'path': apkPath,
      });
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
