// In-app updates (YumeFlix 2.11.0) — prompt + progress UI.
//
// Minimal professional style, matching the rest of the app: the theme's
// own surface / on-surface / primary colours (primary is the muted
// slate-blue), no neon, no glow, no gradients. All dialogs are dumb views:
// the coordinator (update_coordinator.dart) decides when they appear and
// what their buttons do.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'update_downloader.dart';
import 'update_models.dart';

/// Shows the soft update prompt. Returns true when the user tapped
/// "Update now", false for "Later" / dismiss. The dialog is dismissible:
/// "Later" is a real choice, and dismissing is recorded by the caller.
Future<bool> showUpdatePrompt({
  required BuildContext context,
  required UpdateRelease release,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final theme = Theme.of(context);
      final notes = release.notes;
      return AlertDialog(
        title: Text('Update available — v${release.version}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'YumeFlix ${release.version} is ready '
                '(${formatBytes(release.apkSize)}). '
                'Your library, downloads and settings stay exactly as they are.',
                style: theme.textTheme.bodyMedium,
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  "What's new",
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(notes, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update now'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Progress dialog for a manual ("Update now") download. It is a *view*
/// onto [progress]: the download keeps running if the dialog is dismissed
/// (barrier tap), and the coordinator re-shows it when the user taps the
/// system notification. [onCancel] cancels the download; the partial file
/// is deleted, never installed.
class UpdateDownloadDialog extends StatelessWidget {
  final UpdateRelease release;
  final ValueListenable<UpdateDownloadProgress?> progress;
  final VoidCallback onCancel;

  const UpdateDownloadDialog({
    super.key,
    required this.release,
    required this.progress,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Downloading v${release.version}'),
      content: ValueListenableBuilder<UpdateDownloadProgress?>(
        valueListenable: progress,
        builder: (context, value, _) {
          final pct = value == null || value.progress < 0
              ? null
              : (value.progress * 100).round();
          final received = value == null || value.receivedBytes < 0
              ? '—'
              : formatBytes(value.receivedBytes);
          final total = value == null || value.totalBytes <= 0
              ? formatBytes(release.apkSize)
              : formatBytes(value.totalBytes);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: value == null || value.progress < 0
                    ? null
                    : value.progress.clamp(0.0, 1.0),
              ),
              const SizedBox(height: 12),
              Text(
                pct == null
                    ? 'Starting… ($received / $total)'
                    : '$pct%  •  $received / $total',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Downloading in the background — you can keep using the app.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// Shows the progress dialog. Returns when the dialog is dismissed; the
/// download itself is unaffected by dismissal.
Future<void> showUpdateDownloadDialog({
  required BuildContext context,
  required UpdateRelease release,
  required ValueListenable<UpdateDownloadProgress?> progress,
  required VoidCallback onCancel,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => UpdateDownloadDialog(
      release: release,
      progress: progress,
      onCancel: () {
        onCancel();
        Navigator.of(context).pop();
      },
    ),
  );
}

/// "Download complete — tap to install". Returns true when the user tapped
/// "Install", false for "Later". The install itself still opens the
/// system installer, where the user confirms.
Future<bool> showDownloadCompleteDialog({
  required BuildContext context,
  required UpdateRelease release,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text('YumeFlix ${release.version} downloaded'),
        content: Text(
          'The update (${formatBytes(release.apkSize)}) is ready. '
          'Tap Install to open the Android installer and confirm.',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Install'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Explains the one-time "Install unknown apps" permission, shown when the
/// user has not allowed it yet. Returns true for "Open settings".
/// The update stays available if the user declines — nothing is forced.
Future<bool> showInstallPermissionDialog({
  required BuildContext context,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: const Text('Allow installing updates'),
        content: Text(
          'Android asks once before YumeFlix can install an update it '
          'downloaded itself. Turn on "Allow from this source" for '
          'YumeFlix on the next screen, then come back and tap Install.',
          style: theme.textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}
