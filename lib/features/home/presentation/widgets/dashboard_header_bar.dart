import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yumeflix/core/theme/design_tokens.dart';
import 'package:yumeflix/core/utils/layout_constants.dart';
import 'package:yumeflix/core/extensions/extension_manager.dart';
import 'package:yumeflix/l10n/generated/app_localizations.dart';
import 'package:yumeflix/shared/widgets/cards_wrapper.dart';
import 'package:yumeflix/shared/widgets/glass_card.dart';
import 'package:yumeflix/features/home/presentation/delegates/home_search_delegate.dart';
import 'package:yumeflix/features/home/presentation/home_provider.dart';
import 'package:yumeflix/features/explore/presentation/widgets/hover_border_gradient.dart';

import 'dart:async';

/// A custom header bar for the widescreen dashboard layout.
///
/// 2.6.0: glass icon buttons, a glass search capsule and the gradient-border
/// provider chip — one header language shared with [ExploreHeaderBar].
/// Contains: carousel prev/next arrows, capsule search, provider chip.
class DashboardHeaderBar extends ConsumerWidget {
  final FocusNode searchFocusNode;
  final VoidCallback onShowProviderSelector;

  /// Called when the user taps the left arrow (carousel previous).
  final VoidCallback? onPrevious;

  /// Called when the user taps the right arrow (carousel next).
  final VoidCallback? onNext;

  const DashboardHeaderBar({
    super.key,
    required this.searchFocusNode,
    required this.onShowProviderSelector,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final activeProvider = ref.watch(activeProviderProvider);

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

          // Capsule search bar — glass.
          Expanded(
            child: CardsWrapper(
              scaleFactor: 1.01,
              focusNode: searchFocusNode,
              onTap: () {
                unawaited(
                  showSearch<void>(
                    context: context,
                    delegate: HomeSearchDelegate(),
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

          // Refresh button — glass icon button.
          GlassIconButton(
            icon: Icons.refresh,
            tooltip: l10n.retry,
            onTap: () => ref.read(homeDataProvider.notifier).fetch(),
          ),

          const SizedBox(width: 12),

          Tooltip(
            message: l10n.selectProvider,
            child: Semantics(
              button: true,
              label:
                  '${l10n.selectProvider}: ${activeProvider?.name ?? l10n.none}',
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                child: HoverBorderGradient(
                  onTap: onShowProviderSelector,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.extension,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        activeProvider?.name ?? l10n.none,
                        style: TextStyle(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
