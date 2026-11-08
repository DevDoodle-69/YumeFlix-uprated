/// Guest auto-open: the guest's phone opens the host's title by itself.
///
/// Mounted once, above the router next to the floating orb (see
/// `main.dart`), and rendering nothing. It watches the Together service
/// and, the moment a live title exists for a guest, resolves it and pushes
/// the player — no tap, from wherever the guest is (Together tab, home,
/// details), including on join-if-already-live and when the host changes
/// title or source mid-session.
///
/// ZERO-LATENCY TRIGGER (2.11.0). The trigger is the service notification
/// itself, and nothing else: the host's go-live state arriving flips the
/// phase synchronously in `TogetherService._handleState`, and the
/// `ref.listen` below fires in the same notification round — the go-live
/// event IS the navigation trigger. There is deliberately no debounce, no
/// timer, no "wait for the next tick" and no heartbeat wait on this path:
/// the heartbeat only ever repairs a lost packet, it is never what the
/// open waits on. The only wait after the trigger is the title resolution
/// itself (a provider round-trip, bounded by the resolver's timeouts) —
/// and a newer live title supersedes an open still in flight instead of
/// queueing behind it. "Zero latency" here means it feels instant, not a
/// literal zero; no user-facing text claims otherwise.
///
/// DEDUPE. One player, ever: an open is keyed by title + source + episode
/// token ([guestAutoOpenKey]); a duplicate go-live, a rejoin, or a
/// re-publish of the same title is the same key and does nothing, and a
/// title/source change pops the old player before pushing the new one.
///
/// OPT-OUT. If the guest presses Back out of an auto-opened player, this
/// title is not forced on them again — but a NEW title still auto-opens.
/// The opt-out is per title key, never per room.
///
/// HOST LEAVES. When the host is gone ([TogetherService.hostGone] — a
/// `bye`, a presence `left`, or 8 s of host silence) while an auto-opened
/// (or adopted) player is up, the player closes back to the Together
/// screen with a short line. A player on any other title is left alone.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/domain/entity/multimedia_item.dart';
import '../../core/extensions/base_provider.dart';
import '../../core/extensions/extension_manager.dart';
import '../../core/router/app_router.dart';
import '../../core/services/notification_service.dart';
import '../details/presentation/details_controller.dart';
import '../details/presentation/widgets/provider_search_section.dart';
import '../search/presentation/search_provider.dart';
import 'guest_title_resolver.dart';
import 'models.dart';
import 'together_provider.dart';
import 'together_service.dart';

/// What the guest auto-open policy says to do about the current room
/// snapshot. Pure, so tests can pin it without a widget.
enum GuestAutoOpenAction {
  /// Nothing to do right now.
  none,

  /// Open (or switch to) the live title.
  open,

  /// Close the auto-opened player back to the Together screen: the host
  /// is gone.
  closeToTogether,
}

/// The open key for a live title: TMDB id, base title, episode label,
/// source label and episode token. Two states with the same key are the
/// same open — a re-publish, a duplicate go-live, a rejoin. Anything that
/// changes the key (a new title, a new episode, a host source pick, a new
/// episode token) is a new open.
String guestAutoOpenKey(TogetherMediaIdentity media) => <String>[
  media.tmdbId?.toString() ?? '',
  baseTitleOf(media),
  media.episodeLabel ?? '',
  media.source ?? '',
  media.episodeUrl ?? '',
].join('|');

