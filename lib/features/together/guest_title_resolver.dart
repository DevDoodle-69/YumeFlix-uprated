/// Resolving a Together room identity into something the player can open.
///
/// The guest never replays the host's search by hand: it resolves the
/// shared identity ([TogetherMediaIdentity]) through the same catalog the
/// host used, in tiers —
///
/// 1. **Exact token.** The host's episode data URL ([episodeUrl]) plus the
///    provider that produced it: the guest loads streams for that same
///    token, puts the host's source ([source]) first, and opens the player
///    with that ordered list preloaded. Same token + same provider means
///    the same source list, so the host's source is the one that opens.
/// 2. **Detail URL.** No episode token (an old host, or a title the host
///    opened without one): load details from [itemUrl] and pick the
///    episode by season/episode number, then resolve its token as in (1).
/// 3. **Title search.** No usable URL at all (a 2.10.0 host publishes only
///    a title + TMDB id): search the guest's providers for the exact
///    title, preferring a TMDB-id match, then continue as in (2).
///
/// When a tier cannot resolve, the next one is tried; when none can, the
/// resolve throws [GuestTitleResolutionFailure] with the short honest line
/// the guest sees — never a silent stuck screen. A stream list that loads
/// but lacks the host's source is NOT a failure: the guest opens on the
/// best available source and the resolution carries a one-line notice
/// saying so ([GuestTitleResolution.sourceFallbackNotice]).
///
/// The async work is injected as callbacks ([loadDetails], [loadStreams],
/// [searchTitles]) so the pure parts — episode picking, title matching,
/// source ordering — are unit-testable without providers, and the widget
/// that owns the providers wires them in.
library;

import 'dart:async';

import 'package:collection/collection.dart';

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/utils/app_utils.dart';
import 'models.dart';

/// How long the guest gives the title search (tier 3) before giving up
/// and showing the honest fallback. ABSOLUTE, not per-event (2.13.0):
/// the old per-event `Stream.timeout` reset on every progressive batch,
/// so a trickling search could run forever — now the search gets this
/// budget from its first byte, however many batches arrive.
const Duration kGuestTitleSearchTimeout = Duration(seconds: 30);

/// How long the guest gives one detail load (tier 2) before treating it
/// as unavailable and trying the next tier (2.13.0). Tier 2 used to
/// await `loadDetails` with NO timeout at all — a hung provider call
/// left the guest on "Opening…" forever, which is the stall the
/// 2.12.0 live test showed. The JS engine itself caps an invoke at
/// 90 s; 15 s is the guest-facing bound for one tier.
const Duration kGuestDetailsTimeout = Duration(seconds: 15);

/// How long the guest gives one stream list to load before treating it
/// as unavailable and trying the next tier.
const Duration kGuestStreamsTimeout = Duration(seconds: 20);

/// Total budget for ONE resolution attempt (2.13.0): every tier await
/// is cut at this deadline, so a resolution can never hang past it
/// however many callbacks stall. The coordinator retries a failed
/// attempt (see `guest_auto_open.dart`) instead of failing once — the
/// guest's only outcomes are the player opening, or an honest message
/// plus the Enter button.
const Duration kGuestResolveTotalTimeout = Duration(seconds: 90);

/// What step a guest auto-open is on, for the honest progress the
/// guest sees while the title resolves (2.13.0) instead of a dead
/// spinner: finding the title, getting the stream, opening the player.
enum GuestResolveStep { findingTitle, gettingStream, openingPlayer }

/// Progress callback for [resolveGuestTitle]: the step the resolution
/// just reached. Steps only move forward within one attempt.
typedef GuestResolveProgress = void Function(GuestResolveStep step);

/// What the guest opens: the item, the episode, the token the player
/// resolves streams from, and — when the guest pre-resolved them — the
/// ordered stream list for the player to open first.
class GuestTitleResolution {
  const GuestTitleResolution({
    required this.item,
    this.episode,
    required this.videoUrl,
    this.preloadedStreams = const <StreamResult>[],
    this.sourceFallbackNotice,
    this.startPositionMs = 0,
  });

  /// The item to open the player with.
  final MultimediaItem item;

  /// The episode to open, when the title is one. Null for films.
  final Episode? episode;

