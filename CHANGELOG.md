# YumeFlix 2.11.0 — Guest auto-open + guest rules + zero-latency sync + in-app updates + names & HOST 👑

### Guest auto-open (the 2.10.0 two-phone failure, fixed)
- Root cause: there was no auto-open at all — on Start the guest only got a relay state and had to tap "Find this title to join playback" themselves.
- Fixed: a root-mounted, render-nothing coordinator (`guest_auto_open.dart`) watches `TogetherService` via `ref.listen`; the trigger is the service notification itself — the host's go-live flips the phase synchronously and the listener fires in the same round. No debounce, no timer, no heartbeat wait. Same instant trigger for join-if-already-live, host title/source change, and foreground resume (retained live state re-evaluated on resume). Pure `GuestAutoOpenPolicy.decide()` pins the decision; dedupe key = TMDB id + title + episode label + source + episode token, so duplicate go-live / re-publish / rejoin is a no-op and a title/source change pops the old player then pushes the new one. Guest pressing Back opts out of that exact key only; host gone closes only the auto-opened/adopted player back to `/together` with "Host left the room — back to Together."
- Title resolution (`guest_title_resolver.dart`), three tiers: (1) host's exact episode token + provider, pre-resolve streams, host source first, pushed as `preloadedStreams` (player opens index 0, probes, fails over); (2) detail URL → load details → pick episode by S/E numbers (numbers matching nothing → null, never the wrong episode; film takes first); (3) title search, exact normalised title + matching type, TMDB-id preferred. Timeouts: search 15 s, streams 20 s. Direct tokens (torrent/magnet/local/direct) skip pre-resolve.
- Payload: `TogetherMediaIdentity` now carries `season`, `episode`, `provider`, `itemUrl`, `episodeUrl`, `source` (all optional, backward/forward compatible). Host's `attachMedia` resets position to 0 only on a real title change, never on a source-only pick.
- Same source: the guest plays the host's chosen server/provider; if it is genuinely absent, the guest plays best-available and the player says so briefly ("The host's source "Server 1" wasn't available — playing the best available source instead.", auto-clears after 6 s). All tiers fail → "Couldn't open this title automatically — tap to find it" on the Together screen with the manual "Find this title" fallback; "Opening the host's title…" shows while resolving.
- Pill: the orb already hides when `startState == live`, so the pill vanishes the moment live playback starts and returns only per 2.10.0 semantics. Session end → guest returns to Together in portrait, no stale pill. JOIN → WAIT: the guest-only waiting card shows until the host starts (host never sees it).

### Guest rules (user's authoritative spec)
- Up to 5 guests per room (host + 5). Enforced host-side on presence-join AND heartbeat. 6th joiner gets a targeted `room-full` event, is dropped from the member list at once, leaves cleanly and sees "This room is full — the host already has 5 guests."; Retry rejoins as the same guest (code + name restored). A guest leaving frees the seat; same guest re-joining counts once. Stale members pruned after 10 s without a heartbeat. `members` returns host first, guests in join order; presence label is count-based ("HOST 👑 + 2 guests in room").
- Guest controls are LOCAL ONLY: brightness up/down, volume up/down, play/pause — guest only. Guest cannot change series/episode, language, server/provider, or title: no episode buttons, no panel tabs, no startup source rows, no skip-outro/up-next/ended-card next-episode for guests; method guards in `_pickSource`, `_applyTorrentFile`, `_advance`, `_goToPreviousEpisode`, `_offerNextEpisodeNow` refuse guests as defence in depth. Seeks, speed boost, scrub, rewind/forward stay blocked for guests.
- Guest pause = local pause: hook flag `_guestLocallyPaused` — guest pause holds only that phone, never publishes, never snaps back; guest play clears the flag and forces a catch-up seek to the host's current live position (resume = "jump to live", never resume-where-stopped). Guest seek is not a thing. Pill copy says what the guest can do: "Host controls playback · pause holds only you" / when paused "Paused — play jumps back to the host".
- Host keeps full control: play, pause, seek, change title/episode, change server/language — host only. Host source reporting on resolution + explicit host picks (never on automatic failover — failover stays local); hook `updateSource` is idempotent and converges on the same `withSource` identity as the first-frame direct `attachMedia(media.withSource(...))` call.