/// The pure decision: given the room as it stands, what should the
/// coordinator do? No navigation, no resolution, no side effects — the
/// widget does those. Every branch is pinned by
/// `test/together_guest_auto_open_test.dart`.
class GuestAutoOpenPolicy {
  static GuestAutoOpenAction decide({
    required TogetherRole? role,
    required TogetherPhase phase,
    required TogetherMediaIdentity? liveMedia,
    required bool hostGone,
    required bool playerOpen,
    required TogetherMediaIdentity? playerOpenMedia,
    required String? openedKey,
    required String? optedOutKey,
  }) {
    if (role != TogetherRole.guest) return GuestAutoOpenAction.none;
    // The host left while an auto-opened (or adopted) player is up:
    // close it back to the Together screen. A player on any other title
    // is not ours to close, and with no player up there is nothing to do.
    if (hostGone && openedKey != null && playerOpen) {
      return GuestAutoOpenAction.closeToTogether;
    }
    // A gone host's title is never opened — not even a different one the
    // guest has not seen yet. The coordinator's post-resolution check is
    // the backstop; this keeps it from starting a resolution at all.
    if (hostGone) return GuestAutoOpenAction.none;
    if (phase != TogetherPhase.live || liveMedia == null) {
      return GuestAutoOpenAction.none;
    }
    final key = guestAutoOpenKey(liveMedia);
    // Already watching this exact title + source: nothing to do — this is
    // what stops a duplicate go-live, a 1 s state re-publish and a rejoin
    // from stacking a second player.
    if (playerOpen &&
        playerOpenMedia != null &&
        guestAutoOpenKey(playerOpenMedia) == key) {
      return GuestAutoOpenAction.none;
    }
    // Opened already for this key (the player is still settling in after
    // the push, or the guest is watching it): nothing to do.
    if (openedKey == key) return GuestAutoOpenAction.none;
    // The guest backed out of this exact title: stay out until a new
    // title (or source) arrives.
    if (optedOutKey == key) return GuestAutoOpenAction.none;
    return GuestAutoOpenAction.open;
  }
}

/// Root-mounted guest auto-open coordinator. Renders nothing.
class TogetherGuestAutoOpen extends ConsumerStatefulWidget {
  const TogetherGuestAutoOpen({super.key});

  @override
  ConsumerState<TogetherGuestAutoOpen> createState() =>
      _TogetherGuestAutoOpenState();
}

