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