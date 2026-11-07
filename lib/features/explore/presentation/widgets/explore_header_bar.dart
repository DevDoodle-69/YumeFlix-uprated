import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yumeflix/core/theme/design_tokens.dart';
import 'package:yumeflix/core/utils/layout_constants.dart';
import 'package:yumeflix/l10n/generated/app_localizations.dart';
import 'package:yumeflix/shared/widgets/cards_wrapper.dart';
import 'package:yumeflix/shared/widgets/glass_card.dart';
import 'package:yumeflix/features/explore/presentation/delegates/explore_search_delegate.dart';
import 'package:yumeflix/features/explore/presentation/widgets/unified_filter_dialog.dart';
import 'package:yumeflix/features/explore/data/explore_filter_provider.dart';
import 'package:yumeflix/features/explore/data/explore_mode_provider.dart';
import 'package:yumeflix/features/explore/presentation/widgets/hover_border_gradient.dart';
import 'package:yumeflix/features/explore/presentation/widgets/explore_mode_selector_dialog.dart';

import 'dart:async';

import '../../../../core/router/app_router.dart';

/// A custom header bar for the explore screen in widescreen/desktop layout.
///
/// 2.6.0: glass icon buttons, a glass search capsule and the gradient-border
/// mode chip — one header language shared with [DashboardHeaderBar].
/// Contains: carousel prev/next arrows, capsule search, filter chip.
class ExploreHeaderBar extends ConsumerWidget {
  final FocusNode searchFocusNode;

  /// Called when the user taps the left arrow (carousel previous).
  final VoidCallback? onPrevious;

  /// Called when the user taps the right arrow (carousel next).
  final VoidCallback? onNext;

  const ExploreHeaderBar({
    super.key,
    required this.searchFocusNode,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    final hasCarousel = onPrevious != null && onNext != null;

    return Container(
      height: LayoutConstants.dashboardHeaderHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.dashboardContentPadding,
      ),
      child: Row(
        children: [
          // Carousel prev / next arrows — glass icon buttons.
          GlassIconButton(
            icon: Icons.arrow_back_ios_new,
            tooltip: 'Previous',
            enabled: hasCarousel,
            onTap: onPrevious,
          ),
          const SizedBox(width: 6),
          GlassIconButton(
            icon: Icons.arrow_forward_ios,
            tooltip: 'Next',
            enabled: hasCarousel,
            onTap: onNext,
          ),

          const SizedBox(width: 16),

          CardsWrapper(
            scaleFactor: 1.01,
            onTap: () => showExploreModeSelectorDialog(context, ref),
            borderRadius: YumeDesign.pillRadius,
            child: HoverBorderGradient(
              onTap: () => showExploreModeSelectorDialog(context, ref),
              child: Consumer(
                builder: (context, ref, _) {
                  final mode = ref.watch(exploreModeProvider);
                  final isDark =
                      Theme.of(context).brightness == Brightness.dark;
                  final textColor = isDark ? Colors.white : Colors.black;

                  Widget iconWidget;
                  String labelText;

                  switch (mode) {
                    case ExploreModeType.movies:
                      iconWidget = Icon(
                        Icons.movie_outlined,
                        size: 14,
                        color: textColor,
                      );
                      labelText = l10n.exploreMovies;
                      break;
                    case ExploreModeType.anime:
                      iconWidget = SizedBox(
                        width: 14,
                        height: 14,
                        child: CustomPaint(
                          painter: AnimeLogoPainter(color: textColor),
                        ),
                      );
                      labelText = l10n.exploreAnime;
                      break;
                    case ExploreModeType.stremio:
                      iconWidget = Icon(
                        Icons.extension_outlined,
                        size: 14,
                        color: textColor,
                      );
                      labelText = 'Stremio Add-ons';
                      break;
                  }

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      iconWidget,
                      const SizedBox(width: 8),
                      Text(
                        labelText,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          const SizedBox(width: 16),

          // Capsule search bar — glass.
          Expanded(
            child: CardsWrapper(
              scaleFactor: 1.01,
              focusNode: searchFocusNode,
              onTap: () {
                unawaited(
                  showSearch<void>(
                    context: context,
                    delegate: ExploreSearchDelegate(),
                    useRootNavigator: false,
                    maintainState: true,
                  ),
                );
              },
              borderRadius: YumeDesign.pillRadius,
              child: Container(
                height: 38,
                constraints: const BoxConstraints(maxWidth: 500),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: YumeDesign.pillRadius,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${l10n.search}...',
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(width: 16),
          // Filter / Stremio Add-on Settings chip — glass icon button,
          // highlighted while a filter is active.
          Consumer(
            builder: (context, ref, _) {
              final mode = ref.watch(exploreModeProvider);
              final isStremio = mode == ExploreModeType.stremio;
              final filters = ref.watch(exploreFilterProvider);
              final hasActiveFilter =
                  filters.selectedGenre != null ||
                  filters.selectedYear != null ||
                  filters.minRating != null;

              return GlassIconButton(
                icon: isStremio
                    ? Icons.dashboard_customize_rounded
                    : Icons.tune,
                tooltip: isStremio ? 'Stremio Settings' : 'Filter',
                highlighted: !isStremio && hasActiveFilter,
                onTap: () {
                  if (isStremio) {
                    const AddonsRoute().go(context);
                  } else {
                    unawaited(
                      showDialog<void>(
                        context: context,
                        builder: (context) => const UnifiedFilterDialog(),
                      ),
                    );
                  }
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
