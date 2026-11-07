// REFERENCE ONLY — user-supplied scraper, NOT executed by the app as-is.
// Provided by the user on 2026-11-07 to be ported into YumeFlix as a proper
// provider (search / details / streams) in the app's own JS-provider format.
// Original credit header kept intact per the author's note ("HARGAI WOY
// JANGAN DIHAPUS!" — do not remove the credit).
//
// What it does (reviewed): GETs moviesublk.com's Blogger JSON feed for
// search (title, categories, thumbnail, slug, url) and scrapes a detail page
// for poster (og:image / separator img, upscaled to s1536), metadata,
// synopsis, categories, plus stream/download links — seriesData episodes
// (stream v/v2, gdrive/telegram/subtitle) or movie vars (server1Url,
// server2Url, realGdriveDownload, realTelegramDownload, realSubDownload).
// No credentials, no eval, no exfiltration — only reads that one site.
// The port must keep the same behaviour inside the app's provider sandbox
// (no ctx/m bot globals) and map its results onto MultimediaItem /
// StreamResult, with its poster feeding the Discord cover chain too.

async function JHMSub() {
  const axios = (await import('axios')).default;
  const cheerio = await import('cheerio');
  const baseRes = { status: true, author_skrep: 'JH a.k.a Dhika', kesayangan: 'Fiony Alveria♡', data: null };

/*
- HARGAI WOY JANGAN DIHAPUS!
- Skrep by *JH a.k.a DHIKA - FIONY BOT*
- Credits to all Fiony's Bot Admin. 
- Maaf kalo kurang maksimal atau berantakan
- Hasil gabut saja xixixi. 
*/

  const pick = (...vals) => vals.find(v => v !== undefined && v !== null && v !== '') ?? '';
  const cleanLink = l => (l && String(l).trim() !== '' && String(l).trim() !== '#') ? String(l).trim() : null;

  const args = Array.from(arguments);
  const rawBotInput = typeof ctx !== 'undefined' ? pick(ctx.text) : (typeof m !== 'undefined' ? pick(m.text) : '');

  let mode = 'search';
  let target = '';

  if (args.length >= 2) {
    mode = String(args[0]).toLowerCase().trim();
    target = String(args[1]).trim();
  } else {
    const val = pick((args[0] ? String(args[0]) : rawBotInput).trim(), 'Shadow Punisher');
    const isUrl = /^https?:\/\//i.test(val);
    const isDateSlug = /^\/?\d{4}\/\d{2}\//i.test(val);
    if (isUrl ? true : (isDateSlug ? true : val.endsWith('.html'))) {
      mode = 'detail';
      target = val;
    } else if (/^search\s+/i.test(val) ? true : /^detail\s+/i.test(val)) {
      const sp = val.split(/\s+/);
      mode = sp[0].toLowerCase();
      target = sp.slice(1).join(' ');
    } else {
      mode = 'search';
      target = val;
    }
  }

  const jantung = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8',
    'Referer': 'https://www.moviesublk.com/'
  };

  try {
    if (mode === 'search') {
      if (!target) throw new Error('Masukkan kata kunci pencarian film');

      const feedUrl = `https://www.moviesublk.com/feeds/posts/default?alt=json&q=${encodeURIComponent(target)}&max-results=50`;
      const { data: res } = await axios.get(feedUrl, { headers: jantung, validateStatus: () => true });
      let entries = Array.isArray(res?.feed?.entry) ? res.feed.entry : [];

      if (!entries.length) {
        const { data: fbRes } = await axios.get('https://www.moviesublk.com/feeds/posts/default?alt=json&max-results=500', { headers: jantung, validateStatus: () => true });
        const allEntries = Array.isArray(fbRes?.feed?.entry) ? fbRes.feed.entry : [];
        const qWords = target.toLowerCase().split(/\s+/);
        entries = allEntries.filter(e => {
          const catsArr = Array.isArray(e.category) ? e.category : [];
          const hay = `${pick(e.title?.$t)} ${catsArr.map(c => c.term).join(' ')}`.toLowerCase();
          return qWords.every(w => hay.includes(w));
        });
      }

      const results = entries.map(e => {
        const title = pick(e.title?.$t?.trim(), 'Unknown');
        const linksArr = Array.isArray(e.link) ? e.link : [];
        const linkObj = linksArr.find(l => l.rel === 'alternate');
        const url = linkObj ? linkObj.href : '';
        const slug = url.replace(/^https?:\/\/(www\.)?moviesublk\.com\/?/i, '');
        const catsArr = Array.isArray(e.category) ? e.category : [];
        const cats = catsArr.map(c => c.term);

        let thumb = e.media$thumbnail?.url ? e.media$thumbnail.url.replace(/\/s\d+-c\//, '/w400-h600-c/') : '';
        if (!thumb && e.content?.$t) {
          const imgM = e.content.$t.match(/<img[^>]+src=["']([^"'>]+)["']/i);
          if (imgM) thumb = imgM[1];
        }

        const cLow = cats.map(c => c.toLowerCase());
        const isMov = ['movie', 'movies'].some(k => cLow.includes(k));
        const isDra = ['drama', 'tv series', 'cdrama', 'kdrama'].some(k => cLow.includes(k));
        const type = isMov ? 'Movie' : (isDra ? 'Drama / Series' : 'Post');

        return {
          title,
          type,
          year: e.published?.$t ? e.published.$t.substring(0, 4) : '',
          categories: cats,
          thumbnail: thumb,
          slug,
          url
        };
      });

      baseRes.data = {
        mode: 'search',
        query: target,
        total_results: results.length,
        results
      };

    } else if (mode === 'detail') {
      if (!target) throw new Error('Masukkan URL atau Slug halaman film');

      const pageUrl = /^https?:\/\//i.test(target) ? target : `https://www.moviesublk.com/${target.replace(/^\/+/, '')}`;
      const { data: html, status } = await axios.get(pageUrl, { headers: jantung, validateStatus: () => true });
      if (status >= 400 ? true : !html) throw new Error(`Gagal membuka halaman detail (HTTP ${status})`);

      const $ = cheerio.load(html);
      const postBody = $('.post-body.entry-content');
      const fullTitle = pick(
        $('h1.post-title').first().text().trim(),
        postBody.find('h1').first().text().trim(),
        $('title').text().replace('- MOVIESUB LK', '').trim()
      );

      const sepImg = postBody.find('.separator img').first().attr('src');
      const ogImg = $('meta[property="og:image"]').attr('content');
      const poster = pick(
        sepImg ? sepImg.replace(/\/s\d+(-rw)?\//, '/s1536/').replace(/\/s\d+-c\//, '/s1536/') : '',
        ogImg ? ogImg.replace(/\/s\d+-c\//, '/s1536/') : ''
      );

      const metadata = {};
      postBody.find('div').each((_, el) => {
        const bTag = $(el).children('b').first();
        if (bTag.length && $(el).children().length === 1) {
          const rawKey = bTag.text().replace(/:/g, '').trim();
          const val = $(el).text().replace(bTag.text(), '').trim();
          if (rawKey && val) {
            const cleanKey = rawKey.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_/, '').replace(/_$/, '');
            metadata[cleanKey] = val;
          }
        }
      });

      const synopsisArr = [];
      postBody.find('p').each((_, el) => {
        const pTxt = $(el).text().trim();
        if (pTxt) synopsisArr.push(pTxt);
      });

      const categories = [];
      $('.label-info a[rel="tag"]').each((_, el) => {
        const tag = $(el).text().trim();
        if (tag) categories.push(tag);
      });

      let rawSeries = null;
      let movieMedia = null;

      $('script').each((_, el) => {
        const sContent = pick($(el).html());
        const matchIdx = sContent.indexOf('const seriesData');
        if (matchIdx !== -1) {
          const startBrace = sContent.indexOf('{', matchIdx);
          if (startBrace !== -1) {
            let depth = 0, endBrace = -1;
            for (let i = startBrace; i < sContent.length; i++) {
              if (sContent[i] === '{') depth++;
              else if (sContent[i] === '}') {
                depth--;
                if (depth === 0) { endBrace = i; break; }
              }
            }
            if (endBrace !== -1) {
              try {
                const rawObjStr = sContent.substring(startBrace, endBrace + 1);
                const jsonReadyStr = rawObjStr
                  .replace(/([{,]\s*)([a-zA-Z0-9_]+)\s*:/g, '$1"$2":')
                  .replace(/,\s*([}\]])/g, '$1');
                rawSeries = JSON.parse(jsonReadyStr);
              } catch {}
            }
          }
        }

        const hasMovieVars = [
          sContent.includes('realGdriveDownload'),
          sContent.includes('server1Url'),
          sContent.includes('realTelegramDownload')
        ].some(Boolean);

        if (hasMovieVars) {
          const grabVar = name => {
            const rgx = new RegExp(`(?:const|let|var)\\s+${name}\\s*=\\s*["']([^"']*)["']`);
            const m = sContent.match(rgx);
            return m ? cleanLink(m[1]) : null;
          };

          const s1 = grabVar('server1Url');
          const s2 = grabVar('server2Url');
          const gd = grabVar('realGdriveDownload');
          const tg = grabVar('realTelegramDownload');
          const sb = grabVar('realSubDownload');

          if ([s1, s2, gd, tg, sb].some(Boolean)) {
            movieMedia = {
              stream_url: s1,
              stream_backup_url: s2,
              downloads: {
                gdrive: gd,
                telegram: tg,
                subtitle: sb
              }
            };
          }
        }
      });

      const seasons = [];
      let contentType = 'Unknown';

      if (rawSeries && typeof rawSeries === 'object') {
        contentType = 'Series';
        Object.keys(rawSeries).forEach(sKey => {
          const sObj = rawSeries[sKey];
          const epMap = sObj.episodes ? sObj.episodes : {};
          const epList = Object.keys(epMap).map(epNum => {
            const ep = epMap[epNum];
            return {
              episode: Number(epNum),
              stream_url: cleanLink(ep.v),
              stream_backup_url: cleanLink(ep.v2),
              downloads: {
                gdrive: cleanLink(ep.gd),
                telegram: cleanLink(ep.tg),
                subtitle: cleanLink(ep.sb)
              }
            };
          }).filter(e => [e.stream_url, e.stream_backup_url, e.downloads.gdrive, e.downloads.telegram].some(Boolean));

          seasons.push({
            season: Number(sKey),
            title: pick(sObj.title, `Season ${sKey}`),
            total_episodes_planned: sObj.totalEpisodes ? sObj.totalEpisodes : epList.length,
            available_episodes_count: epList.length,
            episodes: epList
          });
        });
      } else if (movieMedia) {
        contentType = 'Movie';
        seasons.push({
          season: 1,
          title: 'Full Movie',
          total_episodes_planned: 1,
          available_episodes_count: 1,
          episodes: [{
            episode: 1,
            ...movieMedia
          }]
        });
      }

      baseRes.data = {
        mode: 'detail',
        content_type: contentType,
        title: fullTitle,
        url: pageUrl,
        poster,
        metadata,
        categories,
        synopsis: synopsisArr.join('\n\n'),
        movie_links: movieMedia,
        seasons
      };

    } else {
      throw new Error('Mode tidak dikenali. Gunakan mode "search" atau "detail"');
    }

    return JSON.stringify(baseRes, null, 2);
  } catch (error) {
    return JSON.stringify({ ...baseRes, status: false, error: error.message }, null, 2);
  }
}

// SAMPLE USE — REMOVE COMMENTS
// return JHMSub('search', 'QUERY/TITLE'); // CONTOH 'AQUAMAN'
// return JHMSub('detail', 'URL/SLUG'); // INPUT URL HALAMAN DARI HASIL SEARCH
