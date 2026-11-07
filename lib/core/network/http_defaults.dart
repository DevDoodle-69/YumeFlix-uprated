/// Shared HTTP defaults for the app's network and playback layers.
///
/// Many CDNs tie the signed playback URL to the User-Agent that resolved it,
/// or simply 403 any non-browser UA. If the player then fetches the stream
/// with the engine's built-in UA — or the resolver fetches with Dio's default
/// `Dio/xx` — the origin sees a different identity and rejects playback even
/// though resolution succeeded. Engine defaults also differ per platform
/// build, so the same stream can play on one desktop OS and 403 on another.
/// One browser UA across resolve and playback removes both.
library;

/// Current-ish desktop Chrome UA. Picked because it's the least likely to be
/// filtered by CDNs and matches what most scraping plugins already send.
const String kDefaultBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Conservative browser identities used only when a legitimate provider needs
/// a platform-compatible request header. Keep resolver and player on the same
/// identity for a stream; do not rotate per request, which breaks signed URLs.
const List<String> kCompatibleBrowserUserAgents = <String>[
  kDefaultBrowserUserAgent,
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
];