  /// The token the player hands to `loadStreams` (the host's episode data
  /// URL, or the episode URL resolved from details / search).
  final String videoUrl;

  /// Streams pre-resolved by the guest, host's source first. Empty when
  /// the guest could not pre-resolve: the player then resolves the token
  /// itself, exactly as a manual open does.
  final List<StreamResult> preloadedStreams;

  /// One-line note when the open used a fallback source because the
  /// host's source was not in the resolved list. Null when the open used
  /// the host's exact source (or no source was named).
  final String? sourceFallbackNotice;

  /// Where the guest's player starts, in milliseconds: the host's
  /// CURRENT live position (see [TogetherRoomState.targetPositionMs]),
  /// not the position from when the title first started and never 0
  /// for a late joiner. The coordinator fills this in from the fresh
  /// room state after resolution, so a slow resolve still lands on
  /// where the host is now. 0 when the host is at the start.
  final int startPositionMs;
}

/// The guest could not open the host's title automatically. [message] is
/// the short honest line the Together screen shows next to the manual
/// "Find this title" fallback. [diagnostics] is the tier-by-tier reason
/// (2.13.0) — which tier failed and why — shown in the diagnostics line
/// so the next failure is diagnosable from the phone.
class GuestTitleResolutionFailure implements Exception {
  const GuestTitleResolutionFailure(this.message, {this.diagnostics});

  final String message;

  /// Tier-by-tier failure reasons, or null when none was recorded.
  final String? diagnostics;

  @override
  String toString() => 'GuestTitleResolutionFailure: $message';
}

const String kGuestTitleNotFoundMessage =
    'Couldn’t open this title automatically — tap to find it';

/// The title without its ` · S{n} E{n}` episode suffix, for searching.
String baseTitleOf(TogetherMediaIdentity identity) =>
    identity.title.replaceFirst(RegExp(r' · S\d+ E\d+$'), '').trim();

/// Normalised title for comparison: case and surrounding space ignored,
/// inner runs of space collapsed.
String normalizeTitle(String title) =>
    title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// The item the guest opens the player (or loads details) with, built
/// from the room identity alone. The URL is the host's detail URL when
/// known; an empty URL means "no detail URL — search instead".
MultimediaItem buildItemForIdentity(TogetherMediaIdentity identity) =>
    MultimediaItem(
      title: baseTitleOf(identity),
      url: identity.itemUrl ?? '',
      posterUrl: identity.posterUrl ?? '',
      contentType: identity.tmdbType == 'tv'
          ? MultimediaContentType.series
          : MultimediaContentType.movie,
      tmdbId: identity.tmdbId,
      provider: identity.provider,
    );

/// Picks the episode the room is about out of a detail list, by
/// season/episode number. A series episode with numbers that match nothing
/// returns null — opening the wrong episode silently would be worse than
/// the honest fallback. A film (or a title without numbers) takes the
/// first entry, which is how the details screen plays a film too.
Episode? pickEpisodeForIdentity(
  List<Episode> episodes,
  TogetherMediaIdentity identity,
) {
  if (episodes.isEmpty) return null;
  final season = identity.season;
  final number = identity.episode;
  if (season != null && season > 0 && number != null && number > 0) {
    final exact = episodes.firstWhereOrNull(
      (e) => e.season == season && e.episode == number,
    );
    if (exact != null) return exact;
    return null;
  }
  return episodes.first;
}

/// Picks the host's title out of title-search results: the exact
/// normalised title with a matching media type, preferring a TMDB-id
/// match when the candidate carries one. Anything else is not the host's
/// title — a near match must not open the wrong film.
///
/// 2.13.0 — a trailing release year on the candidate (`"The Garden of
/// Words (2013)"`) still matches: providers commonly carry the year,
/// and the year is not what distinguishes two films — the TMDB id does
/// when both sides know it, and the exact title otherwise.
MultimediaItem? pickSearchMatch(
  List<MultimediaItem> items,
  TogetherMediaIdentity identity,
) {
  final wantTitle = _matchTitle(baseTitleOf(identity));
  if (wantTitle.isEmpty) return null;
  final candidates = items.where((item) {
    if (_matchTitle(item.title) != wantTitle) return false;
    if (identity.tmdbType == 'movie' &&
        item.contentType != MultimediaContentType.movie) {
      return false;
    }
    if (identity.tmdbType == 'tv' &&
        item.contentType != MultimediaContentType.series &&
        item.contentType != MultimediaContentType.anime) {
      return false;
    }
    return true;
  }).toList();
  if (candidates.isEmpty) return null;
  if (identity.tmdbId != null) {
    final byId = candidates.firstWhereOrNull(
      (item) => item.tmdbId == identity.tmdbId,
    );
    if (byId != null) return byId;
  }
  return candidates.first;
}

