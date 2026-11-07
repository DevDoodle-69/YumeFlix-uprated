(function() {
    /*
     * MovieSubLK — YumeFlix provider for moviesublk.com
     * (Sinhala-subtitled movies & dramas)
     *
     * Ported from the user's scraper JHMSub() — see
     * tools/moviesublk-jhmsub-reference.js — with credit kept intact:
     *
     *   HARGAI WOY JANGAN DIHAPUS!
     *   Skrep by *JH a.k.a DHIKA - FIONY BOT*
     *   Credits to all Fiony's Bot Admin.
     *
     * The reference only GETs moviesublk.com (Blogger JSON feed for search;
     * detail-page HTML for poster/metadata/synopsis/streams). This port keeps
     * that shape — no credentials, no eval, no exfiltration — but runs inside
     * the app's JS-provider sandbox: no axios/cheerio, no ctx/m bot globals.
     * HTTP goes through the engine's own `http_get`; the page is parsed with
     * plain string/regex work on the raw HTML (the engine has no cheerio for
     * JsBasedProvider plugins).
     *
     * LIVE SITE NOTE (verified 2026-11-07 from curl): moviesublk.com is no
     * longer a Blogger site — it is a Next.js app now. Its Blogger feed
     * (`/feeds/posts/default?alt=json`) answers 404 with the Next.js 404
     * page, on both the www and bare hosts, so a Blogger-only port returns
     * nothing live. The port therefore works against the live site first and
     * keeps the reference's Blogger feed as a fallback:
     *
     *   search  (live): GET /search?q=<query> HTML — the server-rendered
     *             result cards carry title, poster, category and slug — with
     *             GET /api/search?q=<query> JSON ({ok,total,posts:[{title,
     *             slug,url}]}) as fallback, then the Blogger feed.
     *   home    (live): GET / homepage HTML — server-rendered sections
     *             (Latest Update, Movie Collection, TV Show Collection,
     *             K-Drama, C-Drama, Sinhala Dubbed, Anime).
     *   details (live): GET /post/<slug> HTML. The old Blogger post body
     *             survives inside the page's RSC payload (same info rows,
     *             summary, `server1Url`/`server2Url`,
     *             `realGdriveDownload`/`realTelegramDownload`/
     *             `realSubDownload`, and `seriesData` seasons -> episodes
     *             with stream v/v2 + gdrive/telegram/subtitle downloads),
     *             so the reference's detail parsing applies after the RSC
     *             escapes (\" and \uXXXX) are decoded.
     *
     * Streams: server1 is the primary stream, server2 the backup. The
     * Google Drive direct-download link is exposed as a third
     * "Google Drive Download" stream — the app's download sheet is driven by
     * the same loadStreams list, so that is where it surfaces as a download
     * option. Telegram bot links and MediaFire subtitle pages are NOT
     * streams (a bot deep-link is not a file, and the subtitle URL is a
     * MediaFire landing page, not a direct .ass file), so they are left out.
     *
     * Poster / Discord cover: search/home items carry an absolute https
     * posterUrl (Blogger CDN images upscaled, TMDB/postimg URLs untouched),
     * and load() returns the detail poster upscaled to s1536 — the existing
     * Discord presence code reads item.posterUrl, so no separate poster path
     * is needed. Verified live 2026-11-07, e.g. Aquaman (2018):
     *   https://www.moviesublk.com/post/aquaman-2018-sinhala-subtitles
     *   poster: https://blogger.googleusercontent.com/img/b/R29vZ2xl/AVvXsEijJ7oGlqI9nTTJ5gGb8ve3L6ujWTZCS2iIsDAQYIEE30fmcWE2lz3bUGu4A9_8qTCzhDCOZzaOGqwFZE-cGr5pEysZFnbqd2YJIGPXJF8B4XrvUlNlkkn5gqXvGUhVOenwGOzjdVvUakXUdnJCQUBmA9_78o2JXNsss8US8YJWhT5kzjfegKfYNjQWQBxy/s320/download.jfif
     *   server1: https://drive.google.com/file/d/1SxhLyPpOqV4f_iGwqTZIp80XMu8YRCt2/preview
     *
     * Playback caveat: server1/server2 are Google Drive *preview* pages
     * (HTML embeds), not direct video files — the site itself plays them in
     * a browser iframe. Whether the in-app VLC player can open them is NOT
     * verified here and needs a live user test.
     *
     * Failures are graceful by design: a down site, an empty result, or a
     * malformed page yields an empty list / minimal item with success:true,
     * never a throw and never a false "check internet" error.
     *
     * Engine contract (see JsBasedProvider / js_engine_worker): each export
     * is invoked with Dart's args plus the engine callback appended last, so
     * search is (query, cb) — NOT (query, page, cb). The callback envelope
     * is {success:true, data:...}. The function ALSO returns the envelope:
     * the worker chains the callback onto a returned promise too, and a
     * second dispatch is ignored, so doing both is safe and covers either
     * calling convention.
     */

    var BASE_URL =
        (typeof manifest !== 'undefined' &&
            manifest &&
            manifest.baseUrl) ||
        'https://www.moviesublk.com';
    if (BASE_URL.charAt(BASE_URL.length - 1) === '/') {
        BASE_URL = BASE_URL.substring(0, BASE_URL.length - 1);
    }

    var HEADERS = {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8',
        Referer: BASE_URL + '/',
    };

    // ── small helpers ──────────────────────────────────────────────────────

    function pick() {
        for (var i = 0; i < arguments.length; i++) {
            var v = arguments[i];
            if (v !== undefined && v !== null && v !== '') return v;
        }
        return '';
    }

    function cleanLink(l) {
        if (!l) return null;
        var s = String(l).trim();
        if (s === '' || s === '#') return null;
        return s;
    }

    function httpsUrl(u) {
        if (!u) return '';
        var s = String(u).trim();
        if (s.indexOf('http://') === 0) return 'https://' + s.substring(7);
        if (s.indexOf('//') === 0) return 'https:' + s;
        return s;
    }

    function decodeEntities(s) {
        if (!s) return '';
        return String(s)
            .replace(/&amp;/g, '&')
            .replace(/&quot;/g, '"')
            .replace(/&#39;|&apos;/g, "'")
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&#(\d+);/g, function (m, code) {
                return String.fromCharCode(parseInt(code, 10));
            });
    }

    function stripTags(s) {
        if (!s) return '';
        return decodeEntities(String(s).replace(/<[^>]+>/g, ' '))
            .replace(/\s+/g, ' ')
            .trim();
    }

    // The detail page's post body lives inside the Next.js RSC payload, where
    // quotes and non-ASCII are escaped (\" \\n \uXXXX). Decoding those escapes
    // once lets the reference's plain-HTML parsing apply unchanged.
    function decodeRsc(s) {
        if (!s) return '';
        return String(s)
            .replace(/\\u([0-9a-fA-F]{4})/g, function (m, hex) {
                return String.fromCharCode(parseInt(hex, 16));
            })
            .replace(/\\"/g, '"')
            .replace(/\\\//g, '/')
            .replace(/\\n/g, '\n')
            .replace(/\\t/g, ' ')
            .replace(/\\r/g, '');
    }

    // Blogger CDN images carry a size segment right before the filename
    // (/s320/, /s320-rw/, /s72-c/ …). Rewrite it to the wanted size; every
    // other host (TMDB, postimg) is left untouched.
    function upscaleBlogger(u, size) {
        if (!u) return '';
        var s = httpsUrl(u);
        if (s.indexOf('blogger.googleusercontent.com') === -1) return s;
        return s.replace(/\/s\d+(?:-rw|-c)?\/([^/?#]+)([?#].*)?$/, function (
            m,
            file,
            rest,
        ) {
            return '/' + size + '/' + file + (rest || '');
        });
    }

    function parseYear(title, fallback) {
        var m = String(title || '').match(/\((19|20)\d{2}/);
        if (m) {
            var y = parseInt(m[0].substring(1), 10);
            if (y) return y;
        }
        if (fallback) {
            var f = parseInt(String(fallback).substring(0, 4), 10);
            if (f) return f;
        }
        return null;
    }

    function isSeriesTitle(title) {
        return /S\d{1,2}\b|Season\s*\d|\(Season/i.test(String(title || ''));
    }

    // Card category labels seen live: movie, kdrama, cdrama, drama, jdrama,
    // tvshows, anime — plus genre words (Action, Adventure, …) on some rows.
    function inferType(label, title) {
        var l = String(label || '').toLowerCase().trim();
        if (l === 'movie' || l === 'movies') return 'movie';
        if (l === 'anime') return 'anime';
        if (
            l === 'kdrama' ||
            l === 'cdrama' ||
            l === 'drama' ||
            l === 'jdrama' ||
            l === 'tvshows' ||
            l === 'tv show' ||
            l === 'tv series'
        ) {
            return 'series';
        }
        return isSeriesTitle(title) ? 'series' : 'movie';
    }

    function done(cb, data) {
        var env = { success: true, data: data };
        if (typeof cb === 'function') {
            try {
                cb(env);
            } catch (e) {}
        }
        return env;
    }

    // ── HTTP ───────────────────────────────────────────────────────────────

    // Returns {status, body} or null on any transport/HTTP failure. The
    // engine's http_get resolves to {status/statusCode/code, body, …}; a
    // network error resolves to {code:0, body:'', error:…}.
    async function fetchText(url) {
        try {
            var res = await http_get(url, HEADERS);
            if (!res) return null;
            var status = res.status || res.statusCode || res.code || 0;
            if (status < 200 || status >= 300) return null;
            return { status: status, body: res.body || '' };
        } catch (e) {
            return null;
        }
    }

    // ── shared item builder ────────────────────────────────────────────────

    function makeItem(o) {
        var year = parseYear(o.title, o.yearRaw);
        var item = new MultimediaItem({
            title: o.title || 'Unknown',
            url: o.url || '',
            posterUrl: httpsUrl(o.posterUrl || ''),
            type: o.type || inferType(o.label, o.title),
            description: o.description || undefined,
            year: year || undefined,
            tags: o.tags && o.tags.length ? o.tags : undefined,
            headers: { Referer: BASE_URL + '/' },
            provider: 'MovieSubLK',
        });
        return item;
    }

    // ── live HTML card parsing (home / search pages) ───────────────────────

    // One server-rendered card:
    //   <a href="/post/<slug>" class="block"><div …><img src alt>…
    //   <h3>Title</h3>…</div><p>category</p></a>
    function parseCards(html) {
        var items = [];
        var seen = {};
        if (!html) return items;
        var cardRe =
            /<a\s+href="\/post\/([a-z0-9][a-z0-9\-]*)"[^>]*>([\s\S]*?)<\/a>/g;
        var m;
        while ((m = cardRe.exec(html)) !== null) {
            var slug = m[1];
            if (seen[slug]) continue;
            seen[slug] = true;
            var inner = m[2];
            var img = /<img[^>]*src="(https?:\/\/[^"]+)"[^>]*>/i.exec(inner);
            var alt = /<img[^>]*alt="([^"]*)"/i.exec(inner);
            var h3 = /<h3[^>]*>([\s\S]*?)<\/h3>/i.exec(inner);
            var ps = inner.match(/<p[^>]*>([^<]{1,60})<\/p>/gi);
            var label = '';
            if (ps && ps.length) {
                var lastP = ps[ps.length - 1];
                var lm = />([^<]+)</.exec(lastP);
                if (lm) label = stripTags(lm[1]);
            }
            var title = stripTags(pick(alt && alt[1], h3 && h3[1], slug));
            if (!title) continue;
            var poster = img ? upscaleBlogger(img[1], 's600') : '';
            items.push(
                makeItem({
                    title: title,
                    url: BASE_URL + '/post/' + slug,
                    posterUrl: poster,
                    label: label,
                    tags: label ? [label] : undefined,
                }),
            );
        }
        return items;
    }

    // Home sections in document order: <h2>NAME (Available - N)</h2> then
    // that section's cards. The first section becomes "Trending" (the
    // app promotes a "Trending" row to the hero carousel).
    function parseHomeSections(html) {
        var sections = {};
        var order = [];
        if (!html) return sections;
        var sectionName = 'Trending';
        var re =
            /<h2[^>]*>([\s\S]*?)<\/h2>|<a\s+href="\/post\/([a-z0-9][a-z0-9\-]*)"[^>]*>([\s\S]*?)<\/a>/g;
        var m;
        var seen = {};
        var counts = {};
        while ((m = re.exec(html)) !== null) {
            if (m[1] !== undefined && m[1] !== '') {
                var raw = stripTags(m[1]);
                var name = raw.replace(/\s*\(Available.*$/i, '').trim();
                if (!name || /moviesublk/i.test(name)) continue;
                sectionName = name
                    .toLowerCase()
                    .replace(/(^|\s)\S/g, function (c) {
                        return c.toUpperCase();
                    });
                if (sectionName === 'Latest Update') sectionName = 'Trending';
                if (sectionName === 'Movie Collection') sectionName = 'Movies';
                if (sectionName === 'Tv Show Collection') {
                    sectionName = 'TV Shows';
                }
                if (sectionName === 'K-drama Collection') {
                    sectionName = 'K-Drama';
                }
                if (sectionName === 'C-drama Collection') {
                    sectionName = 'C-Drama';
                }
                if (sectionName === 'Sinhala Dubbed') {
                    sectionName = 'Sinhala Dubbed';
                }
                if (sectionName === 'Anime Collection') sectionName = 'Anime';
                if (!sections[sectionName]) {
                    sections[sectionName] = [];
                    order.push(sectionName);
                }
                continue;
            }
            var slug = m[2];
            if (!slug || seen[slug]) continue;
            // Cards before any <h2> belong to the first (Trending) section.
            if (!sections[sectionName]) {
                sections[sectionName] = [];
                order.push(sectionName);
            }
            if ((counts[sectionName] || 0) >= 12) continue;
            var inner = m[3] || '';
            var img = /<img[^>]*src="(https?:\/\/[^"]+)"[^>]*>/i.exec(inner);
            var alt = /<img[^>]*alt="([^"]*)"/i.exec(inner);
            var h3 = /<h3[^>]*>([\s\S]*?)<\/h3>/i.exec(inner);
            var ps = inner.match(/<p[^>]*>([^<]{1,60})<\/p>/gi);
            var label = '';
            if (ps && ps.length) {
                var lm = />(\s*[^<]+)\s*</.exec(ps[ps.length - 1]);
                if (lm) label = stripTags(lm[1]);
            }
            var title = stripTags(pick(alt && alt[1], h3 && h3[1], slug));
            if (!title) continue;
            seen[slug] = true;
            counts[sectionName] = (counts[sectionName] || 0) + 1;
            sections[sectionName].push(
                makeItem({
                    title: title,
                    url: BASE_URL + '/post/' + slug,
                    posterUrl: img ? upscaleBlogger(img[1], 's600') : '',
                    label: label,
                    tags: label ? [label] : undefined,
                }),
            );
        }
        // Drop empty sections, keep document order.
        var out = {};
        for (var i = 0; i < order.length; i++) {
            if (sections[order[i]].length) out[order[i]] = sections[order[i]];
        }
        return out;
    }

    // ── Blogger feed fallback (the reference's search, verbatim logic) ─────
    // Kept because the reference is built on it; live it 404s (the site
    // moved off Blogger), so it only runs when both live paths come back
    // empty. A 404 HTML body fails JSON.parse and lands here as [].

    function feedEntryToItem(e) {
        var title = pick(e.title && e.title.$t && e.title.$t.trim(), 'Unknown');
        var links = Array.isArray(e.link) ? e.link : [];
        var alt = null;
        for (var i = 0; i < links.length; i++) {
            if (links[i].rel === 'alternate') {
                alt = links[i];
                break;
            }
        }
        var url = alt ? alt.href : '';
        var slug = url.replace(
            /^https?:\/\/(www\.)?moviesublk\.com\/?/i,
            '',
        );
        var catsArr = Array.isArray(e.category) ? e.category : [];
        var cats = [];
        for (var j = 0; j < catsArr.length; j++) cats.push(catsArr[j].term);
        var thumb = '';
        if (e.media$thumbnail && e.media$thumbnail.url) {
            thumb = e.media$thumbnail.url.replace(
                /\/s\d+-c\//,
                '/w400-h600-c/',
            );
        }
        if (!thumb && e.content && e.content.$t) {
            var imgM = e.content.$t.match(/<img[^>]+src=["']([^"'>]+)["']/i);
            if (imgM) thumb = imgM[1];
        }
        var cLow = [];
        for (var k = 0; k < cats.length; k++) cLow.push(cats[k].toLowerCase());
        var isMov = cLow.indexOf('movie') !== -1 || cLow.indexOf('movies') !== -1;
        var isDra =
            cLow.indexOf('drama') !== -1 ||
            cLow.indexOf('tv series') !== -1 ||
            cLow.indexOf('cdrama') !== -1 ||
            cLow.indexOf('kdrama') !== -1;
        var type = isMov ? 'movie' : isDra ? 'series' : 'movie';
        if (!isMov && !isDra && isSeriesTitle(title)) type = 'series';
        return makeItem({
            title: title,
            url: url,
            posterUrl: thumb,
            type: type,
            yearRaw: e.published && e.published.$t ? e.published.$t : '',
            tags: cats,
            label: '',
        });
    }

    function parseFeedJson(body) {
        try {
            var res = JSON.parse(body);
            var entries = res && res.feed && Array.isArray(res.feed.entry)
                ? res.feed.entry
                : [];
            return entries;
        } catch (e) {
            return [];
        }
    }

    async function bloggerSearch(query) {
        var feedUrl =
            BASE_URL +
            '/feeds/posts/default?alt=json&q=' +
            encodeURIComponent(query) +
            '&max-results=50';
        var res = await fetchText(feedUrl);
        var entries = res ? parseFeedJson(res.body) : [];
        if (!entries.length) {
            var fb = await fetchText(
                BASE_URL + '/feeds/posts/default?alt=json&max-results=500',
            );
            var all = fb ? parseFeedJson(fb.body) : [];
            var qWords = query.toLowerCase().split(/\s+/);
            entries = all.filter(function (e) {
                var catsArr = Array.isArray(e.category) ? e.category : [];
                var hay = (
                    pick(e.title && e.title.$t) +
                    ' ' +
                    catsArr
                        .map(function (c) {
                            return c.term;
                        })
                        .join(' ')
                ).toLowerCase();
                return qWords.every(function (w) {
                    return hay.indexOf(w) !== -1;
                });
            });
        }
        return entries.map(feedEntryToItem);
    }

    // ── detail parsing (shared by load and loadStreams) ────────────────────

    function parseRuntimeMinutes(raw) {
        if (!raw) return null;
        var h = /(\d+)\s*h/i.exec(raw);
        var m = /(\d+)\s*m/i.exec(raw);
        var total = 0;
        if (h) total += parseInt(h[1], 10) * 60;
        if (m) total += parseInt(m[1], 10);
        return total || null;
    }

    // Reads the movie vars the reference reads, off the decoded page.
    function grabVar(clean, name) {
        var rgx = new RegExp(
            '(?:const|let|var)\\s+' + name + '\\s*=\\s*["\']([^"\']*)["\']',
        );
        var m = clean.match(rgx);
        return m ? cleanLink(m[1]) : null;
    }

    // The reference's seriesData extraction: brace-match the object literal,
    // quote bare keys, drop trailing commas, JSON.parse.
    function parseSeriesData(clean) {
        var idx = clean.indexOf('const seriesData');
        if (idx === -1) return null;
        var start = clean.indexOf('{', idx);
        if (start === -1) return null;
        var depth = 0;
        var end = -1;
        for (var i = start; i < clean.length; i++) {
            if (clean[i] === '{') depth++;
            else if (clean[i] === '}') {
                depth--;
                if (depth === 0) {
                    end = i;
                    break;
                }
            }
        }
        if (end === -1) return null;
        try {
            var rawObj = clean.substring(start, end + 1);
            var jsonReady = rawObj
                .replace(/([{,]\s*)([a-zA-Z0-9_]+)\s*:/g, '$1"$2":')
                .replace(/,\s*([}\]])/g, '$1');
            return JSON.parse(jsonReady);
        } catch (e) {
            return null;
        }
    }

    function streamResultsForEpisode(ep) {
        var out = [];
        var v = cleanLink(ep.v);
        var v2 = cleanLink(ep.v2);
        var gd = cleanLink(ep.gd);
        if (v) {
            out.push(
                new StreamResult({
                    url: v,
                    source: 'Server 1',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        if (v2) {
            out.push(
                new StreamResult({
                    url: v2,
                    source: 'Server 2',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        if (gd) {
            out.push(
                new StreamResult({
                    url: gd,
                    source: 'Google Drive Download',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        return out;
    }

    function streamResultsForMovie(movieMedia) {
        var out = [];
        if (movieMedia.stream_url) {
            out.push(
                new StreamResult({
                    url: movieMedia.stream_url,
                    source: 'Server 1',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        if (movieMedia.stream_backup_url) {
            out.push(
                new StreamResult({
                    url: movieMedia.stream_backup_url,
                    source: 'Server 2',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        var gd = movieMedia.downloads && movieMedia.downloads.gdrive;
        if (gd) {
            out.push(
                new StreamResult({
                    url: gd,
                    source: 'Google Drive Download',
                    headers: { Referer: BASE_URL + '/' },
                }),
            );
        }
        return out;
    }

    // Parses a fetched detail page into plain data. `pageUrl` is the clean
    // canonical URL (no #fragment). Returns null when the page is unusable.
    function parseDetail(html, pageUrl) {
        if (!html) return null;
        var clean = decodeRsc(html);

        var title = '';
        var ogTitle = /<meta[^>]*property="og:title"[^>]*content="([^"]*)"/i.exec(
            clean,
        );
        if (ogTitle) title = stripTags(ogTitle[1]);
        if (!title) {
            var h1 = /<h1[^>]*>([\s\S]*?)<\/h1>/i.exec(clean);
            if (h1) title = stripTags(h1[1]);
        }
        if (!title) {
            var t = /<title>([^<]*)<\/title>/i.exec(clean);
            if (t) title = stripTags(t[1]).replace(/\s*\|\s*MovieSubLK\s*$/i, '');
        }
        if (!title) return null;

        var poster = '';
        var ogImg = /<meta[^>]*property="og:image"[^>]*content="([^"]*)"/i.exec(
            clean,
        );
        if (ogImg) poster = upscaleBlogger(ogImg[1], 's1536');
        if (!poster) {
            var img = /<img[^>]*src="(https?:\/\/[^"]+)"[^>]*>/i.exec(clean);
            if (img) poster = upscaleBlogger(img[1], 's1536');
        }

        // Info rows — both the movie template
        // (<div class="info-row"><b class="label">Name:</b> Aquaman</div>)
        // and the series template
        // (<div style="margin:7px 0;"><b style="color:#f0abfc;">Name:</b> …</div>).
        var metadata = {};
        var rowRe =
            /<div[^>]*>\s*<b[^>]*>([^<>:]+):<\/b>\s*([^<]+?)\s*<\/div>/g;
        var rm;
        while ((rm = rowRe.exec(clean)) !== null) {
            var key = stripTags(rm[1])
                .toLowerCase()
                .replace(/[^a-z0-9]+/g, '_')
                .replace(/^_+|_+$/g, '');
            var val = stripTags(rm[2]);
            if (key && val && !metadata[key]) metadata[key] = val;
        }

        // Synopsis: <p> text inside the old movie-post body when present,
        // otherwise the page's meta description.
        var synopsis = '';
        var postIdx = clean.indexOf('movie-post');
        if (postIdx !== -1) {
            var region = clean.substring(postIdx, postIdx + 40000);
            var pRe = /<p[^>]*>([\s\S]*?)<\/p>/g;
            var pm;
            var paras = [];
            while ((pm = pRe.exec(region)) !== null) {
                var txt = stripTags(pm[1]);
                if (txt) paras.push(txt);
            }
            synopsis = paras.join('\n\n');
        }
        if (!synopsis) {
            var metaDesc =
                /<meta[^>]*name="description"[^>]*content="([^"]*)"/i.exec(
                    clean,
                );
            if (metaDesc) synopsis = stripTags(metaDesc[1]);
        }

        var genres = [];
        if (metadata.genre) {
            genres = metadata.genre
                .split(',')
                .map(function (g) {
                    return g.trim();
                })
                .filter(function (g) {
                    return g !== '';
                });
        }

        var score = null;
        var ratingRaw = pick(metadata.mydramalist_rating, metadata.imdb_rating);
        if (ratingRaw) {
            var parsed = parseFloat(ratingRaw);
            if (!isNaN(parsed)) score = parsed;
        }
        var duration = parseRuntimeMinutes(metadata.runtime);

        var rawSeries = parseSeriesData(clean);
        var movieMedia = null;
        var s1 = grabVar(clean, 'server1Url');
        var s2 = grabVar(clean, 'server2Url');
        var gd = grabVar(clean, 'realGdriveDownload');
        var tg = grabVar(clean, 'realTelegramDownload');
        var sb = grabVar(clean, 'realSubDownload');
        if (s1 || s2 || gd || tg || sb) {
            movieMedia = {
                stream_url: s1,
                stream_backup_url: s2,
                downloads: { gdrive: gd, telegram: tg, subtitle: sb },
            };
        }

        var seasons = [];
        var contentType = 'movie';
        if (rawSeries && typeof rawSeries === 'object') {
            contentType = 'series';
            var keys = Object.keys(rawSeries);
            for (var si = 0; si < keys.length; si++) {
                var sKey = keys[si];
                var sObj = rawSeries[sKey] || {};
                var epMap = sObj.episodes || {};
                var epNums = Object.keys(epMap);
                var epList = [];
                for (var ei = 0; ei < epNums.length; ei++) {
                    var epNum = epNums[ei];
                    var ep = epMap[epNum] || {};
                    var streams = streamResultsForEpisode(ep);
                    if (!streams.length) continue;
                    epList.push({
                        episode: parseInt(epNum, 10) || 0,
                        streams: streams,
                    });
                }
                epList.sort(function (a, b) {
                    return a.episode - b.episode;
                });
                seasons.push({
                    season: parseInt(sKey, 10) || 0,
                    title: pick(sObj.title, 'Season ' + sKey),
                    total: sObj.totalEpisodes || epList.length,
                    episodes: epList,
                });
            }
            seasons.sort(function (a, b) {
                return a.season - b.season;
            });
        } else if (movieMedia) {
            contentType = 'movie';
        } else if (isSeriesTitle(title)) {
            contentType = 'series';
        }

        return {
            title: title,
            url: pageUrl,
            poster: poster,
            synopsis: synopsis,
            metadata: metadata,
            genres: genres,
            score: score,
            duration: duration,
            yearRaw: metadata.release_year || '',
            contentType: contentType,
            seasons: seasons,
            movieMedia: movieMedia,
        };
    }

    function detailDataToItem(d) {
        var episodes = [];
        for (var i = 0; i < d.seasons.length; i++) {
            var s = d.seasons[i];
            for (var j = 0; j < s.episodes.length; j++) {
                var ep = s.episodes[j];
                episodes.push(
                    new Episode({
                        name: 'Episode ' + ep.episode,
                        // Opaque token for loadStreams: the player hands the
                        // episode URL straight back to loadStreams, which
                        // re-fetches this page and picks the episode out.
                        url:
                            d.url +
                            '#mslk-s' +
                            s.season +
                            'e' +
                            ep.episode,
                        season: s.season,
                        episode: ep.episode,
                        description:
                            s.title + ' — Episode ' + ep.episode,
                        posterUrl: d.poster || undefined,
                        headers: { Referer: BASE_URL + '/' },
                        streams: ep.streams,
                    }),
                );
            }
        }
        var item = new MultimediaItem({
            title: d.title,
            url: d.url,
            posterUrl: d.poster || '',
            type: d.contentType,
            description: d.synopsis || undefined,
            year: parseYear(d.title, d.yearRaw) || undefined,
            score: d.score || undefined,
            duration: d.duration || undefined,
            status: 'completed',
            tags: d.genres.length ? d.genres : undefined,
            headers: { Referer: BASE_URL + '/' },
            provider: 'MovieSubLK',
            episodes: episodes.length ? episodes : undefined,
            streams: d.movieMedia
                ? streamResultsForMovie(d.movieMedia)
                : undefined,
        });
        return item;
    }

    // Accepts a full URL, a /post/<slug> path, a bare slug, or an episode
    // token URL (detail URL + #mslk-sNeM). Returns {pageUrl, season, episode}
    // with the fragment stripped for fetching.
    function resolveDetailTarget(target) {
        var t = String(target || '').trim();
        var season = null;
        var episode = null;
        var frag = /#mslk-s(\d+)e(\d+)$/.exec(t);
        if (frag) {
            season = parseInt(frag[1], 10);
            episode = parseInt(frag[2], 10);
            t = t.substring(0, frag.index);
        }
        var pageUrl;
        if (/^https?:\/\//i.test(t)) {
            pageUrl = t;
        } else {
            var path = t.replace(/^\/+/, '');
            if (path.indexOf('post/') !== 0) path = 'post/' + path;
            pageUrl = BASE_URL + '/' + path;
        }
        return { pageUrl: pageUrl, season: season, episode: episode };
    }

    // ── exports ────────────────────────────────────────────────────────────

    async function getHome(cb) {
        try {
            var res = await fetchText(BASE_URL + '/');
            if (res) {
                var sections = parseHomeSections(res.body);
                if (Object.keys(sections).length) {
                    return done(cb, sections);
                }
            }
            // Fallback: latest Blogger entries as a single row.
            var fb = await fetchText(
                BASE_URL + '/feeds/posts/default?alt=json&max-results=20',
            );
            var entries = fb ? parseFeedJson(fb.body) : [];
            var items = entries.map(feedEntryToItem);
            return done(cb, items.length ? { Latest: items } : {});
        } catch (e) {
            return done(cb, {});
        }
    }

    async function search(query, cb) {
        try {
            var q = String(query || '').trim();
            if (!q) return done(cb, []);
            // Live path: the server-rendered search page (cards carry the
            // poster + category, which the JSON API does not).
            var res = await fetchText(
                BASE_URL + '/search?q=' + encodeURIComponent(q),
            );
            if (res) {
                var items = parseCards(res.body);
                if (items.length) return done(cb, items);
            }
            // Fallback 1: the JSON search API (titles + URLs, no posters —
            // load() fills the poster in when the user opens a result).
            var api = await fetchText(
                BASE_URL + '/api/search?q=' + encodeURIComponent(q),
            );
            if (api) {
                try {
                    var parsed = JSON.parse(api.body);
                    var posts = parsed && Array.isArray(parsed.posts)
                        ? parsed.posts
                        : [];
                    var apiItems = posts.map(function (p) {
                        return makeItem({
                            title: p.title || 'Unknown',
                            url: p.url || BASE_URL + '/post/' + (p.slug || ''),
                            posterUrl: '',
                            label: '',
                        });
                    });
                    if (apiItems.length) return done(cb, apiItems);
                } catch (e) {}
            }
            // Fallback 2: the reference's Blogger feed search.
            var feedItems = await bloggerSearch(q);
            return done(cb, feedItems);
        } catch (e) {
            return done(cb, []);
        }
    }

    async function load(url, cb) {
        try {
            var target = resolveDetailTarget(url);
            var res = await fetchText(target.pageUrl);
            if (!res) {
                return done(
                    cb,
                    new MultimediaItem({
                        title: 'MovieSubLK',
                        url: target.pageUrl,
                        posterUrl: '',
                        type: 'movie',
                        description:
                            'Details could not be loaded. The MovieSubLK page did not respond.',
                        headers: { Referer: BASE_URL + '/' },
                        provider: 'MovieSubLK',
                    }),
                );
            }
            var d = parseDetail(res.body, target.pageUrl);
            if (!d) {
                return done(
                    cb,
                    new MultimediaItem({
                        title: 'MovieSubLK',
                        url: target.pageUrl,
                        posterUrl: '',
                        type: 'movie',
                        description:
                            'Details could not be loaded. The MovieSubLK page could not be read.',
                        headers: { Referer: BASE_URL + '/' },
                        provider: 'MovieSubLK',
                    }),
                );
            }
            return done(cb, detailDataToItem(d));
        } catch (e) {
            return done(
                cb,
                new MultimediaItem({
                    title: 'MovieSubLK',
                    url: String(url || ''),
                    posterUrl: '',
                    type: 'movie',
                    description: 'Details could not be loaded.',
                    headers: { Referer: BASE_URL + '/' },
                    provider: 'MovieSubLK',
                }),
            );
        }
    }

    async function loadStreams(url, cb) {
        try {
            var target = resolveDetailTarget(url);
            var res = await fetchText(target.pageUrl);
            if (!res) return done(cb, []);
            var d = parseDetail(res.body, target.pageUrl);
            if (!d) return done(cb, []);
            if (
                target.season !== null &&
                target.episode !== null &&
                d.seasons.length
            ) {
                for (var i = 0; i < d.seasons.length; i++) {
                    if (d.seasons[i].season !== target.season) continue;
                    for (var j = 0; j < d.seasons[i].episodes.length; j++) {
                        if (d.seasons[i].episodes[j].episode === target.episode) {
                            return done(cb, d.seasons[i].episodes[j].streams);
                        }
                    }
                }
                return done(cb, []);
            }
            if (d.movieMedia) {
                return done(cb, streamResultsForMovie(d.movieMedia));
            }
            if (d.seasons.length) {
                // No episode selected: first available episode's streams.
                for (var s = 0; s < d.seasons.length; s++) {
                    if (d.seasons[s].episodes.length) {
                        return done(cb, d.seasons[s].episodes[0].streams);
                    }
                }
            }
            return done(cb, []);
        } catch (e) {
            return done(cb, []);
        }
    }

    // Export to global scope for the namespaced IIFE capture.
    globalThis.getHome = getHome;
    globalThis.search = search;
    globalThis.load = load;
    globalThis.loadStreams = loadStreams;
})();
