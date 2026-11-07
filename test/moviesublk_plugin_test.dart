import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/domain/entity/multimedia_item.dart';
import 'package:yumeflix/core/extensions/models/extension_plugin.dart';

// MovieSubLK provider tests.
//
// The plugin itself is JavaScript (assets/plugins/moviesublk.js) and runs
// in the app inside the QuickJS engine (JsBasedProvider). That engine's
// native library is only produced by the desktop CMake build, so it cannot
// be loaded under `flutter test` on this machine — the spike in
// test/spike_qjs_test.dart failed with "Failed to load dynamic library
// 'libquickjs_c_bridge_plugin.so'". The JS is therefore exercised through
// Node (tool/moviesublk_check.js), which loads the real plugin file with
// stubs mirroring the engine globals (manifest, http_get, MultimediaItem /
// Episode / StreamResult) and fixture HTTP responses — no live network.
// The node-driven tests skip, rather than fail, on machines without node.
//
// Fixtures are trimmed excerpts of the real pages fetched from
// moviesublk.com on 2026-11-07 (same markup, same URLs, same titles/slugs).

bool _nodeAvailable() {
  try {
    final result = Process.runSync('node', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<Map<String, Map<String, dynamic>>> _runPluginDriver() async {
  final result = await Process.run('node', [
    'tool/moviesublk_check.js',
    'assets/plugins/moviesublk.js',
    'test/fixtures',
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'moviesublk_check.js failed: ${result.stderr}',
  );
  final calls = <String, Map<String, dynamic>>{};
  for (final line in (result.stdout as String).split('\n')) {
    if (!line.startsWith('RESULT ')) continue;
    final decoded = jsonDecode(line.substring('RESULT '.length))
        as Map<String, dynamic>;
    calls[decoded['call'] as String] =
        Map<String, dynamic>.from(decoded['env'] as Map);
  }
  expect(calls, isNotEmpty, reason: 'driver printed no RESULT lines');
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nodeAvailable = _nodeAvailable();
  const nodeSkip =
      'node is not installed, so the MovieSubLK JS driver cannot run '
      '(see tool/moviesublk_check.js)';

  group('MovieSubLK manifest + plugin file', () {
    test('manifest parses as an ExtensionPlugin', () {
      final raw = File(
        'assets/plugins/moviesublk.json',
      ).readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final plugin = ExtensionPlugin.fromJson(json, 'LocalAssets');
      expect(plugin.packageName, 'com.moviesublk.yumeflix');
      expect(plugin.name, 'MovieSubLK');
      expect(plugin.version, 1);
      expect(plugin.manifest['baseUrl'], 'https://www.moviesublk.com');
      expect(plugin.providers, isNull);
      expect(plugin.categories, containsAll(['Movie', 'Series']));
    });

    test('plugin files are bundled assets (pubspec registration)', () async {
      // rootBundle only serves files listed under flutter/assets in
      // pubspec.yaml — this fails if the registration entry is missing.
      final manifestRaw = await rootBundle.loadString(
        'assets/plugins/moviesublk.json',
      );
      final manifestJson = jsonDecode(manifestRaw) as Map<String, dynamic>;
      expect(manifestJson['packageName'], 'com.moviesublk.yumeflix');
      final pluginSrc = await rootBundle.loadString(
        'assets/plugins/moviesublk.js',
      );
      expect(pluginSrc, contains('globalThis.loadStreams = loadStreams;'));
    });

    test('plugin file keeps the author credit and the engine contract', () {
      final src = File('assets/plugins/moviesublk.js').readAsStringSync();
      expect(src, contains('JH a.k.a DHIKA'));
      expect(src, contains('globalThis.getHome = getHome;'));
      expect(src, contains('globalThis.search = search;'));
      expect(src, contains('globalThis.load = load;'));
      expect(src, contains('globalThis.loadStreams = loadStreams;'));
      // Sandbox-only: no axios/cheerio usage, no bot globals, no require/eval.
      // (The header comment names them in prose, so match usage patterns.)
      expect(src, isNot(contains('axios.get')));
      expect(src, isNot(contains('cheerio.load')));
      expect(src, isNot(contains('require(')));
      expect(src, isNot(contains('eval(')));
    });
  });

  group(
    'MovieSubLK plugin (Node driver, fixture HTTP)',
    () {
      late Map<String, Map<String, dynamic>> calls;

      setUpAll(() async {
        calls = await _runPluginDriver();
      });

      Map<String, dynamic> env(String call) {
        final e = calls[call];
        expect(e, isNotNull, reason: 'driver printed no $call result');
        expect(e!['success'], isTrue, reason: '$call was not success:true');
        return e;
      }

      test('getHome returns the live sections with https posters', () {
        final data = env('getHome')['data'] as Map<String, dynamic>;
        expect(data.keys, containsAll(['Trending', 'Movies']));
        final trending = data['Trending'] as List;
        expect(trending, hasLength(2));
        expect(trending[0]['title'], startsWith('Aquaman (2018)'));
        expect(trending[0]['type'], 'movie');
        expect(trending[0]['year'], 2018);
        expect(trending[0]['posterUrl'], startsWith('https://'));
        expect(trending[0]['posterUrl'], contains('/s600/'));
        expect(trending[1]['type'], 'series');
        expect(trending[1]['year'], 2026);
        expect((data['Movies'] as List).single['title'], contains('Svaha'));
      });

      test('search uses the live search page (posters included)', () {
        final items = env('searchAquaman')['data'] as List;
        expect(items, hasLength(2));
        final aquaman = items[0] as Map<String, dynamic>;
        expect(aquaman['title'], startsWith('Aquaman (2018)'));
        expect(
          aquaman['url'],
          'https://www.moviesublk.com/post/aquaman-2018-sinhala-subtitles',
        );
        expect(aquaman['posterUrl'], startsWith('https://'));
        expect(aquaman['posterUrl'], contains('/s600/'));
        expect(aquaman['year'], 2018);
        expect(items[1]['type'], 'series');
      });

      test('search falls back to the JSON API when the page has no cards',
          () {
        final items = env('searchShadow')['data'] as List;
        expect(items, hasLength(3));
        expect(items[0]['title'], contains('Shadow Punisher'));
        expect(items[0]['type'], 'series');
        expect(items[0]['year'], 2026);
        // The API carries no posters; load() fills them in later.
        expect(items[0]['posterUrl'], isEmpty);
      });

      test('search falls back to the Blogger feed 500-item filter', () {
        final items = env('searchPunisher')['data'] as List;
        expect(items, hasLength(1));
        final item = items.single as Map<String, dynamic>;
        expect(item['title'], contains('Shadow Punisher'));
        expect(item['type'], 'series');
        expect(item['year'], 2026);
        // The reference's thumbnail transform, kept verbatim in the fallback.
        expect(item['posterUrl'], contains('/w400-h600-c/'));
      });

      test('search with no match is a clean empty list, not an error', () {
        final items = env('searchMissing')['data'] as List;
        expect(items, isEmpty);
      });

      test('load() maps a movie detail page onto MultimediaItem', () {
        final data = env('loadMovie')['data'] as Map<String, dynamic>;
        final item = MultimediaItem.fromJson(data);
        expect(item.title, startsWith('Aquaman (2018)'));
        expect(item.contentType, MultimediaContentType.movie);
        expect(item.year, 2018);
        expect(item.duration, 143); // "2h 23m"
        expect(item.tags, containsAll(['Action', 'Adventure', 'Fantasy']));
        // Detail poster: absolute https, upscaled to s1536 — this is what
        // the Discord cover chain reads (item.posterUrl).
        expect(item.posterUrl, startsWith('https://'));
        expect(item.posterUrl, contains('/s1536/'));
        expect(item.description, isNotNull);
        expect(item.description, isNotEmpty);
        expect(item.episodes, isNull);
        final streams = item.streams!;
        expect(
          streams.map((s) => s.source),
          ['Server 1', 'Google Drive Download'],
        );
        expect(
          streams.first.url,
          'https://drive.google.com/file/d/1SxhLyPpOqV4f_iGwqTZIp80XMu8YRCt2/preview',
        );
        expect(streams.last.url, contains('drive.usercontent.google.com'));
        // Telegram bot links and MediaFire subtitle pages are not streams.
        for (final s in streams) {
          expect(s.url, isNot(contains('t.me')));
          expect(s.url, isNot(contains('mediafire')));
        }
      });

      test('load() maps a series detail page onto episodes', () {
        final data = env('loadSeries')['data'] as Map<String, dynamic>;
        final item = MultimediaItem.fromJson(data);
        expect(item.contentType, MultimediaContentType.series);
        expect(item.year, 2026);
        expect(item.score, 8.2);
        expect(item.tags, containsAll(['Mystery', 'Fantasy', 'Historical']));
        expect(item.posterUrl, contains('/s1536/'));
        expect(item.description, isNotEmpty);
        final episodes = item.episodes!;
        expect(episodes, hasLength(30));
        final ep2 = episodes[1];
        expect(ep2.season, 1);
        expect(ep2.episode, 2);
        expect(
          ep2.url,
          'https://www.moviesublk.com/post/shadow-punisher-s01-2026-sinhala#mslk-s1e2',
        );
        expect(ep2.streams!.first.source, 'Server 1');
        expect(
          ep2.streams!.first.url,
          contains('15gzMsldodwMrG8SbjBDO_KYh3y4kUpUC'),
        );
      });

      test('loadStreams returns the movie servers', () {
        final streams = env('loadStreamsMovie')['data'] as List;
        expect(streams, hasLength(2));
        expect(streams[0]['source'], 'Server 1');
        expect(streams[0]['url'], contains('/preview'));
        expect(streams[1]['source'], 'Google Drive Download');
      });

      test('loadStreams resolves an episode token to that episode', () {
        final streams = env('loadStreamsEpisode')['data'] as List;
        expect(streams, isNotEmpty);
        expect(streams[0]['source'], 'Server 1');
        expect(
          streams[0]['url'],
          contains('15gzMsldodwMrG8SbjBDO_KYh3y4kUpUC'),
        );
      });

      test('unknown pages fail gracefully (no throw, no false error)', () {
        final item = env('loadUnknown')['data'] as Map<String, dynamic>;
        expect(item['title'], 'MovieSubLK');
        expect(item['description'], contains('could not be loaded'));
        expect(env('loadStreamsUnknown')['data'], isEmpty);
      });
    },
    skip: nodeAvailable ? null : nodeSkip,
  );
}
