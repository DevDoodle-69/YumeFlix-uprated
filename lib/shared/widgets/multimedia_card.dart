import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/presentation/general_settings_provider.dart';
import 'cinematic_poster_card.dart';

/// The app's poster card, kept as the stable public API every rail, grid
/// and search result already uses.
///
/// 2.6.0: the rendering moved into [CinematicPosterCard] — 22 dp corners,
/// a gradient scrim with the title and meta on the card, and glass chips
/// for rating / type. This widget now only resolves the user's
/// `titlePosition` setting (`inside` vs `below`) and forwards the new
/// optional metadata through.
class MultimediaCard extends ConsumerWidget {
  final String? imageUrl;
  final String title;
  final VoidCallback onTap;
  final String heroTag;
  final bool isPortrait;
  final FocusNode? focusNode;

  /// Rating out of 10, shown as a gold glass chip. Null hides the chip.
  final double? rating;

  /// Release year, shown in the meta line under the title.
  final int? year;

  /// Duration in minutes, shown in the meta line ("1h 56m" / "96m").
  final int? durationMinutes;

  /// Media-type label ("MOVIE", "TV", "ANIME"), top-right glass chip.
  final String? typeLabel;

  /// Explicit card width. Null means the rail default for the form factor.
  final double? width;

  const MultimediaCard({
    super.key,
    required this.imageUrl,
    required this.title,
    required this.onTap,
    required this.heroTag,
    this.isPortrait = true,
    this.focusNode,
    this.rating,
    this.year,
    this.durationMinutes,
    this.typeLabel,
    this.width,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final titlePosition = ref.watch(
      generalSettingsProvider.select((s) => s.titlePosition),
    );
    final isInside = titlePosition == 'inside';

    return CinematicPosterCard(
      imageUrl: imageUrl,
      title: title,
      onTap: onTap,
      heroTag: heroTag,
      isPortrait: isPortrait,
      focusNode: focusNode,
      rating: rating,
      year: year,
      durationMinutes: durationMinutes,
      typeLabel: typeLabel,
      titleInside: isInside,
      width: width,
    );
  }
}
