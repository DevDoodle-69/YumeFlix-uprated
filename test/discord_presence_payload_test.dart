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

    test('falls back to the logo for http and non-URL posters', () {
      for (final posterUrl in [
        'http://images.example.org/posters/insecure.jpg',
        'not a url',
        null,
      ]) {
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