/// Normalised title for matching: case and surrounding space ignored,
/// inner runs of space collapsed, and a trailing release year
/// (`" (2013)"`) stripped — the year is metadata, not identity.
String _matchTitle(String title) =>
    normalizeTitle(title).replaceFirst(RegExp(r' \(\d{4}\)$'), '');

/// Orders a resolved stream list so the host's source opens first, when
/// it is in the list at all. The rest keep their order as failover.
/// Returns the ordered list and whether the host's source was found.
({List<StreamResult> streams, bool found}) orderStreamsForHostSource(
  List<StreamResult> streams,
  String? hostSource,
) {
  if (hostSource == null || hostSource.trim().isEmpty) {
    return (streams: streams, found: false);
  }
  final want = hostSource.trim().toLowerCase();
  final index = streams.indexWhere(
    (s) => s.source.trim().toLowerCase() == want,
  );
  if (index <= 0) return (streams: streams, found: index == 0);
  final ordered = <StreamResult>[...streams];
  final picked = ordered.removeAt(index);
  ordered.insert(0, picked);
  return (streams: ordered, found: true);
}

/// A token the player opens directly, without a provider's `loadStreams`:
/// a torrent, a remote/local file, or a direct link. The guest must not
/// pre-resolve these — the player's own direct path handles them, and a
/// `loadStreams` call on a magnet would be meaningless.
bool _isDirectToken(MultimediaItem item, String url) =>
    item.provider == 'Torrent' ||
    item.provider == 'Remote' ||
    item.provider == 'Local' ||
    url.startsWith('magnet:') ||
    url.endsWith('.torrent') ||
    AppUtils.isLocalFile(url);

