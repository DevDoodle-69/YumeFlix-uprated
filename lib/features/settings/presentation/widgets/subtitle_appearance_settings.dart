/// The subtitle appearance editor, back where it can be reached.
///
/// `subtitle_style.dart` has always translated [PlayerSettings.subtitleSize],
/// [PlayerSettings.subtitleColor], [PlayerSettings.subtitleBackgroundColor] and
/// [PlayerSettings.subtitleBackgroundOpacity] into the libVLC options the
/// engine honours — but the only screen that ever wrote those four fields left
/// with the media_kit player, so every user has been pinned to the defaults.
///
/// The preview is built from `subtitleStyleFrom` rather than from the raw
/// settings, so it cannot drift from what the engine is told. It reproduces
/// VLC's own sizing rule: the rendered glyph height is the video height divided
/// by the relative font size, which is why a *smaller* number means *bigger*
/// text and why the preview scales with the screen instead of with the slider.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yumeflix/l10n/generated/app_localizations.dart';

import '../../../../shared/widgets/custom_widgets.dart';
import '../../../player/domain/subtitle_style.dart';
import '../player_settings_provider.dart';
import 'settings_widgets.dart';

/// The caption colours worth offering, in the order broadcast captioning has
/// used them for decades: white first, then the high-contrast pair that stays
/// legible over bright scenes.
///
/// Bare ARGB rather than a name-keyed map: the names are translated, and a
/// translated key is not a stable identity for a stored colour.
/// [subtitleColorLabel] is the one place that names them.
const List<int> kSubtitleTextColors = <int>[
  0xFFFFFFFF,
  0xFFFFEB3B,
  0xFF4DD0E1,
  0xFF81C784,
  0xFFE040FB,
  0xFFEF5350,
  0xFF000000,
];

/// Box colours. The *alpha* of the stored value is never used —
/// `subtitleStyleFrom` replaces it with [PlayerSettings.subtitleBackgroundOpacity]
/// — so these are opaque and the opacity slider owns transparency outright.
const List<int> kSubtitleBackgroundColors = <int>[
  0xFF000000,
  0xFF303030,
  0xFFFFFFFF,
];

/// Name of [argb] if it is one of the offered colours, otherwise its hex.
///
/// A value can be off-list: older installs stored whatever the deleted dialog
/// wrote, and a settings row that says nothing at all is worse than one that
/// says `#FF8800`.
String subtitleColorLabel(AppLocalizations l10n, int argb) => switch (argb) {
  0xFFFFFFFF => l10n.colorWhite,
  0xFFFFEB3B => l10n.colorYellow,
  0xFF4DD0E1 => l10n.colorCyan,
  0xFF81C784 => l10n.colorGreen,
  0xFFE040FB => l10n.colorMagenta,
  0xFFEF5350 => l10n.colorRed,
  0xFF000000 => l10n.colorBlack,
  0xFF303030 => l10n.colorDarkGrey,
  _ => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
};

/// One-line summary of the background box.
///
/// Zero opacity is the only way to get no box at all — `subtitleStyleFrom`
/// drops the background when the resulting alpha is zero — so it is spelled
/// out as "Off" rather than as "0%".
String subtitleBackgroundLabel(AppLocalizations l10n, PlayerSettings settings) {
  final percent = (settings.subtitleBackgroundOpacity.clamp(0.0, 1.0) * 100)
      .round();
  if (percent == 0) return l10n.off;
  return l10n.subtitleBackgroundSummary(
    subtitleColorLabel(l10n, settings.subtitleBackgroundColor),
    percent,
  );
}

/// Height of the video frame the engine will scale subtitles against.
///
/// Playback is landscape, so the frame is as tall as the *short* edge of the
/// window no matter which way the settings screen happens to be held. On a
/// television the window is already landscape and this is simply its height.
double subtitleFrameHeight(Size window) =>
    math.min(window.width, window.height);

/// Subtitle appearance rows, styled like every other section on the screen.
class SubtitleAppearanceGroup extends ConsumerWidget {
  const SubtitleAppearanceGroup({required this.settings, super.key});

  final PlayerSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return SettingsGroup(
      title: l10n.subtitleSettings,
      children: [
        // Not a SettingsTile: there is nothing to activate here, and a
        // focusable row that does nothing is a D-pad dead end.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: SubtitlePreview(
            settings: settings,
            sample: l10n.subtitlePreviewSample,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            l10n.subtitleAppearanceNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        SettingsTile(
          icon: Icons.format_size_rounded,
          title: l10n.textSize,
          subtitle: '${settings.subtitleSize.round()}',
          onTap: () => showSubtitleSizeDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.palette_outlined,
          title: l10n.subtitleTextColour,
          subtitle: subtitleColorLabel(l10n, settings.subtitleColor),
          trailing: _Swatch(color: Color(settings.subtitleColor)),
          onTap: () => showSubtitleColorDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.format_color_fill_rounded,
          title: l10n.background,
          subtitle: subtitleBackgroundLabel(l10n, settings),
          onTap: () => showSubtitleBackgroundDialog(context, ref, settings),
        ),
        SettingsTile(
          icon: Icons.restart_alt_rounded,
          title: l10n.resetSubtitleAppearance,
          subtitle: l10n.resetSubtitleAppearanceSubtitle,
          isLast: true,
          onTap: () =>
              ref.read(playerSettingsProvider.notifier).resetSubtitleSettings(),
        ),
      ],
    );
  }
}

