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
/// and showing the honest fallback. The search is progressive — a match
/// ends it early — so this only bounds the no-match case.
const Duration kGuestTitleSearchTimeout = Duration(seconds: 15);

/// How long the guest gives one stream list to load before treating it
/// as unavailable and trying the next tier.
const Duration kGuestStreamsTimeout = Duration(seconds: 20);

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
}

/// The guest could not open the host's title automatically. [message] is
/// the short honest line the Together screen shows next to the manual
/// "Find this title" fallback.
class GuestTitleResolutionFailure implements Exception {
  const GuestTitleResolutionFailure(this.message);

  final String message;

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
MultimediaItem? pickSearchMatch(
  List<MultimediaItem> items,
  TogetherMediaIdentity identity,
) {
  final wantTitle = normalizeTitle(baseTitleOf(identity));
  if (wantTitle.isEmpty) return null;
  final candidates = items.where((item) {
    if (normalizeTitle(item.title) != wantTitle) return false;
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
}) async {
  // Tier 1 — the exact token the host is playing.
  final episodeUrl = identity.episodeUrl;
  if (episodeUrl != null && episodeUrl.isNotEmpty) {
    final item = buildItemForIdentity(identity);
    final episode = Episode(
      name: identity.title,
      url: episodeUrl,
      season: identity.season ?? 0,
      episode: identity.episode ?? 0,
    );
    final resolved = await _resolveStreams(
      item,
      episode,
      episodeUrl,
      loadStreams,
      identity.source,
    );
    if (resolved != null) return resolved;
  }

  // Tier 2 — the host's detail URL: load it, pick the episode by number.
  if (identity.itemUrl != null && identity.itemUrl!.isNotEmpty) {
    final resolved = await _resolveFromItem(
      buildItemForIdentity(identity),
      identity,
      loadDetails,
      loadStreams,
    );
    if (resolved != null) return resolved;
  }

  // Tier 3 — title search, exact title (TMDB id preferred).
  final match = await _searchForTitle(identity, searchTitles);
  if (match != null) {
    final resolved = await _resolveFromItem(
      match,
      identity,
      loadDetails,
      loadStreams,
    );
    if (resolved != null) return resolved;
  }

  throw const GuestTitleResolutionFailure(kGuestTitleNotFoundMessage);
}

/// Resolves one item (detail URL known) into a player opening: load its
/// details, pick the episode, resolve its streams. Null when any step
/// cannot — the caller then tries the next tier.
Future<GuestTitleResolution?> _resolveFromItem(
  MultimediaItem item,
  TogetherMediaIdentity identity,
  Future<MultimediaItem?> Function(MultimediaItem baseItem) loadDetails,
  Future<List<StreamResult>> Function(MultimediaItem item, String episodeUrl)
  loadStreams,
) async {
  MultimediaItem? detailed;
  try {
    detailed = await loadDetails(item);
  } catch (_) {
    return null;
  }
  final episodes =
      detailed?.episodes ?? item.episodes ?? const <Episode>[];
  final episode = pickEpisodeForIdentity(episodes, identity);
  if (episode == null || episode.url.isEmpty) return null;
  return _resolveStreams(
    detailed ?? item,
    episode,
    episode.url,
    loadStreams,
    identity.source,
  );
}

/// Searches for the host's title and returns the exact match, or null.
/// Consumes the progressive batches until a match appears, the search
/// completes, or the search times out.
Future<MultimediaItem?> _searchForTitle(
  TogetherMediaIdentity identity,
  Stream<List<MultimediaItem>> Function(String query) searchTitles,
) async {
  final query = baseTitleOf(identity);
  if (query.isEmpty) return null;
  final collected = <MultimediaItem>[];
  try {
    await for (final batch in searchTitles(
      query,
    ).timeout(kGuestTitleSearchTimeout)) {
      collected.addAll(batch);
      final match = pickSearchMatch(collected, identity);
      if (match != null) return match;
    }
  } on TimeoutException {
    // No match in the time allowed: the caller falls through to the
    // honest failure instead of waiting on a search that may never land.
    return pickSearchMatch(collected, identity);
  }
  return pickSearchMatch(collected, identity);
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
  String? hostSource,
) async {
  if (_isDirectToken(item, episodeUrl)) {
    return GuestTitleResolution(
      item: item,
      episode: episode,
      videoUrl: episodeUrl,
    );
  }
  List<StreamResult> streams;
  try {
    streams = await loadStreams(
      item,
      episodeUrl,
    ).timeout(kGuestStreamsTimeout);
  } catch (_) {
    return null;
  }
  if (streams.isEmpty) return null;
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
  );
}
