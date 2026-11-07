import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/core/utils/image_fallbacks.dart';
import 'package:yumeflix/shared/widgets/cards_wrapper.dart';
import 'package:yumeflix/shared/widgets/glass_card.dart';
import 'package:yumeflix/shared/widgets/multimedia_card.dart';
import 'package:yumeflix/shared/widgets/section_header.dart';
import 'package:yumeflix/core/theme/design_tokens.dart';
import 'package:yumeflix/shared/widgets/shimmer_placeholder.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:yumeflix/core/utils/responsive_breakpoints.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'details_layout_widgets.dart';

class MetadataBar extends ConsumerWidget {
  final MultimediaItem item;
  final bool isLoading;
  const MetadataBar({super.key, required this.item, this.isLoading = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // theme and context used in helper methods
    final contentType = item.contentType;
    final showTypeBadge =
        !isLoading || (contentType != MultimediaContentType.movie);

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (item.provider != null && item.provider!.isNotEmpty)
          DetailsProviderChip(providerName: item.provider!),
        if (showTypeBadge)
          _buildBorderedInfo(
            context,
            contentType.name.toUpperCase(),
            color: Theme.of(context).colorScheme.primary,
            isFilled: true,
          )
        else
          ShimmerPlaceholder.rectangular(
            width: 60,
            height: 20,
            borderRadius: 4,
          ),

        if (item.year != null)
          _buildIconInfo(
            context,
            Icons.calendar_today_rounded,
            item.year.toString(),
          )
        else if (isLoading)
          ShimmerPlaceholder.rectangular(
            width: 60,
            height: 20,
            borderRadius: 4,
          ),

        if (item.contentRating != null)
          _buildBorderedInfo(context, item.contentRating!)
        else if (isLoading)
          ShimmerPlaceholder.rectangular(
            width: 60,
            height: 20,
            borderRadius: 4,
          ),

        if (item.duration != null)
          _buildIconInfo(context, Icons.timer_outlined, "${item.duration}m")
        else if (isLoading)
          ShimmerPlaceholder.rectangular(
            width: 60,
            height: 20,
            borderRadius: 4,
          ),

        if (item.score != null)
          _buildIconInfo(
            context,
            Icons.star_rounded,
            item.score!.toStringAsFixed(1),
            iconColor: const Color(0xFF01B4E4),
          )
        else if (isLoading)
          ShimmerPlaceholder.rectangular(
            width: 60,
            height: 20,
            borderRadius: 4,
          ),

        if (item.playbackPolicy != null && item.playbackPolicy != "none")
          _buildPlaybackBadge(context, item.playbackPolicy!),
        if (item.isAdult)
          _buildBorderedInfo(context, "18+", color: Colors.redAccent),
      ],
    );
  }

  Widget _buildBorderedInfo(
    BuildContext context,
    String text, {
    Color? color,
    bool isFilled = false,
  }) {
    // 2.6.0: one chip language.
    if (isFilled) {
      return GlassChip.accent(text, accent: color ?? YumeDesign.violet);
    }
    return GlassChip(label: text);
  }

  Widget _buildIconInfo(
    BuildContext context,
    IconData icon,
    String text, {
    Color? iconColor,
  }) {
    // 2.6.0: one chip language. The star is a gold rating chip.
    if (icon == Icons.star_rounded) {
      return GlassChip.rating(text);
    }
    return GlassChip(label: text, icon: icon);
  }

  Widget _buildPlaybackBadge(BuildContext context, String policy) {
    // 2.6.0: one chip language.
    return GlassChip(
      label: policy,
      icon: Icons.play_circle_outline_rounded,
      accent: Theme.of(context).colorScheme.secondary,
      filled: true,
    );
  }
}

class NextAiringWidget extends StatefulWidget {
  final NextAiring nextAiring;

  const NextAiringWidget({super.key, required this.nextAiring});

  @override
  State<NextAiringWidget> createState() => _NextAiringWidgetState();
}

class _NextAiringWidgetState extends State<NextAiringWidget> {
  Timer? _timer;
  late Duration _remaining;