### Guest names + HOST 👑
- Join with name: after entering the code and tapping Join, a pop-up asks "Type your name" BEFORE entering the room. Name is REQUIRED — Join disabled until valid; trim, max 20 chars, inline error "Type your name to join." Last typed name is remembered (`together.last_guest_name`) and pre-filled next time. The name travels in presence + heartbeat + chat (`senderName`/`senderRole`).
- Chat shows names: bubbles and reply quotes show the typed name (`togetherChatSenderDisplayName`); host renders "HOST 👑" (crown emoji + label, never colour alone); pre-2.11.0 messages fall back to "Friend"; own messages stay "You".
- Member list (`together_member_list.dart`, new): HOST 👑 + typed names with "(you)" suffix, in the Together screen (pending/waiting/live cards) and the orb's expanded card, kept in sync as people join/leave.

### Zero-latency sync (honest numbers, no "zero latency" in user-facing text)
- Host actions publish instantly on the action — play, pause, seek, speed, title/episode change, server change, leave/end. No debounce, batching, or poll wait anywhere on the publish path (`reportLocalPlayback` → `_publishState` is a direct synchronous publish); the 1 s heartbeat is a safety net only, never the delivery path.
- MQTT keep-alive tightened 20 s → 10 s so a silently dead network is noticed in ~10 s. Reconnect backoff 1/2/4/8/15 s, max 5 attempts.
- Drift correction: nudge ≥150 ms at ±5% rate, seek >750 ms — 150/750 is the tightest stable combination, proven by simulation (tighter would sit inside normal clock-skew + jitter noise, ±100 ms skew + ±50 ms jitter ≈ ±150 ms). Seek detection is elapsed-aware with a 400 ms excess threshold — catches a +500 ms forward seek instantly. Convergence simulation: 1× and 2× hosts, 5 s behind, ~100 ms latency + jitter → exactly 1 seek, then drift <150 ms, no oscillation; 400 ms drift glides in with 0 seeks.
- Speed is now carried end-to-end (payload `playbackSpeed`, `liveTargetMs`, `decideSync`/`decideResumeSync`, heartbeat samples, rejoin adoption). A 2× host no longer makes the guest seek forever. Hook wirings: host passes `value.playbackSpeed` into `reportLocalPlayback`; guest passes `state.playbackSpeed` into `decideSync`.
- Stale-state fixes (12): `hostGone` was write-only — now cleared on fresh state/heartbeat/presence; ghost "Host is playing" after host closes the player (close now publishes paused at the frozen position); host-leave leaves a stale status (new `TogetherRoomStatus.hostLeft`, "Host left the room"); silence timer fired during reconnect (now returns early while reconnecting); retained state re-delivered on reconnect was dropped as duplicate (re-sync trigger armed on reconnect); restarted host (new client id, sequence back at 1) was dropped as stale forever (sequence space resets when hostId changes); stale title/source survived a re-share (`_pendingMedia` now assigned, was `??=`); host title change while waiting never notified (heartbeat now notifies on media change); waiting screen showed stale status over a dropped relay (headline becomes "Connection lost — reconnecting…" + attempt line, stale card suppressed while reconnecting); guest pause leaking to the room — audited, no leak found, every publish path is role-gated host-only; server change rewound guests to 0 (source-only change now keeps position; source identity survives state round-trip, re-sync and reconnect); host speed gap (see above).
- Reconnect: guest sees "Connection lost — reconnecting… (Attempt N/5 — re-syncs automatically…)", keeps local state; on relay answer the retained state is re-applied and the guest re-syncs to the host's current title/position/playing state, including seeks made while dark. Names and host identity survive (presence re-published with `displayName`; a nameless heartbeat never wipes a known name).
- Professional pass: "Joining the live session…" loading state with the room poster as logo fallback when a guest's player opens live (no blank screen, no jarring jump). Live health thresholds unchanged from 2.10.0 (RTT >800 ms / drift >750 ms / reconnecting / heartbeat stale >3 s → orange).
- Known limits (unchanged): chat photos paced at 250 ms/chunk (~8 s per 1 MB, ~40 s per 5 MB, with progress); forward seeks <~400 ms can wait up to 1 s for the steady tick; host language change is not propagated (no payload field); EMQX vs Mosquitto retained state doesn't replicate, so a relay split-brain splits the room.

