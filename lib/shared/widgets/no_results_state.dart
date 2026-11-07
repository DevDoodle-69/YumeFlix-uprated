import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';

/// A compact, localized empty state shared by the app's search surfaces.
///
/// The artwork is bundled locally, so this state stays available offline and
/// cannot fail because of a remote image request. Its rendered size is bounded
/// by the available viewport to avoid overflows on short phone screens.
class NoResultsState extends StatelessWidget {
  const NoResultsState({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final screenSize = MediaQuery.sizeOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : screenSize.width;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : screenSize.height;
        final imageHeight = math.min(300.0, availableHeight * 0.4);
        final imageWidth = math.min(
          220.0,
          math.min(availableWidth * 0.65, imageHeight * 0.74),
        );
        final gap = math.min(12.0, availableHeight * 0.05);

        return Center(
          child: SizedBox(
            width: availableWidth * 0.9,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.noResultsFound,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: gap),
                Image.asset(
                  'assets/images/no_results.png',
                  width: imageWidth,
                  height: imageHeight,
                  fit: BoxFit.contain,
                  cacheWidth: 512,
                  excludeFromSemantics: true,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.search_off_rounded,
                    size: math.min(72.0, imageWidth * 0.42),
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
