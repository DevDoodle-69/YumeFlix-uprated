import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/services/discord_presence_service.dart';

void main() {
  group('Discord Rich Presence activity', () {
    test(
      'uses the poster URL as the large image with the logo as the small image',
      () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Black Clover · S1 E1',
        state: 'Asta and Yuno',
        posterUrl:
            'https://images.example.org/posters/black-clover.jpg?size=large',
        position: const Duration(seconds: 34),
        duration: const Duration(minutes: 24, seconds: 26),
        playing: true,
        nowMilliseconds: 1700000000000,
      );

      expect(activity['name'], 'YumeFlix');
      expect(activity['application_id'], DiscordPresenceService.applicationId);
      expect(activity['type'], 3);
      expect(activity['details'], 'Black Clover · S1 E1');
      expect(activity['state'], 'Asta and Yuno');
      expect(activity['assets'], {
        'large_image':
            'https://images.example.org/posters/black-clover.jpg?size=large',
        'large_text': 'Black Clover · S1 E1',
        'small_image': DiscordPresenceService.discordLargeImageKey,
        'small_text': 'YumeFlix',
      });
      expect(activity['timestamps'], {
        'start': 1699999966000,
        'end':
            1700000000000 +
            const Duration(minutes: 23, seconds: 52).inMilliseconds,
      });
    });

    test('keeps the icon asset even when poster data is unavailable', () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Example Movie',
        posterUrl: '/posters/title.jpg',
        position: Duration.zero,
        duration: Duration.zero,
        playing: false,
      );
      expect(activity.containsKey('assets'), isTrue);
      expect(activity['assets'], {
        'large_image': DiscordPresenceService.discordLargeImageKey,
        'large_text': 'YumeFlix',
      });
      expect(
        (activity['assets'] as Map<String, dynamic>).containsKey('small_image'),
        isFalse,
      );
    });

    test('supports protocol-relative extension image URLs', () {
      expect(
        DiscordPresenceService.normalizePosterUrl(
          '//cdn.example.org/poster.webp#poster',
        ),
        'https://cdn.example.org/poster.webp',
      );
    });
    test('uses provider artwork as the large image too', () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Black Clover · S1 E2',
        posterUrl: 'https://cdn.example.org/provider/black-clover-s1e2.jpg',
        position: Duration.zero,
        duration: const Duration(minutes: 24),
        playing: true,
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['large_image'],
        'https://cdn.example.org/provider/black-clover-s1e2.jpg',
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['large_text'],
        'Black Clover · S1 E2',
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['small_image'],
        DiscordPresenceService.discordLargeImageKey,
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['small_text'],
        'YumeFlix',
      );
    });

    test('upgrades an http poster to https instead of falling back', () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Example Movie',
        posterUrl: 'http://images.example.org/posters/insecure.jpg',
        position: Duration.zero,
        duration: const Duration(minutes: 90),
        playing: false,
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['large_image'],
        'https://images.example.org/posters/insecure.jpg',
      );
      expect(
        (activity['assets'] as Map<String, dynamic>)['small_image'],
        DiscordPresenceService.discordLargeImageKey,
      );
    });

    test('falls back to the logo for non-URL posters', () {
      for (final posterUrl in ['not a url', null]) {
        final activity = DiscordPresenceService.buildActivity(
          title: 'Example Movie',
          posterUrl: posterUrl,
          position: Duration.zero,
          duration: const Duration(minutes: 90),
          playing: false,
        );
        expect(activity['assets'], {
          'large_image': DiscordPresenceService.discordLargeImageKey,
          'large_text': 'YumeFlix',
        });
      }
    });

    test('truncates a long title in large_text the same way as details', () {
      final longTitle = List.filled(200, 'A').join();
      final activity = DiscordPresenceService.buildActivity(
        title: longTitle,
        posterUrl: 'https://images.example.org/posters/long-title.jpg',
        position: Duration.zero,
        duration: const Duration(minutes: 90),
        playing: false,
      );
      final assets = activity['assets'] as Map<String, dynamic>;
      expect(assets['large_text'], activity['details']);
      expect((assets['large_text'] as String).length, 128);
      expect(assets['large_text'], endsWith('…'));
    });

    test('omits playback timestamps when paused', () {
      final activity = DiscordPresenceService.buildActivity(
        title: 'Example Movie',
        position: const Duration(seconds: 20),
        duration: const Duration(minutes: 90),
        playing: false,
      );
      expect(activity.containsKey('timestamps'), isFalse);
    });
  });

  group('normalizePosterUrl', () {
    test('upgrades http to https', () {
      expect(
        DiscordPresenceService.normalizePosterUrl(
          'http://images.example.org/posters/insecure.jpg',
        ),
        'https://images.example.org/posters/insecure.jpg',
      );
    });

    test('expands a bare TMDB poster_path to its image.tmdb.org URL', () {
      expect(
        DiscordPresenceService.normalizePosterUrl(
          '/kqjL17yufvn9OVLyXYpvtyrFfak.jpg',
        ),
        'https://image.tmdb.org/t/p/w500/kqjL17yufvn9OVLyXYpvtyrFfak.jpg',
      );
    });

    test('rejects multi-segment relative paths instead of guessing a host', () {
      expect(
        DiscordPresenceService.normalizePosterUrl('/posters/title.jpg'),
        isNull,
      );
    });

    test('rejects data, blob, local and private URLs', () {
      for (final raw in [
        'data:image/png;base64,iVBORw0KGgo=',
        'blob:https://example.org/1234',
        'file:///storage/poster.jpg',
        'content://media/poster.jpg',
        'https://localhost/poster.jpg',
        'https://192.168.0.5/poster.jpg',
        'https://10.0.0.2/poster.jpg',
        'http://127.0.0.1:8080/poster.jpg',
      ]) {
        expect(
          DiscordPresenceService.normalizePosterUrl(raw),
          isNull,
          reason: raw,
        );
      }
    });
  });

  group('Discord activity title', () {
    test('never appends S/E to a movie, even with a dummy S1 E1 episode', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Harry Potter and the Deathly Hallows: Part 2',
          isSeries: false,
          season: 1,
          episode: 1,
        ),
        'Harry Potter and the Deathly Hallows: Part 2',
      );
    });

    test('appends S/E for a true series episode', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Black Clover',
          isSeries: true,
          season: 2,
          episode: 3,
        ),
        'Black Clover · S2 E3',
      );
    });

    test('omits S/E for S0/E0 placeholders', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Example Show',
          isSeries: true,
          season: 0,
          episode: 1,
        ),
        'Example Show',
      );
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Example Show',
          isSeries: true,
          season: 1,
          episode: 0,
        ),
        'Example Show',
      );
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Example Show',
          isSeries: true,
          season: 0,
          episode: 0,
        ),
        'Example Show',
      );
    });

    test('omits S/E when no episode is playing', () {
      expect(
        DiscordPresenceService.formatWatchingTitle(
          title: 'Example Show',
          isSeries: true,
        ),
        'Example Show',
      );
    });
  });

  group('effective poster selection', () {
    test('a TMDB poster wins over an extension poster from another host', () {
      expect(
        DiscordPresenceService.selectEffectivePoster(
          extensionPosterUrl: 'https://cdn.obscure-example.org/poster.jpg',
          tmdbPosterUrl: 'https://image.tmdb.org/t/p/w500/tmdb.jpg',
        ),
        'https://image.tmdb.org/t/p/w500/tmdb.jpg',
      );
    });

    test('an extension poster already on image.tmdb.org is kept', () {
      expect(
        DiscordPresenceService.selectEffectivePoster(
          extensionPosterUrl:
              'https://image.tmdb.org/t/p/w500/extension.jpg',
          tmdbPosterUrl: 'https://image.tmdb.org/t/p/w500/tmdb.jpg',
        ),
        'https://image.tmdb.org/t/p/w500/extension.jpg',
      );
    });

    test('a rejected extension URL falls through to the TMDB poster', () {
      expect(
        DiscordPresenceService.selectEffectivePoster(
          extensionPosterUrl: 'data:image/png;base64,AAAA',
          tmdbPosterUrl: 'https://image.tmdb.org/t/p/w500/tmdb.jpg',
        ),
        'https://image.tmdb.org/t/p/w500/tmdb.jpg',
      );
    });

    test('returns the extension poster when TMDB has nothing', () {
      expect(
        DiscordPresenceService.selectEffectivePoster(
          extensionPosterUrl: 'https://cdn.example.org/poster.jpg',
          tmdbPosterUrl: null,
        ),
        'https://cdn.example.org/poster.jpg',
      );
    });

    test('returns null when neither poster is usable', () {
      expect(
        DiscordPresenceService.selectEffectivePoster(
          extensionPosterUrl: 'https://192.168.0.5/poster.jpg',
          tmdbPosterUrl: null,
        ),
        isNull,
      );
    });
  });

  group('Discord account profile', () {
    test('uses the global display name and animated avatar when available', () {
      final profile = DiscordAccountProfile.fromGateway(const {
        'id': '123456789012345678',
        'username': 'yume_user',
        'global_name': 'Yume Viewer',
        'avatar': 'a_abcdef123456',
      });

      expect(profile.username, 'yume_user');
      expect(profile.displayName, 'Yume Viewer');
      expect(
        profile.avatarUrl,
        'https://cdn.discordapp.com/avatars/123456789012345678/a_abcdef123456.gif?size=128',
      );
    });

    test(
      'builds a default avatar URL when the account has no uploaded avatar',
      () {
        final profile = DiscordAccountProfile.fromGateway(const {
          'id': '123456789012345678',
          'username': 'yume_user',
          'avatar': null,
        });
        expect(
          profile.avatarUrl,
          startsWith('https://cdn.discordapp.com/embed/avatars/'),
        );
        expect(profile.displayName, 'yume_user');
      },
    );
  });
}