/// A sample caption drawn the way libVLC will draw it.
class SubtitlePreview extends StatelessWidget {
  const SubtitlePreview({
    required this.settings,
    required this.sample,
    super.key,
  });

  final PlayerSettings settings;

  /// Supplied rather than defaulted, so the phrase is the caller's translated
  /// one. A preview whose sample is in the wrong script says nothing useful
  /// about how the reader's own subtitles will look.
  final String sample;

  @override
  Widget build(BuildContext context) {
    final style = subtitleStyleFrom(settings);
    final frameHeight = subtitleFrameHeight(MediaQuery.sizeOf(context));
    final fontSize = frameHeight / (style.relativeFontSize ?? 16);
    final outline = (style.outlineThickness ?? 0).toDouble();

    return Container(
      // Tracks the text so the preview reads as a frame rather than a label,
      // and stops growing before it takes over the screen it is describing.
      height: (fontSize * 1.9 + 24).clamp(72.0, 160.0),
      alignment: Alignment.bottomCenter,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF37474F), Color(0xFF11171A)],
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        color: style.backgroundColor,
        child: Stack(
          children: [
            // VLC outlines the glyphs; a plain Text cannot, so the stroke is a
            // second copy underneath. Without it white-on-bright is the exact
            // illegibility the outline exists to prevent.
            if (outline > 0)
              Text(
                sample,
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  foreground: Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = outline
                    ..color = style.outlineColor ?? const Color(0xFF000000),
                ),
              ),
            Text(
              sample,
              maxLines: 1,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: style.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Text size, previewed while it is dragged.
void showSubtitleSizeDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  var size = settings.subtitleSize;

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        surfaceTintColor: Colors.transparent,
        title: Text(l10n.textSize),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubtitlePreview(
              settings: settings.copyWith(subtitleSize: size),
              sample: l10n.subtitlePreviewSample,
            ),
            const SizedBox(height: 12),
            Text(l10n.size(size.round())),
            CustomSlider(
              value: size,
              min: 10,
              max: 80,
              divisions: 70,
              onChanged: (value) => setState(() => size = value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop<void>(ctx),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              ref
                  .read(playerSettingsProvider.notifier)
                  .setSubtitleSettings(
                    size,
                    settings.subtitleColor,
                    settings.subtitleBackgroundColor,
                    settings.subtitleBackgroundOpacity,
                  );
              Navigator.pop<void>(ctx);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    ),
  );
}

/// Text colour. Applied on selection, like the other option lists here.
void showSubtitleColorDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      surfaceTintColor: Colors.transparent,
      title: Text(l10n.subtitleTextColour),
      content: RadioGroup<int>(
        groupValue: settings.subtitleColor,
        onChanged: (value) {
          if (value == null) return;
          ref
              .read(playerSettingsProvider.notifier)
              .setSubtitleSettings(
                settings.subtitleSize,
                value,
                settings.subtitleBackgroundColor,
                settings.subtitleBackgroundOpacity,
              );
          Navigator.pop<void>(ctx);
        },
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final argb in kSubtitleTextColors)
                ListTile(
                  leading: Radio<int>(value: argb),
                  title: Text(subtitleColorLabel(l10n, argb)),
                  trailing: _Swatch(color: Color(argb)),
                  onTap: () {
                    ref
                        .read(playerSettingsProvider.notifier)
                        .setSubtitleSettings(
                          settings.subtitleSize,
                          argb,
                          settings.subtitleBackgroundColor,
                          settings.subtitleBackgroundOpacity,
                        );
                    Navigator.pop<void>(ctx);
                  },
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Background colour and opacity together, because neither means anything on
/// its own: zero opacity is what "no box" is, whatever the colour says.
void showSubtitleBackgroundDialog(
  BuildContext context,
  WidgetRef ref,
  PlayerSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  var color = settings.subtitleBackgroundColor;
  var opacity = settings.subtitleBackgroundOpacity.clamp(0.0, 1.0);

  showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final preview = settings.copyWith(
          subtitleBackgroundColor: color,
          subtitleBackgroundOpacity: opacity,
        );
        return AlertDialog(
          surfaceTintColor: Colors.transparent,
          title: Text(l10n.background),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SubtitlePreview(
                  settings: preview,
                  sample: l10n.subtitlePreviewSample,
                ),
                const SizedBox(height: 12),
                RadioGroup<int>(
                  groupValue: color,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      color = value;
                      // Picking a colour while the box is off obviously means
                      // "switch it on", so give it something to show.
                      if (opacity == 0) opacity = 0.5;
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final argb in kSubtitleBackgroundColors)
                        ListTile(
                          dense: true,
                          leading: Radio<int>(value: argb),
                          title: Text(subtitleColorLabel(l10n, argb)),
                          trailing: _Swatch(color: Color(argb)),
                          onTap: () => setState(() {
                            color = argb;
                            if (opacity == 0) opacity = 0.5;
                          }),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  opacity == 0
                      ? l10n.opacityOff
                      : l10n.opacityPercent((opacity * 100).round()),
                ),
                CustomSlider(
                  value: opacity,
                  max: 1,
                  divisions: 20,
                  step: 0.05,
                  onChanged: (value) => setState(() => opacity = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop<void>(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                ref
                    .read(playerSettingsProvider.notifier)
                    .setSubtitleSettings(
                      settings.subtitleSize,
                      settings.subtitleColor,
                      color,
                      opacity,
                    );
                Navigator.pop<void>(ctx);
              },
              child: Text(l10n.save),
            ),
          ],
        );
      },
    ),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
    );
  }
}
