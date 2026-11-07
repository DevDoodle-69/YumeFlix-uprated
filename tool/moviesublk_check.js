#!/usr/bin/env node
/**
 * Runs the real MovieSubLK plugin (assets/plugins/moviesublk.js) in Node
 * against fixture HTTP responses — no live network.
 *
 * The app's own QuickJS runtime cannot be loaded under `flutter test` on
 * this Linux box (libquickjs_c_bridge_plugin.so is only produced by the
 * desktop CMake build), so the Dart test drives this script with Node
 * instead. The stubs below mirror the engine globals the plugin uses
 * (see lib/core/extensions/engine/js_engine_worker.dart):
 *   - `manifest` (the plugin.json, with baseUrl)
 *   - `http_get(url, headers)` -> Promise<{status, statusCode, body, ...}>
 *   - `MultimediaItem` / `Episode` / `StreamResult` (Object.assign classes)
 *   - `console`
 *
 * Usage: node tool/moviesublk_check.js <plugin.js> <fixtures-dir>
 * Prints one `RESULT {"call": "<name>", "env": {...}}` JSON line per call.
 * Exits non-zero if the plugin file cannot be loaded.
 */
const fs = require('fs');
const path = require('path');

const pluginPath = process.argv[2];
const fixturesDir = process.argv[3];
if (!pluginPath || !fixturesDir) {
  console.error('usage: moviesublk_check.js <plugin.js> <fixtures-dir>');
  process.exit(2);
}

function fixture(name) {
  return fs.readFileSync(path.join(fixturesDir, name), 'utf8');
}

const BASE = 'https://www.moviesublk.com';
// Exact-URL fixture map. Anything unmapped answers 404 with an empty body,
// which is how the plugin must treat a dead/unknown endpoint.
const HTTP = {
  [BASE + '/']: { status: 200, body: fixture('moviesublk_home.html') },
  [BASE + '/search?q=Aquaman']: { status: 200, body: fixture('moviesublk_search.html') },
  [BASE + '/search?q=Shadow']: { status: 200, body: fixture('moviesublk_search_empty.html') },
  [BASE + '/search?q=Punisher']: { status: 200, body: fixture('moviesublk_search_empty.html') },
  [BASE + '/search?q=zzzz-no-such-title']: { status: 200, body: fixture('moviesublk_search_empty.html') },
  [BASE + '/api/search?q=Shadow']: { status: 200, body: fixture('moviesublk_api_search_shadow.json') },
  [BASE + '/api/search?q=Punisher']: { status: 200, body: fixture('moviesublk_api_search_empty.json') },
  [BASE + '/api/search?q=zzzz-no-such-title']: { status: 200, body: fixture('moviesublk_api_search_empty.json') },
  [BASE + '/feeds/posts/default?alt=json&q=Punisher&max-results=50']: { status: 200, body: fixture('moviesublk_blogger_feed_empty.json') },
  [BASE + '/feeds/posts/default?alt=json&q=zzzz-no-such-title&max-results=50']: { status: 200, body: fixture('moviesublk_blogger_feed_empty.json') },
  [BASE + '/feeds/posts/default?alt=json&max-results=500']: { status: 200, body: fixture('moviesublk_blogger_feed_500.json') },
  [BASE + '/post/aquaman-2018-sinhala-subtitles']: { status: 200, body: fixture('moviesublk_detail_movie.html') },
  [BASE + '/post/shadow-punisher-s01-2026-sinhala']: { status: 200, body: fixture('moviesublk_detail_series.html') },
};

// ── engine globals (mirror js_engine_worker.dart) ──────────────────────────
var manifest = JSON.parse(
  fs.readFileSync(
    path.join(path.dirname(pluginPath), 'moviesublk.json'),
    'utf8',
  ),
);
globalThis.manifest = manifest;

class Actor { constructor(p) { Object.assign(this, p); } }
class Trailer { constructor(p) { Object.assign(this, p); } }
class NextAiring { constructor(p) { Object.assign(this, p); } }
class MultimediaItem {
  constructor(params) {
    Object.assign(this, {
      type: 'movie', status: 'ongoing', playbackPolicy: 'none',
      isAdult: false, streams: [], syncData: {}, ...params,
    });
  }
}
class Episode {
  constructor(params) {
    Object.assign(this, {
      season: 0, episode: 0, dubStatus: 'none', playbackPolicy: 'none',
      streams: [], ...params,
    });
  }
}
class StreamResult {
  constructor({ url, source, headers, subtitles, drmKid, drmKey, licenseUrl }) {
    this.url = url; this.source = source || 'Auto'; this.headers = headers;
    this.subtitles = subtitles; this.drmKid = drmKid;
    this.drmKey = drmKey; this.licenseUrl = licenseUrl;
  }
}
globalThis.MultimediaItem = MultimediaItem;
globalThis.Episode = Episode;
globalThis.StreamResult = StreamResult;
globalThis.Actor = Actor;
globalThis.Trailer = Trailer;
globalThis.NextAiring = NextAiring;

globalThis.http_get = function (url, headers, cb) {
  const hit = HTTP[url] || { status: 404, body: '' };
  const res = {
    status: hit.status, statusCode: hit.status, code: hit.status,
    body: hit.body, headers: {}, finalUrl: url,
  };
  const p = Promise.resolve(res);
  if (cb && typeof cb === 'function') p.then(cb);
  return p;
};
globalThis.console = console;

// ── load the plugin ─────────────────────────────────────────────────────────
const pluginSrc = fs.readFileSync(pluginPath, 'utf8');
eval(pluginSrc);
for (const fn of ['getHome', 'search', 'load', 'loadStreams']) {
  if (typeof globalThis[fn] !== 'function') {
    console.error('plugin does not export ' + fn);
    process.exit(3);
  }
}

// ── scenario calls ──────────────────────────────────────────────────────────
async function call(name, fn, args) {
  let captured = null;
  const cb = (env) => { captured = env; };
  let returned;
  try {
    returned = await fn(...args, cb);
  } catch (e) {
    console.log('RESULT ' + JSON.stringify({ call: name, env: { success: false, errorCode: 'THREW', message: String(e && e.stack || e) } }));
    return;
  }
  const env = captured || returned;
  console.log('RESULT ' + JSON.stringify({ call: name, env }));
}

(async () => {
  await call('getHome', globalThis.getHome, []);
  await call('searchAquaman', globalThis.search, ['Aquaman']);
  await call('searchShadow', globalThis.search, ['Shadow']);
  await call('searchPunisher', globalThis.search, ['Punisher']);
  await call('searchMissing', globalThis.search, ['zzzz-no-such-title']);
  await call('loadMovie', globalThis.load, [BASE + '/post/aquaman-2018-sinhala-subtitles']);
  await call('loadSeries', globalThis.load, [BASE + '/post/shadow-punisher-s01-2026-sinhala']);
  await call('loadStreamsMovie', globalThis.loadStreams, [BASE + '/post/aquaman-2018-sinhala-subtitles']);
  await call('loadStreamsEpisode', globalThis.loadStreams, [BASE + '/post/shadow-punisher-s01-2026-sinhala#mslk-s1e2']);
  await call('loadUnknown', globalThis.load, [BASE + '/post/no-such-post-12345']);
  await call('loadStreamsUnknown', globalThis.loadStreams, [BASE + '/post/no-such-post-12345']);
})().catch((e) => {
  console.error(e && e.stack || e);
  process.exit(1);
});