  DateTime get _airingDate => DateTime.fromMillisecondsSinceEpoch(
    widget.nextAiring.unixTime * 1000,
    isUtc: true,
  );

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  @override
  void didUpdateWidget(covariant NextAiringWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.nextAiring.unixTime != widget.nextAiring.unixTime) {
      _startCountdown();
    }
  }

  Duration _calculateRemaining() {
    final difference = _airingDate.difference(DateTime.now().toUtc());

    if (difference.isNegative) {
      return Duration.zero;
    }

    return difference;
  }

  void _startCountdown() {
    _timer?.cancel();
    _remaining = _calculateRemaining();

    if (_remaining == Duration.zero) {
      return;
    }

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = _calculateRemaining();

      if (!mounted) {
        return;
      }

      setState(() {
        _remaining = remaining;
      });

      if (remaining == Duration.zero) {
        _timer?.cancel();
      }
    });
  }

  String _formatCountdown(Duration duration) {
    final days = duration.inDays;
    final hours = duration.inHours.remainder(24).toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    if (days > 0) {
      return '$days days  $hours:$minutes:$seconds';
    }

    return '$hours:$minutes:$seconds';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final season = widget.nextAiring.season;
    final episodeDescription = season == null
        ? 'Episode ${widget.nextAiring.episode}'
        : 'Episode ${widget.nextAiring.episode} of Season $season';

    final countdownText = _remaining == Duration.zero
        ? 'Airing now'
        : _formatCountdown(_remaining);

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.timer_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$episodeDescription in',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            countdownText,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class CastCarousel extends StatelessWidget {
  final List<Actor> cast;
  const CastCarousel({super.key, required this.cast});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: SectionHeader(title: 'Cast'),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final actor = cast[index];
              return SizedBox(
                width: 80,
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 35,
                      backgroundImage: actor.image != null
                          ? CachedNetworkImageProvider(actor.image!)
                          : null,
                      child: actor.image == null
                          ? const Icon(Icons.person)
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      actor.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    if (actor.role != null)
                      Text(
                        actor.role!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: Theme.of(context).hintColor),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TrailersSection extends StatelessWidget {
  final List<Trailer> trailers;
  const TrailersSection({super.key, required this.trailers});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: SectionHeader(title: 'Trailers & Extras'),
        ),
        SizedBox(
          height: 160,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: trailers.length,
            separatorBuilder: (_, _) => const SizedBox(width: 16),
            itemBuilder: (context, index) {
              final trailer = trailers[index];
              return CardsWrapper(
                onTap: () async {
                  final uri = Uri.tryParse(trailer.url);
                  if (uri != null) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  width: 240,
                  decoration: BoxDecoration(
                    borderRadius: YumeDesign.cardRadius,
                    color: Theme.of(context).colorScheme.surfaceContainer,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl:
                            "https://img.youtube.com/vi/${_extractYoutubeId(trailer.url)}/mqdefault.jpg",
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const Center(child: Icon(Icons.movie_rounded)),
                      ),
                      Container(
                        color: Colors.black26,
                        child: const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            color: Colors.white,
                            size: 48,
                          ),
                        ),
                      ),
                      const Positioned(
                        bottom: 8,
                        left: 8,
                        child: GlassChip(label: 'Trailer'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _extractYoutubeId(String url) {
    // Simple extraction for common patterns
    if (url.contains("v=")) return url.split("v=")[1].split("&")[0];
    if (url.contains("be/")) return url.split("be/")[1].split("?")[0];
    return "";
  }
}

class RecommendationsCarousel extends StatelessWidget {
  final List<MultimediaItem> items;
  final void Function(MultimediaItem) onItemTap;

  const RecommendationsCarousel({
    super.key,
    required this.items,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    // A size branch: the 900 dp desktop breakpoint, which a 960 dp
    // television clears on its own.
    final isLarge = context.isDesktop;
    final cardWidth = isLarge ? 180.0 : 110.0;
    final listHeight = isLarge ? 310.0 : 180.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8.0),
          child: SectionHeader(title: 'More Like This'),
        ),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              // 2.6.0: one card language — the hand-rolled poster + label
              // column is gone; the cinematic card carries title + meta.
              return MultimediaCard(
                imageUrl:
                    AppImageFallbacks.poster(item.posterUrl, label: item.title) ??
                    '',
                title: item.title,
                heroTag: 'rec_${item.url}_$index',
                width: cardWidth,
                rating: item.score,
                year: item.year,
                onTap: () => onItemTap(item),
              );
            },
          ),
        ),
      ],
    );
  }
}