/// Resolves [identity] into a player opening, through the tiers above.
///
/// [loadDetails] loads full details (episodes included) for [baseItem]
/// — the guest's details controller on the item's URL — or null when it
/// cannot. [loadStreams] loads the stream list for one episode token
/// through the item's provider. [searchTitles] yields progressive batches
/// of title-search results for [query] and completes when the search is
/// done. Every callback is allowed to fail: a failure just drops to the
/// next tier, and only a failure of all three throws
/// [GuestTitleResolutionFailure].
///
/// 2.13.0 — fast join + bounded + honest:
/// * Tiers 1 and 2 run IN PARALLEL when both a token and a detail URL
///   are known: the stream pre-resolve and the detail load overlap
///   instead of waiting on each other serially. Tier 1 wins when it
///   resolves; tier 2 is the fallback. Total time is the slower tier,
///   not the sum.
/// * Every tier is bounded: streams 20 s, details 15 s, search 30 s
///   absolute — and the whole attempt is cut at
///   [kGuestResolveTotalTimeout], so a resolution can never hang past
///   it however many callbacks stall. A slow network (300–500 ms
///   round-trips, different countries) is far inside every bound.
/// * [onProgress] reports each step as it is reached, so the guest
///   sees real progress instead of a dead spinner.
/// * The failure carries [GuestTitleResolutionFailure.diagnostics]:
///   which tier failed and why, for the diagnostics line.
Future<GuestTitleResolution> resolveGuestTitle({
  required TogetherMediaIdentity identity,
  required Future<MultimediaItem?> Function(MultimediaItem baseItem)
  loadDetails,
  required Future<List<StreamResult>> Function(
    MultimediaItem item,
    String episodeUrl,
  )
  loadStreams,
  required Stream<List<MultimediaItem>> Function(String query) searchTitles,
  int startPositionMs = 0,
  GuestResolveProgress? onProgress,
}) async {
  final deadline = DateTime.now().add(kGuestResolveTotalTimeout);
  final reasons = <String>[];
  onProgress?.call(GuestResolveStep.findingTitle);

  // Tier 1 — the exact token the host is playing — and tier 2 — the
  // host's detail URL — start together (see above). Tier 2's future is
  // only awaited when tier 1 cannot resolve; abandoning it is safe
  // (its callbacks swallow their own failures, so it never throws
  // unhandled).
  final episodeUrl = identity.episodeUrl;
  final hasToken = episodeUrl != null && episodeUrl.isNotEmpty;
  final hasItemUrl = identity.itemUrl != null && identity.itemUrl!.isNotEmpty;
  Future<GuestTitleResolution?>? tier2Future;
  if (hasItemUrl) {
    tier2Future = _resolveFromItem(
      buildItemForIdentity(identity),
      identity,
      loadDetails,
      loadStreams,
      startPositionMs: startPositionMs,
      reasons: reasons,
    );
  }
  if (hasToken) {
    onProgress?.call(GuestResolveStep.gettingStream);
    final item = buildItemForIdentity(identity);
    final episode = Episode(
      name: identity.title,
      url: episodeUrl,
      season: identity.season ?? 0,
      episode: identity.episode ?? 0,
    );
    final resolved = await _withDeadline(
      _resolveStreams(
        item,
        episode,
        episodeUrl,
        loadStreams,
        identity.source,
        startPositionMs: startPositionMs,
        reasons: reasons,
      ),
      deadline,
    );
    if (resolved != null) {
      onProgress?.call(GuestResolveStep.openingPlayer);
      return resolved;
    }
    if (tier2Future != null) {
      final fromDetails = await _withDeadline(tier2Future, deadline);
      if (fromDetails != null) {
        onProgress?.call(GuestResolveStep.openingPlayer);
        return fromDetails;
      }
    }
  } else if (tier2Future != null) {
    final fromDetails = await _withDeadline(tier2Future, deadline);
    if (fromDetails != null) {
      onProgress?.call(GuestResolveStep.openingPlayer);
      return fromDetails;
    }
  }

  // Tier 3 — title search, exact title (TMDB id preferred).
  onProgress?.call(GuestResolveStep.findingTitle);
  final match = await _searchForTitle(identity, searchTitles, deadline);
  if (match != null) {
    onProgress?.call(GuestResolveStep.gettingStream);
    final resolved = await _withDeadline(
      _resolveFromItem(
        match,
        identity,
        loadDetails,
        loadStreams,
        startPositionMs: startPositionMs,
        reasons: reasons,
      ),
      deadline,
    );
    if (resolved != null) {
      onProgress?.call(GuestResolveStep.openingPlayer);
      return resolved;
    }
  } else {
    reasons.add(
      'title search found no exact match for “${baseTitleOf(identity)}”',
    );
  }

  throw GuestTitleResolutionFailure(
    kGuestTitleNotFoundMessage,
    diagnostics: reasons.isEmpty ? null : reasons.join(' · '),
  );
}

/// Awaits [future], cut at [deadline]: null when the deadline passes
/// first. The underlying work is left running (its callbacks are
/// self-bounding), but the caller never waits past the total budget.
Future<T?> _withDeadline<T>(Future<T?> future, DateTime deadline) async {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) return null;
  try {
    return await future.timeout(remaining);
  } on TimeoutException {
    return null;
  }
}

/// Resolves one item (detail URL known) into a player opening: load its
/// details, pick the episode, resolve its streams. Null when any step
/// cannot — the caller then tries the next tier. [reasons] collects
/// why, for the failure diagnostics.
Future<GuestTitleResolution?> _resolveFromItem(
  MultimediaItem item,
  TogetherMediaIdentity identity,
  Future<MultimediaItem?> Function(MultimediaItem baseItem) loadDetails,
  Future<List<StreamResult>> Function(MultimediaItem item, String episodeUrl)
  loadStreams, {
  int startPositionMs = 0,
  List<String>? reasons,
}) async {
  MultimediaItem? detailed;
  try {
    detailed = await loadDetails(
      item,
    ).timeout(kGuestDetailsTimeout);
  } on TimeoutException {
    reasons?.add(
      'details load timed out after ${kGuestDetailsTimeout.inSeconds}s',
    );
    return null;
  } catch (_) {
    reasons?.add('details load failed');
    return null;
  }
  if (detailed == null && (item.episodes ?? const <Episode>[]).isEmpty) {
    reasons?.add('details unavailable for “${baseTitleOf(identity)}”');
    return null;
  }
  final episodes =
      detailed?.episodes ?? item.episodes ?? const <Episode>[];
  final episode = pickEpisodeForIdentity(episodes, identity);
  if (episode == null || episode.url.isEmpty) {
    reasons?.add('details had no episode for this title');
    return null;
  }
  return _resolveStreams(
    detailed ?? item,
    episode,
    episode.url,
    loadStreams,
    identity.source,
    startPositionMs: startPositionMs,
    reasons: reasons,
  );
}

