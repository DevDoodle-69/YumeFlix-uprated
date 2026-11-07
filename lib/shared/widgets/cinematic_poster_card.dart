import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/utils/image_utils.dart';
import '../../core/utils/responsive_breakpoints.dart';
import 'cards_wrapper.dart';
import 'glass_card.dart';
import 'shimmer_placeholder.dart';
import 'thumbnail_error_placeholder.dart';

/// The 2.7.0 poster card — the one card language for every rail, grid and
/// search result in the app.
///
/// * Restrained rounded corners ([YumeDesign.radiusCard], 16 dp).
/// * A neutral black scrim at the foot of the artwork carrying the title
///   and a meta line (year • duration) *on* the card, so a rail reads as a
///   shelf of posters rather than a shelf of posters plus a shelf of
///   labels. The scrim is monochrome — transparent to black — for text
///   legibility only, never coloured.
/// * Monochrome glass chips for rating (top-left) and media type
///   (top-right) when the caller passes them — small, blurred, never
///   covering the title.
/// * Press / focus scale via [CardsWrapper] (1.06 on TV, 1.05 on touch),
///   with the focus ring and shadow the wrapper already provides.
///
/// The decode bound is computed from the constraints **above** the [Hero],
/// exactly as [MultimediaCard] did: a hero flight animates the child's box
/// from card size to full-screen size, and a [LayoutBuilder] inside the
/// hero would recompute the decode bound on every frame of the flight.
class CinematicPosterCard extends ConsumerWidget {
  final String? imageUrl;
  final String title;
  final VoidCallback onTap;
  final String heroTag;
  final bool isPortrait;
  final FocusNode? focusNode;

  /// Rating out of 10, shown as a monochrome glass chip. Null hides it.
  final double? rating;

  /// Release year, shown in the meta line under the title.
  final int? year;

  /// Duration in minutes, shown in the meta line ("1h 56m" / "96m").
  final int? durationMinutes;

  /// Media-type label ("MOVIE", "TV", "ANIME"), top-right glass chip.
  final String? typeLabel;

  /// When false the title sits *below* the artwork (the old
  /// `titlePosition: below` setting) instead of on the scrim. The glass
  /// chips and the 16 dp radius stay in both modes.
  final bool titleInside;

  /// Explicit card width. Null means the rail default for the form factor.
  final double? width;

  const CinematicPosterCard({
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
    this.titleInside = true,
    this.width,
  });

  static String formatDuration(int minutes) {
    if (minutes <= 0) return '';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h > 0) return m > 0 ? '${h}h ${m}m' : '${h}h';
    return '${m}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = context.isDesktop;
    final cardWidth =
        width ??
        (isDesktop
            ? (isPortrait
                  ? YumeDesign.posterWidthLarge
                  : YumeDesign.backdropWidthLarge)
            : (isPortrait
                  ? YumeDesign.posterWidthPhone
                  : YumeDesign.backdropWidthPhone));

    final imageWidget = LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : cardWidth;
        return Hero(
          tag: heroTag,
          child: ClipRRect(
            borderRadius: YumeDesign.cardRadius,
            child: CachedNetworkImage(
              imageUrl: imageUrl ?? '',
              fit: BoxFit.cover,
              width: double.infinity,
              memCacheWidth: ImageUtils.coverDecodeWidth(
                context,
                width: boxWidth,
                height: constraints.maxHeight,
                sourceAspectRatio: isPortrait
                    ? ImageUtils.posterAspectRatio
                    : ImageUtils.backdropAspectRatio,
              ),
              placeholder: (context, url) =>
                  ShimmerPlaceholder(borderRadius: YumeDesign.radiusCard),
              errorWidget: (_, _, _) =>
                  ThumbnailErrorPlaceholder(label: title),
            ),
          ),
        );
      },
    );

    final metaLine = _metaLine();
    final chips = _chipsRow();

    return RepaintBoundary(
      child: CardsWrapper(
        onTap: onTap,
        focusNode: focusNode,
        scaleFactor: 1.06,
        borderRadius: YumeDesign.cardRadius,
        child: SizedBox(
          width: cardWidth,
          child: titleInside
              ? _buildInsideMode(imageWidget, metaLine, chips)
              : _buildBelowMode(imageWidget, metaLine, chips),
        ),
      ),
    );
  }

  String? _metaLine() {
    final parts = <String>[];
    if (year != null) parts.add(year.toString());
    final dur = durationMinutes != null
        ? formatDuration(durationMinutes!)
        : null;
    if (dur != null && dur.isNotEmpty) parts.add(dur);
    return parts.isEmpty ? null : parts.join('  •  ');
  }

  Widget? _chipsRow() {
    if (rating == null && typeLabel == null) return null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (rating != null)
          GlassChip.rating(rating!.toStringAsFixed(1))
        else
          const SizedBox.shrink(),
        if (typeLabel != null)
          GlassChip(label: typeLabel!.toUpperCase())
        else
          const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildInsideMode(Widget imageWidget, String? metaLine, Widget? chips) {
    return Stack(
      children: [
        Positioned.fill(child: imageWidget),
        // Top chips, floating on the artwork.
        if (chips != null)
          Positioned(top: 10, left: 10, right: 10, child: chips),
        // Bottom scrim + title + meta. The scrim is attached to the text
        // block so it is exactly as tall as the text it protects.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(YumeDesign.radiusCard),
                  bottomRight: Radius.circular(YumeDesign.radiusCard),
                ),
                // Neutral black legibility scrim only (see YumeDesign).
                gradient: YumeDesign.legibilityScrim,
              ),
              padding: const EdgeInsets.fromLTRB(12, 28, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      shadows: [
                        Shadow(
                          color: Colors.black87,
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                  if (metaLine != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      metaLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBelowMode(Widget imageWidget, String? metaLine, Widget? chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: imageWidget),
              if (chips != null)
                Positioned(top: 10, left: 10, right: 10, child: chips),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.92),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (metaLine != null) ...[
          const SizedBox(height: 2),
          Text(
            metaLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}