### In-app updates (never go to GitHub again)
- Check: on app start and on foreground-resume, background check of the public latest-release API (`https://api.github.com/repos/DevDoodle-69/YumeFlix-uprated/releases/latest`, no auth), debounced to at most once a day (attempt recorded before fetching). Installed version from `package_info_plus`. Never blocks startup (fire-and-forget); every failure — no network, non-200, malformed JSON, draft/pre-release, no universal asset — returns null and fails silently.
- Soft prompt: minimal `AlertDialog` in theme colours — "Update available — vX.Y.Z", size, short "What's new" from release notes (flattened, capped at 480 chars), "Update now" / "Later". Dismissal respected: no more prompts for that version; at most once per version per day. Decision logic is a pure function with an injectable clock.
- Auto-download after 3 days: first-seen timestamp persisted in `SharedPreferences`; 3 days after first sight of a dismissed version, the universal APK auto-downloads in the background via the existing `background_downloader` (own `app-update` group + system progress notification; tapping it re-shows an in-app progress dialog with Cancel). Wi-Fi/Ethernet-only, enforced twice (Dart-side decision + `requiresWiFi: true` on the task); on mobile data after 3 days the prompt is re-shown instead of silently downloading ~120 MB. The app is never blocked while downloading.
- Install: APK to the application documents directory (`.../updates/`, no storage permission needed, existing FileProvider `<files-path>` already serves it — no new `file_paths.xml`). Verified by size against the release asset before offering install (SHA-256 computed/recorded and enforced whenever a checksum is supplied; the release publishes none today). Partial/interrupted files are deleted, never installed; stale APKs from other versions cleaned up on start. New `yume.flix.by.nzr/app_update` MethodChannel in `MainActivity.kt` (`canRequestInstall`, `requestInstallPermission` → system "Install unknown apps" page, `installApk` → `ACTION_INSTALL_PACKAGE` via FileProvider). Permission denied → one explanation dialog with an Open-settings button; update stays available. No silent install — Android always shows the system installer. After a completed download, a "Download complete — tap to install" dialog appears (also re-offered on next launch).
- Permissions: one line added to `AndroidManifest.xml`: `REQUEST_INSTALL_PACKAGES`. No new dependencies — everything used (`http`, `package_info_plus`, `shared_preferences`, `connectivity_plus`, `path_provider`, `crypto`, `background_downloader`) was already in `pubspec.yaml`. `main.dart` wiring is 18 lines (import + delimited block in `_MyAppState`'s post-frame callback).

### Live verification
- `tools/live_check.dart`: 62/62 passed — new check 7 (in-app updates: latest tag `v2.10.0`, universal asset present, download URL HEAD 200) and new check 8 (presence carries role + typed name; go-live media carries provider + source + episode URL + season/episode + TMDB id over the live EMQX broker; 6th guest receives the targeted room-full with the honest message). Full test suite 403/403, `flutter analyze` 0 errors/warnings (61 info-only, pre-existing style + `avoid_print` in the CLI script).

# YumeFlix 2.10.0 — Live indicator fixed (in-player, green/orange health) + orientation restores to portrait on exit

### Bug 1 — "Live" pill showed on home while watching nothing: now lives only in the player controls
- Root cause: the floating Live pill read the Together session phase, which is sticky — it flips to `live` on Start and nothing flipped it back when the player was left, playback paused, or the host left (`together_service.dart:426` `isLive`, phase only reset by `leaveRoom()`). The orb is mounted once above the router (`lib/main.dart:404`), so it survived every pop and the pill stayed on home, details and search. Pausing while live never even notified listeners, so the UI never rebuilt.
- Fixed: new `TogetherService.isShowingLive` — true iff the phase is live AND the host is present AND a player is open AND the shared title is actually playing AND media is known. Pausing, leaving the player, the host leaving, or the session ending all hide it immediately (pausing falls back to the neutral browsing pill; resume brings Live back with no second Start tap). `reportLocalPlayback` now notifies on any play/pause flip. The floating Live pill is deleted entirely.
- New indicator (`together_live_indicator.dart`): blinking dot + "Live" in the player control panel's bottom row, immediately left of the chat icon; it unmounts (renders nothing) whenever the session is not live. Health thresholds, documented in code: green while RTT ≤ 800 ms, guest drift ≤ 750 ms, not reconnecting, host heartbeat fresh; orange when RTT > 800 ms, drift > 750 ms, reconnecting, or host heartbeat stale > 3000 ms (3 missed 1 s beats). Green `0xFF4CAF50`, orange `0xFFED8A3C` — flat status colours, no glow. The browsing/"Enjoy Together" pill is unchanged and only shows while a room is open and not live.

### Bug 2 — home stuck in landscape after leaving the player: restore is now terminal and retryable
- Root cause (correction: no restore call was missing — `dispose()` did call `restoreOrientation`): the single dispose-restore was defeatable three ways in `PlayerPlatformService`: (1) pop-transition tick race — the player route stays mounted ~300 ms through the pop while playback ticks (~4/s) keep calling `applyLandscapeOrientation()`, and a tick landing after the restore re-pinned landscape while the portrait request was dropped as stale; (2) a failed landscape pin cleared the flag that gated restore, so restore early-returned; (3) a failed restore was swallowed and a second restore was a no-op — one failure meant landscape for the rest of the process. Latent: the restore target was the cached form, so a tablet-profiled phone got `[]` (release) instead of portrait.
- Fixed: restore is now terminal — once `restoreOrientation` runs, `applyLandscapeOrientation()` is a no-op for that player instance, so pop-transition ticks can't re-pin; restore is owed whenever landscape was ever requested, not only while pinned; a failed restore is retryable (re-queued on the next restore call, no-op once delivered). New `PlayerOrientationController` owns the screen's orientation contract (`onPlaybackTick`, `onForegrounded`, `onBack`, `dispose`); `_handleBack` now restores BEFORE `navigator.pop()` (restore issued while the route/channel is definitely alive) with dispose as the second chance; foregrounding re-asserts landscape when returning to a still-open player (Home-button/PiP return), no restore on background so PiP return still works. TV behaviour unchanged (landscape pin on TV, release on exit); Together Start flow untouched.

### Reference material applied (user-supplied skill repos)
- jeffallan/claude-skills `flutter-expert` (plus `code-reviewer`, `debugging-wizard`): narrow `select()` watches so the 1 s heartbeat doesn't rebuild the player, const constructors, `RepaintBoundary` around the blinking dot, Semantics labels (meaning in words, never colour alone), ≥44 dp touch targets, root-cause-first debugging (failing-test repros before fixes, SDK source checked for imperative-pop semantics), test-after-each-feature workflow.
- dpconde/claude-android-skill (translated to Flutter, no Kotlin added): testable-by-design (fake `setPreferredOrientations` seam, no mocking libraries), unidirectional data flow (screen events → controller → service → channel), modular-by-feature (all changes inside the player/Together features). Skipped: Kotlin/Compose, Hilt/Room/Flow, Gradle setup — they don't translate to this Flutter codebase; no big refactor, only one small controller extraction.

### Live verification
- `tools/live_check.dart`: 45/45 passed (unchanged checks; orientation cannot be live-checked, covered by widget tests instead). Full test suite 262/262, `flutter analyze` 0 errors/warnings (47 info-only, pre-existing style + `avoid_print` in the CLI script).

# YumeFlix 2.9.0 — Together bugs fixed from the user's screen recording + full UI quality pass

### Bug 1 — giant broken waiting overlay: guest-only, bounded, never giant
- Root cause: the guest waiting card had no role gate at the widget layer and no bounds (no text-scale clamp, no maxLines/overflow on any line), so it could render over the host's own screen and explode at large text scales. No widget in the app renders red text with a yellow underline — the literal renderer was not found in code, and the overlay does not appear in any sampled frame of the recording; what was proven and closed is the wrong-audience path and the unbounded rendering.
- Fixed: the waiting state returns nothing unless the viewer is the guest (widget + screen both gate on role), the whole card is clamped to 1.3x text scale, every line is explicit small white/grey on dark with maxLines + ellipsis, no red, no yellow, no underline. The orb's expanded card carries the same role gate and bounds.

### Bug 2 — movie showed "S1 E1" again: single title rule everywhere
- Root cause: `togetherMediaIdentityFor` in the player hook built the Together title with `· S{season} E{episode}` unconditionally, fed by a dummy season-1/episode-1 episode the details controller files for movies. The room card showed the suffix twice (title + a second S/E line).
- Fixed: the Together title now comes from the single shared rule (`formatWatchingTitle` — S/E only for true series/anime with season > 0 and episode > 0); poisoned 2.8.0 relay/persisted payloads are sanitised at the wire boundary; the room card shows S/E exactly once for series and never for movies. Same rule also applied to Home continue-watching/synced cards and library downloads rows, which rendered S/E with no movie gate.

### Bug 3 — duplicate Start buttons: one Start control, one source of truth
- Root cause: the orb had two distinct Start implementations (the collapsed pill's own Start row and a `TogetherStartButton` inside the expanded card), driven by different tap paths.
- Fixed: the collapsed pill in `ready` IS the `TogetherStartButton` — the only Start control in the app. The expanded card never renders Start; if it is open when the room becomes ready it collapses itself so the pill is what's on screen. One tap fires Start exactly once.

### Bug 4 — orb in landscape: stays horizontal, stays out of the way
- Root cause: there is no rotated subtree in the app (the player pins landscape at window level), so the vertical pill in the recording is a whole-frame rotation artefact — but the real defect was position: one saved screen fraction was reused across orientations, the top clamp was a fixed 64 px, and the bottom clamp ignored the seek bar, so the pill could land on the seek bar, centre controls, or the room code.
- Fixed: orientation-specific placement bands applied on every build and every drag, safe-area aware (portrait top 120 dp, landscape top 96 dp; landscape bottom 152 dp reserved for seek bar + transport); separate landscape default position; drag clamped so the pill can never cover the room code or primary content. Expanded card is height-capped and scrollable in short landscape windows.

### Confirmed Start flow (movie + series): tap, vanish, both play together
- Host taps Start on the floating widget: the button vanishes in the same synchronous step and Together playback starts for both at the same time — the guest receives the retained playing state for the same title and position. For series the shared title is the exact episode the host is playing (same-show episode matching now compares episode labels too, not just the show id); changing episode re-shares cleanly at position 0 (the hook now retargets on every episode advance). Note: the guest's player does not auto-open on Start yet — the guest opens the title via the existing "find this title" action; that is a deliberate navigation decision left for a follow-up.

### UI quality + responsiveness pass (all screens)
- One typography scale, consistent spacing/alignment, 44-48 dp touch targets, consistent card/corner/chip treatment. Loading states are neutral skeletons (search now shows poster + text shimmer rows instead of a bare spinner); error states are short, honest, minimal. Text never clips/overflows at normal font sizes; safe-area/margin handling in portrait and landscape.
- Responsive: shared grid-column rule (`gridColumnsForWidth`) reused in details episode grids and view-all; layouts reflow across phone portrait/landscape, tablet, and TV instead of clipping. Dead code removed (unused player chat button, unused player-style aliases). Minimal professional language kept throughout (near-black neutrals, grey text, one muted slate-blue accent, no neon, no glow).

### Live verification
- `tools/live_check.dart`: 45/45 passed, including new checks — movie go-live title is bare ("Dune", no S/E), episode go-live title carries the exact S/E ("Dexter: Resurrection · S1 E1"), re-share starts at position 0. Full test suite 230/230, `flutter analyze` 0 errors/warnings.

# YumeFlix 2.8.0 — Together, perfected: host control, no latency, 5 MB chat photos

### Enjoy Together — the priority: professional, accurate, no latency
- Host has full control: play, pause, seek, changing movie/episode — the guest follows exactly. While live, guest playback controls are host-only and clearly shown as such, so guest input can never fight the host.
- No latency: host actions publish state IMMEDIATELY (play/pause/seek/title change never wait for the next heartbeat); the heartbeat is now 1 s and only a backstop. Drift correction tightened (rate-nudge within 150 ms, seek beyond 750 ms), guest evaluation runs twice as fast, and the status pill shows the real measured relay latency.
- Rejoin/resync is fast and exact: retained state plus an immediate state push when a guest joins; a title change clears the old position and re-shares the new title at 0.
- Start button redesigned (the 2.7.0 "Ready to start" pill showed all the time in red underlined text): while browsing the room shows only the small neutral draggable pill — no start text anywhere. Once something is actually playing, a compact dark run button appears (play icon + "Start", muted slate-blue, no red, no underline, no glow). Tapping it starts Together streaming and the button vanishes at once, replaced by a tiny "Live" dot and the glass chat button; it never reappears while live.
- Chat photos up to 5 MB (was ~120 KB, PNG-only): JPEG, PNG, WebP and GIF. Oversize photos are downscaled/compressed on-device until they fit; only an unfixable image is refused, with a clear message. Because the public MQTT relay cannot carry a 5 MB message, photos travel as 32 KiB chunks with message id + index/total + SHA-256 integrity, reassembly only when complete and verified, progress while sending/receiving, and retry of missing chunks (chunks are paced 250 ms apart — the public relay drops rapid bursts, proven live).

### Discord cover — best effort, hardened (2.7.0 still showed no cover for Dexter)
- Root cause: the keyless fallback needed an IMDb id that plugin items never carry, the player collapsed all artwork into a single URL, and verification of image.tmdb.org is flaky under short timeouts (proven live: the same URL failed, then passed minutes later).
- Fixed: keyless Cinemeta title search needs no id at all (exact-title match only); the player now passes every artwork URL (episode still, item poster, banner) and each is verified in order; the verifier falls through to ranged GET on redirects and uses 10 s timeouts. Still never a dead asset key: no verified poster means no image is sent. Settings -> Discord diagnostics show the exact large_image value sent.

### UI polish — more professional, more accurate
- Red is no longer used as normal UI: filter-active dots, search active bars, DEBUG chips/badges and the LIVE badge now use the muted slate-blue accent or neutral grey. The only red left is for genuinely destructive actions (Delete/Clear) and real error states. Underlines appear only on real links. Remaining gradients are neutral black/white legibility scrims over artwork, never colour.

### Live verification — tools/live_check.dart now checks six things live
- Together MQTT round-trip, chunked ~1 MB photo round-trip (byte-exact SHA-256), Discord poster chain for Harry Potter (movie) AND Dexter: Resurrection (series, by id and by title search), MovieSubLK live, and the Together start flow over the real broker (browsing shows no go-live state, Start publishes a retained playing state, title change re-shares at position 0).


# YumeFlix 2.7.0 — Discord cover fixed live, Together fixed live, minimal professional restyle, MovieSubLK provider

### Discord cover — fixed for real (proven live)
- Root cause: the TMDB fallback was dead in shipped builds (no TMDB key was ever set in CI, so the resolver always returned null), and the fallback large image was the `yumeflix_logo` asset key, which was never uploaded under the Discord app — a missing asset renders as the black circle seen on every movie.
- Keyless poster chain: Cinemeta (`v3-cinemeta.strem.io/meta/<movie|series>/<imdbId>.json`, no key) resolves the exact poster by IMDb id; every candidate poster is verified fetchable (HTTP 200 + image/*, HEAD with ranged-GET fallback) before it is sent; if nothing verifies, no `assets` object is sent at all — never a dead asset key again. Extension poster, TMDB-by-id (when a key is configured), and Cinemeta all feed the chain. Movies still never show "S1 E1".
- Settings -> Discord now shows diagnostics: connection state and the exact `large_image` value last sent, so the cover can be checked on-device.

### Enjoy Together — the "check internet" error was a client bug, fixed live
- Root cause: 2.6.0 built the MQTT client the one way `mqtt_client` forbids for secure websockets (`MqttServerClient.withPort` bare host + `useWebSocket = true` + `secure = true`); the `secure` flag silently turns the websocket off, so the client opened raw secure-TCP MQTT to a WebSocket-only port and the broker closed it every time, on any network. The error was then mislabelled as "check internet connection".
- Fixed construction (`wss://<host>/mqtt` URL, `useWebSocket = true`, `secure` never set), EMQX first with Mosquitto fallback, bounded timeouts, reconnect with backoff, honest errors that name the relay tried and only mention the device connection when DNS/the OS proves it offline. Connection status pill in the room UI shows relay + measured round-trip latency.
- The floating Together window is now mounted once above the router, so it stays visible all the time a room is active — while browsing, searching, opening details and picking a title — and survives every navigation. Tapping Start on it mirrors everything live: same title/poster, same position, play/pause/seek in sync (host controls, guest follows with drift correction). Re-sharing a different title clears the old state and re-syncs the guest cleanly; a paused host no longer makes the guest play.
- `tools/live_check.dart` (run with `dart tools/live_check.dart`) verifies live: MQTT host/guest round-trip over the real broker, the Discord poster chain for Harry Potter and the Deathly Hallows: Part 2, and the MovieSubLK provider live.

### MovieSubLK provider (new)
- New `MovieSubLK` provider ported from the user's JHMSub() scraper (credit to JH a.k.a Dhika kept): search, details (poster, metadata, synopsis), series episodes from `seriesData`, movie streams from server1/server2 with gdrive/telegram/subtitle downloads. Note: moviesublk.com is now a Next.js app, not Blogger — the Blogger feed returns 404, so the port reads the live search page/API/detail pages with the Blogger feed as fallback. Enable Developer options -> Load asset plugins to see it.

### Minimal professional restyle — no neon anywhere
- All glowing neon colours, violet/teal/rose gradients, colour-mixing ambient backgrounds and glow pulses from 2.6.0 are removed. New language: near-black/charcoal neutrals, white and grey text, hairline borders, one restrained desaturated slate-blue accent, low-blur neutral glass only where it aids readability. The Together orb is a minimal monochrome glass pill (draggable, subtle press scale, no glow). Poster cards keep the cinematic shape with neutral scrims and monochrome chips. Applied to home, explore, details, player, library and settings. No functionality removed.

# YumeFlix 2.6.0 — Totally New Version

### Discord cover — fixed for real
- The movie/series cover now comes from the extension's own poster, with TMDB as a real fallback: a bad extension poster no longer blocks TMDB, TMDB posters (image.tmdb.org) win over obscure CDN hosts, and artwork resolves by TMDB id first when the extension reports one.
- Movies never show "S1 E1" again — the season/episode suffix is only added for true series/anime with season and episode > 0.
- Poster URLs are normalised (http → https, //-relative and bare TMDB paths handled, data:/private/local URLs rejected with fallback to TMDB).

### Enjoy Together — reworked, realtime
- Create Room now immediately shows a movable glass "Enjoy Together" orb (breathing glow, draggable, position remembered) that stays visible while the host browses.
- Guests see a live waiting state — "Host is still finding a movie…" with live room status (browsing / picked a title / playing), presence, and a no-signal warning if the host goes silent.
- Host taps Start on the orb and both start together in sync; host keeps full play/pause/seek control, guest follows with drift correction. Glass chat button on the player, replies/emoji/image, unread dot. Leave keeps the other playing; returners get Rejoin + resync. Reconnect with backoff if the relay drops. TV still hides Together entirely.

### All-new interface
- Liquid-glass design language everywhere: glass cards/chips, colour-mixing ambient backgrounds sampled from poster art, new cinematic poster cards (rounded, glass rating/year/duration chips), new section headers, staggered entrances, shimmer loading.
- Home, Explore, Details, Library and Settings rebuilt in the new language; duplicate headers/badges and dead widgets removed; one card language and one chip language throughout.

# Changelogs - v2.8.0

### ✨ *New Features & Enhancements*

#### 🧩 Plugins & Add-on Ecosystem (thanks to [Skywave22](https://github.com/Skywave22))
- **Nuvio and streamio plugins support added thanks to [Skywave22](https://github.com/Skywave22)** – Integrated full support for Nuvio scraper plugins (running inside isolated JS workers with Cheerio and DOM polyfills) and Stremio add-ons (manifests, catalog browsing, streams, Cinemeta metadata, and OpenSubtitles v3).

#### 🎬 Media Player & Playback Engine
- **Changed player engine to libVLC** – Migrated the core playback engine to libVLC across desktop, mobile, and TV for broader codec compatibility, lower latency, and rock-solid playback stability.
- **Completely reworked the player controls** – Rebuilt the video player controls from scratch with interactive seek bar scrubbing, intro/outro skipping, next episode countdown, audio & subtitle track management, and robust background playback handling.

#### ⚡ Core Engines (Torrent & JavaScript)
- **Upgraded Torrent Engine** – Rebuilt and upgraded the embedded TorrServer across all platforms (Android, iOS, macOS, Windows, Linux) with auth token security, stripped binary sizes, and optimized torrent streaming reliability.
- **Upgraded JavaScript Engine** – Updated the embedded JS runtime to QuickJS-NG v0.17.0 with modern ECMAScript features (`Array.fromAsync`, iterator helpers), native AES decryption offloading, improved worker isolates, and enhanced polyfills for scraper plugins.

#### 📺 TV & Navigation Experience
- **TV navigation fixed** – Fully overhauled TV D-pad and gamepad focus traversal across player controls, source sheets, episode picker, catalog lists, and search views.

#### 🎨 Appearance & Window
- **Dark mode is default now** – Dark theme is now the default appearance across all devices (System and Light modes remain available under Settings › Appearance).
- **Full screen mode is persistent between sessions** – Leaving the app in full screen mode brings it back that way on subsequent launches, replacing the deprecated `--full-screen` launch flag.

#### ⬇️ Downloads
- **Download location** setting with a native folder picker; the chosen path is used when saving and locating files.
- **Queue limit** (1–10 concurrent downloads) via a native holding queue.
- **Segments per file** (1–8) using `ParallelDownloadTask` to accelerate large downloads.
- **Pause all** and **Resume all** controls in the Downloads tab.
- Multi-**select** mode (long-press / checklist) with **Delete selected**, alongside the existing per-item pause/resume/delete.

#### 🌐 Localization (i18n)
- **New Locales Added** – Added Azerbaijani (`az`) (PR #100 by @jamalkamaladdin) and Finnish (`fi`) subtitle support (PR #93 by @TheBig8).
- **Translation Updates** – Completed missing localized strings across 41 supported languages.
- 
---

### 🐞 *Bug Fixes & System Stability*
- 🛠️ **Fixed: SkyStream no longer resets monitor's brightness on Windows** – The bundled screen-brightness plugin was sending DDC/CI commands to external monitors. The plugin is now excluded from Windows builds entirely.
- 🛠️ **Cloudflare Reliability on Windows** – WebView2 now keeps its working files inside the user AppData directory on installed builds; fixed solve slot deadlock and preserved real error responses.
- 🛠️ **Player Audio & Disposal Lifecycle** – Fixed audio continuing to play after closing the player screen; guarded against memory leaks and state exceptions during player disposal.
- 🛠️ **C++17 Upgrade & Platform Builds** – Upgraded native plugins and build scripts to C++17.


### ⚙️ Improvements
- 🚀 Various performance improvements and optimizations across the app  