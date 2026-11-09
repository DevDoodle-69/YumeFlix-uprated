/// Picking a Together title from the host's watch history.
///
/// The data source is the existing Continue Watching history
/// ([HistoryItem] from `history_repository.dart`, read through
/// `watchHistoryProvider`): each entry already carries the poster,
/// title, saved position/duration, season/episode for series, the last
/// episode token, and the provider last used.
///
/// The mapping here is pure so it can be pinned without a player:
///
/// * a history entry becomes the room identity
///   ([TogetherMediaIdentity]) — same title/episode and same provider
///   the host used before, so the guest auto-opens the same title,
///   episode and provider;
/// * the saved position is the resume point, with the same suppressions
///   the player itself applies ([kCompletedFraction]: under 1% or past
///   90% is not worth resuming, and neither is a clip under 30 s);
/// * an entry with no provider still opens — on the best available
///   source — but carries a notice, so the host is told instead of the
///   app silently picking something else;
/// * an entry that cannot be played at all (no title, no URL, or a live
///   stream, which Together cannot share) is a [HistoryPickProblem],
///   never a dead tap.
///
/// The player itself does the resuming: it is opened with the episode
/// from the history entry (series) or the item URL (film), and its
/// normal resume lookup reads the same stored position back — so the
/// host lands where they left off, and Start then publishes that
/// position to every guest. [TogetherService.attachMedia] only resets
/// the room position to 0 on a real title change, never on a re-share
/// of the same title.
library;

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/storage/history_repository.dart';
import 'models.dart';

/// Why a history entry cannot be shared in a Together room at all.
enum HistoryPickProblem {
  /// No usable title — nothing to show or search for.
  emptyTitle,

  /// No usable URL — nothing to resolve or play.
  emptyUrl,

  /// A live stream: Together shares on-demand titles, not live feeds.
  livestream,
}

/// The problem that stops [item] being shared, or null when it can.
///
/// Checked before anything navigates: a stale entry shows a short
/// honest message with a way to search instead, never a dead tap.
HistoryPickProblem? historyPickProblem(HistoryItem item) {
  if (item.item.title.trim().isEmpty) return HistoryPickProblem.emptyTitle;
  if (item.item.url.trim().isEmpty) return HistoryPickProblem.emptyUrl;
  if (item.item.contentType == MultimediaContentType.livestream) {
    return HistoryPickProblem.livestream;
  }
  return null;
}

/// True when [item] can be shared in a Together room.
bool historyItemIsPlayable(HistoryItem item) =>
    historyPickProblem(item) == null;

/// Short honest line for a history entry that cannot be shared.
String historyPickProblemMessage(HistoryPickProblem problem) =>
    switch (problem) {
      HistoryPickProblem.emptyTitle || HistoryPickProblem.emptyUrl =>
        'This title is no longer available — try searching for it instead.',
      HistoryPickProblem.livestream =>
        'Live streams can’t be shared in a Together room.',
    };

/// The saved position worth resuming at, in milliseconds.
///
/// Mirrors the player's own resume suppressions: under 1% or past 90%
/// of the stored duration is not a place to resume (the viewer has
/// finished, or barely started), and neither is a clip under 30 s.
/// Anything else resumes exactly where the host left off.
int historyResumePositionMs(HistoryItem item) {
  if (item.position <= 0 || item.duration <= 0) return 0;
  if (item.duration < 30000) return 0;
  final fraction = item.position / item.duration;
  if (fraction < 0.01 || fraction >= 0.90) return 0;
  return item.position;
}

/// A history entry mapped onto a Together share: the room identity, the
/// episode the player opens with, the resume point, and the
/// provider-fallback notice when one applies.
class HistoryTogetherPick {
  const HistoryTogetherPick({
    required this.identity,
    required this.episode,
    required this.resumePositionMs,
    this.providerFallbackNotice,
  });

  /// The room identity: same title/episode and same provider as the
  /// host's last watch, so the guest auto-opens exactly that.
  final TogetherMediaIdentity identity;

  /// The episode the host's player opens with (series only, and only
  /// when the history entry still carries its episode token). Null for
  /// films and for series entries without a token — those open through
  /// the details flow, which picks the episode by number instead.
  final Episode? episode;

  /// Where the host's player starts, in milliseconds (see
  /// [historyResumePositionMs]).
  final int resumePositionMs;

  /// One-line note when the entry carries no provider: the title still
  /// opens, on the best available source, and the host is told so.
  /// Null when the stored provider is used.
  final String? providerFallbackNotice;
}

/// Maps a playable history entry onto its Together share, or null when
/// [historyPickProblem] stops it.
HistoryTogetherPick? togetherPickForHistory(HistoryItem item) {
  if (historyPickProblem(item) != null) return null;
  final multimedia = item.item;
  final isSeries =
      multimedia.contentType == MultimediaContentType.series ||
      multimedia.contentType == MultimediaContentType.anime;
  final season = item.season ?? 0;
  final episodeNumber = item.episode ?? 0;
  final hasEpisode = isSeries && season > 0 && episodeNumber > 0;
  final title = hasEpisode
      ? '${multimedia.title} · S$season E$episodeNumber'
      : multimedia.title;
  final episodeLabel = hasEpisode ? 'S$season E$episodeNumber' : null;
  String? poster;
  for (final candidate in <String?>[
    item.episodePosterUrl,
    multimedia.posterUrl,
    multimedia.bannerUrl,
  ]) {
    final value = candidate?.trim();
    if (value != null && value.isNotEmpty) {
      poster = value;
      break;
    }
  }
  // The episode token is the series episode's own URL from the last
  // watch. A film has no episode token: its detail URL is the token,
  // and the guest resolves it from there — a saved *stream* URL is
  // never shared, it is one phone's playback URL, not a catalog token.
  final episodeUrl = isSeries ? item.lastEpisodeUrl : null;
  final episode = isSeries && episodeUrl != null && episodeUrl.isNotEmpty
      ? Episode(
          name: item.episodeTitle?.trim().isNotEmpty == true
              ? item.episodeTitle!
              : title,
          url: episodeUrl,
          season: season,
          episode: episodeNumber,
        )
      : null;
  final provider = multimedia.provider?.trim();
  return HistoryTogetherPick(
    identity: TogetherMediaIdentity(
      title: title,
      tmdbType: isSeries ? 'tv' : 'movie',
      tmdbId: multimedia.tmdbId,
      posterUrl: poster,
      episodeLabel: episodeLabel,
      season: hasEpisode ? season : null,
      episode: hasEpisode ? episodeNumber : null,
      provider: provider?.isNotEmpty == true ? provider : null,
      itemUrl: multimedia.url,
      episodeUrl: episodeUrl?.isNotEmpty == true ? episodeUrl : null,
    ),
    episode: episode,
    resumePositionMs: historyResumePositionMs(item),
    providerFallbackNotice: provider?.isNotEmpty == true
        ? null
        : 'No saved provider for this title — using the best available source.',
  );
}