/// Searches for the host's title and returns the exact match, or null.
/// Consumes the progressive batches until a match appears, the search
/// completes, or the ABSOLUTE search budget ([kGuestTitleSearchTimeout],
/// capped by [deadline]) runs out — whichever comes first. A batch
/// arriving late does not extend the budget.
Future<MultimediaItem?> _searchForTitle(
  TogetherMediaIdentity identity,
  Stream<List<MultimediaItem>> Function(String query) searchTitles,
  DateTime deadline,
) async {
  final query = baseTitleOf(identity);
  if (query.isEmpty) return null;
  final collected = <MultimediaItem>[];
  final searchEnd = DateTime.now().add(kGuestTitleSearchTimeout);
  final end = searchEnd.isBefore(deadline) ? searchEnd : deadline;
  final remaining = end.difference(DateTime.now());
  if (remaining <= Duration.zero) return pickSearchMatch(collected, identity);
  final completer = Completer<MultimediaItem?>();
  late StreamSubscription<List<MultimediaItem>> sub;
  Timer? timer;
  void finish(MultimediaItem? match) {
    if (completer.isCompleted) return;
    timer?.cancel();
    unawaited(sub.cancel());
    completer.complete(match);
  }

  try {
    timer = Timer(remaining, () {
      finish(pickSearchMatch(collected, identity));
    });
    sub = searchTitles(query).listen(
      (batch) {
        collected.addAll(batch);
        final match = pickSearchMatch(collected, identity);
        if (match != null) finish(match);
      },
      onError: (_) => finish(pickSearchMatch(collected, identity)),
      onDone: () => finish(pickSearchMatch(collected, identity)),
      cancelOnError: false,
    );
  } catch (_) {
    timer?.cancel();
    return pickSearchMatch(collected, identity);
  }
  return completer.future;
}

/// Resolves one episode token into a player opening: pre-loads its stream
/// list, host's source first. Null when the list cannot load at all — the
/// caller then tries the next tier. A direct token (torrent / local /
/// direct link) opens without pre-resolving: the player's own direct path
/// handles it. A list that loads but lacks the host's source still opens,
/// on the best available source, carrying the one-line notice.
Future<GuestTitleResolution?> _resolveStreams(
  MultimediaItem item,
  Episode episode,
  String episodeUrl,
  Future<List<StreamResult>> Function(MultimediaItem item, String episodeUrl)
  loadStreams,
  String? hostSource, {
  int startPositionMs = 0,
  List<String>? reasons,
}) async {
  if (_isDirectToken(item, episodeUrl)) {
    return GuestTitleResolution(
      item: item,
      episode: episode,
      videoUrl: episodeUrl,
      startPositionMs: startPositionMs,
    );
  }
  List<StreamResult> streams;
  try {
    streams = await loadStreams(item, episodeUrl).timeout(kGuestStreamsTimeout);
  } on TimeoutException {
    reasons?.add(
      'stream list timed out after ${kGuestStreamsTimeout.inSeconds}s',
    );
    return null;
  } catch (_) {
    reasons?.add('stream list failed to load');
    return null;
  }
  if (streams.isEmpty) {
    reasons?.add('stream list was empty for the host’s token');
    return null;
  }
  final ordered = orderStreamsForHostSource(streams, hostSource);
  final notice =
      hostSource != null &&
          hostSource.trim().isNotEmpty &&
          !ordered.found
      ? 'The host’s source “$hostSource” wasn’t available — playing the best available source instead.'
      : null;
  return GuestTitleResolution(
    item: item,
    episode: episode,
    videoUrl: episodeUrl,
    preloadedStreams: ordered.streams,
    sourceFallbackNotice: notice,
    startPositionMs: startPositionMs,
  );
}