class _TogetherGuestAutoOpenState extends ConsumerState<TogetherGuestAutoOpen>
    with WidgetsBindingObserver {
  /// Generation of the open currently in flight. A newer live title bumps
  /// it, abandoning the older resolution wherever it is — the loser sees
  /// the mismatch and touches nothing.
  int _generation = 0;

  /// True while a resolution is in flight.
  bool _opening = false;

  /// The key the in-flight resolution is opening, or null while none is.
  /// Stops a service notification caused by the open itself (the
  /// "Opening…" state) from starting the same open a second time.
  String? _openingKey;

  /// The key the currently-open player was opened (or adopted) for, or
  /// null while no Together player is up.
  String? _openedKey;

  /// The key the guest backed out of, or null. Only the exact key is
  /// suppressed — a new title still auto-opens.
  String? _optedOutKey;

  /// True while a pop-then-push title switch is between the two routes.
  /// Cleared the moment a player is open again; a delayed safety clear
  /// covers a push that never lands.
  bool _switching = false;

  /// Token for the delayed safety clear of [_switching]: a newer switch
  /// replaces it, so a stale timer can never clear a live switch.
  Object? _switchToken;

  /// Open provider-search subscriptions, closed in [dispose] (and when
  /// their bridge stream is cancelled).
  final List<ProviderSubscription<AsyncValue<SearchAggregateState>>>
  _searchSubscriptions = <ProviderSubscription<AsyncValue<SearchAggregateState>>>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _searchSubscriptions) {
      sub.close();
    }
    _searchSubscriptions.clear();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background → foreground: a go-live that arrived while the app was
    // backgrounded sits in the retained service state already — re-evaluate
    // it at once instead of waiting for the next relay event.
    if (state == AppLifecycleState.resumed) _evaluate();
  }

  @override
  Widget build(BuildContext context) {
    // The trigger is the service notification itself — see the file doc
    // comment. No debounce, no timer, no heartbeat wait.
    ref.listen(togetherServiceProvider, (_, _) => _evaluate());
    return const SizedBox.shrink();
  }

  void _evaluate() {
    if (!mounted) return;
    final service = ref.read(togetherServiceProvider);
    // Session over: forget what was opened for it.
    if (!service.isSessionActive) {
      _openedKey = null;
      _optedOutKey = null;
      _switching = false;
      _switchToken = null;
      return;
    }
    // A switch that landed: a player is open again, so the pop-then-push
    // gap is over.
    if (_switching && service.isPlayerOpen) {
      _switching = false;
      _switchToken = null;
    }
    // The player closed without the coordinator touching it: the guest
    // backed out. Remember which title they left, so this title is not
    // forced on them again — a NEW title still auto-opens.
    if (!service.isPlayerOpen &&
        _openedKey != null &&
        !_opening &&
        !_switching) {
      if (service.phase == TogetherPhase.live &&
          service.roomState?.media != null) {
        _optedOutKey = guestAutoOpenKey(service.roomState!.media);
      }
      _openedKey = null;
    }
    final media = service.roomState?.media;
    final action = GuestAutoOpenPolicy.decide(
      role: service.role,
      phase: service.phase,
      liveMedia: media,
      hostGone: service.hostGone,
      playerOpen: service.isPlayerOpen,
      playerOpenMedia: service.playerOpenMedia,
      openedKey: _openedKey,
      optedOutKey: _optedOutKey,
    );
    switch (action) {
      case GuestAutoOpenAction.none:
        // Adopt: the player is open on the live title without us — the
        // guest opened it by hand before Start — so treat it as ours: a
        // later host-leave closes it, and a duplicate go-live does not
        // stack a second player.
        if (media != null &&
            service.isPlayerOpen &&
            service.playerOpenMedia != null &&
            guestAutoOpenKey(service.playerOpenMedia!) ==
                guestAutoOpenKey(media)) {
          _openedKey ??= guestAutoOpenKey(media);
          _optedOutKey = null;
        }
      case GuestAutoOpenAction.open:
        if (media == null) break;
        final key = guestAutoOpenKey(media);
        // Already opening this exact title (a notification the open
        // itself caused): do not start it a second time.
        if (_opening && _openingKey == key) break;
        unawaited(_openLive(media));
      case GuestAutoOpenAction.closeToTogether:
        unawaited(_closeToTogether());
    }
  }

  bool _stillCurrent(int generation) =>
      mounted && generation == _generation;

  /// Finishes an open attempt — but only if it is still the current one.
  /// A superseded attempt touches nothing: the newer open owns the
  /// pending / failure / notice state now.
  void _finishOpen(
    int generation, {
    String? failure,
    String? openedKey,
    String? notice,
  }) {
    if (generation != _generation) return;
    _opening = false;
    _openingKey = null;
    final service = ref.read(togetherServiceProvider);
    service.setGuestAutoOpenPending(false);
    service.setGuestAutoOpenFailure(failure);
    if (openedKey != null) {
      _openedKey = openedKey;
      _optedOutKey = null;
    }
    if (notice != null) {
      service.setGuestAutoOpenNotice(notice);
      // Brief by design: the note clears itself a few seconds after the
      // open, so it never outlives the moment it explains.
      final shownNotice = notice;
      Future<void>.delayed(const Duration(seconds: 6), () {
        if (!mounted) return;
        final current = ref.read(togetherServiceProvider);
        if (current.guestAutoOpenNotice == shownNotice) {
          current.setGuestAutoOpenNotice(null);
        }
      });
    }
  }

  /// Resolves [media] and pushes the player for it.
  Future<void> _openLive(TogetherMediaIdentity media) async {
    // A newer live title supersedes an open still in flight: bump the
    // generation and the older resolution abandons itself wherever it is.
    final generation = ++_generation;
    final key = guestAutoOpenKey(media);
    _opening = true;
    _openingKey = key;
    final service = ref.read(togetherServiceProvider);
    service.setGuestAutoOpenPending(true);
    GuestTitleResolution? resolution;
    try {
      resolution = await resolveGuestTitle(
        identity: media,
        loadDetails: _loadDetails,
        loadStreams: _loadStreams,
        searchTitles: _searchTitles,
      );
    } on GuestTitleResolutionFailure catch (e) {
      _finishOpen(generation, failure: e.message);
      return;
    } catch (_) {
      _finishOpen(generation, failure: kGuestTitleNotFoundMessage);
      return;
    }
    if (!_stillCurrent(generation)) return;
    // The room may have ended — or the host left — while resolving: never
    // open a dead room's title. A changed title is already being opened by
    // a newer generation; an ended room has nothing to open.
    final current = ref.read(togetherServiceProvider);
    if (current.phase != TogetherPhase.live ||
        current.hostGone ||
        current.roomState?.media != media) {
      _finishOpen(generation);
      return;
    }
    final router = ref.read(appRouterProvider);
    // A player is already up on a different title: pop it first so two
    // players never stack, then open the new one.
    if (current.isPlayerOpen && playerRouteIsOnTop(router)) {
      _switching = true;
      final token = _switchToken = Object();
      Navigator.of(context).pop();
      // Let the pop land before pushing, so the old player route is gone
      // when the new one arrives.
      await Future<void>.delayed(Duration.zero);
      if (!_stillCurrent(generation)) return;
      // Safety: a push that never lands must not leave switching set
      // forever and disable the opt-out detection.
      Future<void>.delayed(const Duration(seconds: 10), () {
        if (mounted && _switchToken == token) {
          _switching = false;
          _switchToken = null;
        }
      });
    }
    if (!_stillCurrent(generation)) return;
    try {
      PlayerRoute(
        $extra: PlayerRouteExtra(
          item: resolution.item,
          videoUrl: resolution.videoUrl,
          episode: resolution.episode,
          preloadedStreams: resolution.preloadedStreams.isEmpty
              ? null
              : resolution.preloadedStreams,
        ),
      ).push<void>(context);
    } catch (_) {
      _finishOpen(generation, failure: kGuestTitleNotFoundMessage);
      return;
    }
    _finishOpen(generation, openedKey: key, notice: resolution.sourceFallbackNotice);
  }

  /// Closes an auto-opened player after the host left, back to the
  /// Together screen, with a short line. Only the player this coordinator
  /// opened (or adopted) is closed: a guest watching something else keeps
  /// watching.
  Future<void> _closeToTogether() async {
    if (_openedKey == null) return;
    final service = ref.read(togetherServiceProvider);
    final router = ref.read(appRouterProvider);
    if (service.isPlayerOpen && playerRouteIsOnTop(router)) {
      Navigator.of(context).pop();
      await Future<void>.delayed(Duration.zero);
    }
    if (!mounted) return;
    _openedKey = null;
    _optedOutKey = null;
    // The player exit restores portrait on its own (2.10.0); the go lands
    // the guest on the Together screen either way.
    context.go('/together');
    ref
        .read(notificationServiceProvider)
        .showInfo('Host left the room — back to Together.');
  }

  // ---- Resolver wiring (providers live here, decisions in the resolver) ----

  /// Loads full details (episodes included) for [baseItem] through the
  /// details controller on the item's URL. Null when there is no URL or
  /// the load cannot — the resolver then tries the next tier.
  Future<MultimediaItem?> _loadDetails(MultimediaItem baseItem) async {
    if (baseItem.url.isEmpty) return null;
    final notifier = ref.read(detailsControllerProvider(baseItem.url).notifier);
    await notifier.loadDetails(baseItem);
    if (!mounted) return null;
    final state = ref.read(detailsControllerProvider(baseItem.url));
    return state.details.asData?.value;
  }

  /// Loads the stream list for one episode token through the item's
  /// provider (falling back to the active provider). An empty list when
  /// no provider can answer — the resolver then tries the next tier.
  Future<List<StreamResult>> _loadStreams(
    MultimediaItem item,
    String episodeUrl,
  ) async {
    final manager = ref.read(extensionManagerProvider.notifier);
    final wanted = item.provider;
    NovaFlixProvider? provider;
    if (wanted != null && wanted.isNotEmpty) {
      provider = manager.getAllProviders().firstWhereOrNull(
        (p) => p.packageName == wanted || p.name == wanted,
      );
    }
    provider ??= ref.read(activeProviderProvider);
    if (provider == null) return const <StreamResult>[];
    return provider.loadStreams(episodeUrl);
  }

  /// Bridges the shared provider search ([providerSearchProvider], the
  /// family over [searchAllProviders]) into the progressive batch stream
  /// the resolver consumes: each aggregate state yields its items, and
  /// the stream closes when the search reports done. The subscription is
  /// tracked and closed with the bridge (and in [dispose]). The resolver
  /// stops early on a match — its `await for` breaking out cancels this
  /// bridge, which closes the subscription.
  Stream<List<MultimediaItem>> _searchTitles(String query) {
    final controller = StreamController<List<MultimediaItem>>();
    // `listenManual` (not `listen`): this runs from an event handler, not
    // `build`, and the subscription must be closable — `WidgetRef.listen`
    // returns void in Riverpod 3.
    final sub = ref.listenManual(providerSearchProvider(query), (previous, next) {
      // The codebase's established read: `asData?.value` (see
      // details_controller.dart).
      final SearchAggregateState? state = next.asData?.value;
      if (state == null || controller.isClosed) return;
      controller.add(
        state.results
            .expand((ProviderSearchResult result) => result.results)
            .toList(),
      );
      if (!state.isLoading) {
        unawaited(controller.close());
      }
    });
    _searchSubscriptions.add(sub);
    controller.onCancel = () {
      sub.close();
      _searchSubscriptions.remove(sub);
    };
    return controller.stream;
  }
}
