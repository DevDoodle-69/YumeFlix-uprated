/// "From your history" for Together: the host picks a title they have
/// already watched, and it opens in the player at the saved position
/// with the same provider — then Start shares it with every guest.
///
/// Two entry points share this file: the section itself (shown at the
/// top of the search screen while a host room is active, and in a sheet
/// from the Together screen) and [openHistoryItemForTogether] (also
/// called from a Continue Watching card's long-press sheet on Home).
/// Both go through the same open: validate the entry, make sure a host
/// room exists (creating one when there is none), then open the player
/// with the episode from the history entry — never the details screen's
/// first episode — so a series resumes the correct episode.
///
/// Minimal professional styling: small poster rows, grey secondary
/// text, one muted accent — no neon, no glow, no gradients except the
/// neutral legibility already on the cards.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart';
import '../../details/presentation/playback_launcher.dart';
import '../../library/presentation/history_provider.dart';
import '../history_pick.dart';
import '../together_provider.dart';
import '../together_service.dart';

/// What opening a history item for Together ended in.
enum HistoryTogetherOpenResult {
  /// The player opened (or is opening) on the history title.
  opened,

  /// The entry is stale — shown with a short message, nothing opened.
  stale,

  /// A live stream — Together shares on-demand titles only.
  livestream,

  /// This phone is a guest in a room: only the host picks the title.
  notHost,

  /// A room could not be created.
  roomFailed,
}

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Opens [item] in the player for Together, as the host.
///
/// Validates first (stale entries get a short message, never a dead
/// tap), creates a room when there is none, refuses when this phone is
/// a guest, and opens the player with the history episode so a series
/// resumes the correct episode at the saved position. A missing
/// provider is not silent: the host is told the best available source
/// is used instead.
Future<HistoryTogetherOpenResult> openHistoryItemForTogether({
  required BuildContext context,
  required WidgetRef ref,
  required HistoryItem item,
}) async {
  final problem = historyPickProblem(item);
  if (problem != null) {
    if (context.mounted) {
      _showMessage(context, historyPickProblemMessage(problem));
    }
    return problem == HistoryPickProblem.livestream
        ? HistoryTogetherOpenResult.livestream
        : HistoryTogetherOpenResult.stale;
  }
  final service = ref.read(togetherServiceProvider);
  if (!service.isSessionActive) {
    final created = await service.createRoom();
    if (!created) {
      if (context.mounted) {
        _showMessage(
          context,
          service.error ?? 'Couldn’t create the room — try again.',
        );
      }
      return HistoryTogetherOpenResult.roomFailed;
    }
  }
  if (service.role != TogetherRole.host) {
    if (context.mounted) {
      _showMessage(context, 'Only the host picks the title for the room.');
    }
    return HistoryTogetherOpenResult.notHost;
  }
  final pick = togetherPickForHistory(item);
  if (pick == null) {
    if (context.mounted) {
      _showMessage(
        context,
        'This title is no longer available — try searching for it instead.',
      );
    }
    return HistoryTogetherOpenResult.stale;
  }
  if (pick.providerFallbackNotice != null && context.mounted) {
    _showMessage(context, pick.providerFallbackNotice!);
  }
  if (!context.mounted) return HistoryTogetherOpenResult.opened;
  // The episode from the history entry, not the details screen's first
  // episode: a series resumes the exact episode the host was watching.
  // Without an episode token (an old entry) the details flow picks the
  // episode by the season/episode numbers the identity carries.
  if (pick.episode != null) {
    unawaited(
      ref
          .read(playbackLauncherProvider)
          .play(
            context,
            pick.episode!.url,
            baseItem: item.item,
            episode: pick.episode,
          ),
    );
  } else if (pick.identity.tmdbType == 'movie') {
    // A film opens straight on its own URL.
    unawaited(
      ref
          .read(playbackLauncherProvider)
          .play(context, item.item.url, baseItem: item.item),
    );
  } else {
    // A series without an episode token goes through details, which
    // resolves the saved episode by number.
    unawaited(
      DetailsRoute($extra: DetailsRouteExtra(item: item.item, autoPlay: true))
          .push<void>(context),
    );
  }
  return HistoryTogetherOpenResult.opened;
}

/// "From your history": the host's Continue Watching entries as
/// Together picks.
///
/// Renders nothing unless this phone is the host of an active room —
/// a guest never picks the title, and outside a room there is nothing
/// to attach to — so it is safe to embed on the search screen and in
/// the Together sheet alike.
class TogetherHistorySection extends ConsumerWidget {
  const TogetherHistorySection({super.key, this.maxItems = 8});

  final int maxItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = ref.watch(togetherServiceProvider);
    if (!service.isSessionActive || service.role != TogetherRole.host) {
      return const SizedBox.shrink();
    }
    final history = ref.watch(watchHistoryProvider);
    final playable = history
        .where(historyItemIsPlayable)
        .take(maxItems)
        .toList();
    if (playable.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'From your history',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Resume where you left off — guests join at your position.',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        for (final entry in playable) _HistoryPickRow(entry: entry),
      ],
    );
  }
}

class _HistoryPickRow extends ConsumerWidget {
  const _HistoryPickRow({required this.entry});

  final HistoryItem entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final pick = togetherPickForHistory(entry);
    final progress = entry.duration > 0
        ? (entry.position / entry.duration).clamp(0.0, 1.0)
        : 0.0;
    final subtitleParts = <String>[];
    if (pick?.identity.episodeLabel != null) {
      subtitleParts.add(pick!.identity.episodeLabel!);
    }
    if (progress > 0) {
      subtitleParts.add('${(progress * 100).round()}% watched');
    }
    return InkWell(
      onTap: () => unawaited(
        openHistoryItemForTogether(context: context, ref: ref, item: entry),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: entry.item.posterUrl.isNotEmpty
                  ? Image.network(
                      entry.item.posterUrl,
                      width: 40,
                      height: 60,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) => Container(
                        width: 40,
                        height: 60,
                        color: colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.movie_rounded, size: 20),
                      ),
                    )
                  : Container(
                      width: 40,
                      height: 60,
                      color: colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.movie_rounded, size: 20),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (subtitleParts.isNotEmpty)
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      backgroundColor: colorScheme.onSurface.withValues(
                        alpha: 0.15,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.play_arrow_rounded, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
