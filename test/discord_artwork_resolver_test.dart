import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/core/services/discord_artwork_resolver.dart';

void main() {
  group('Discord TMDB artwork lookup', () {
    test('uses the exact TV result and its w500 poster path', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'name': 'Black Clover: Special', 'poster_path': '/special.jpg'},
            {'name': 'Black Clover', 'poster_path': '/series.jpg'},
          ],
        },
        query: 'Black Clover',
        mediaType: 'tv',
      );

      expect(poster, 'https://image.tmdb.org/t/p/w500/series.jpg');
    });

    test('uses the exact movie result instead of the first fuzzy result', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'title': 'Black Clover: Shorts', 'poster_path': '/shorts.jpg'},
            {
              'title': 'Black Clover: Sword of the Wizard King',
              'original_title': 'Black Clover',
              'poster_path': '/movie.jpg',
            },
          ],
        },
        query: 'Black Clover',
        mediaType: 'movie',
      );

      expect(poster, 'https://image.tmdb.org/t/p/w500/movie.jpg');
    });

    test('skips null or unsafe poster_path values', () {
      final poster = DiscordArtworkResolver.posterUrlFromSearchResponse(
        {
          'results': [
            {'name': 'Black Clover', 'poster_path': null},
            {'name': 'Other', 'poster_path': '/../../private.jpg'},
          ],
        },
        query: 'Black Clover',
        mediaType: 'tv',
      );

      expect(poster, isNull);
    });

    test('returns no poster for an unsupported media type', () {
      expect(
        DiscordArtworkResolver.posterUrlFromSearchResponse(
          {
            'results': [
              {'title': 'Example', 'poster_path': '/example.jpg'},
            ],
          },
          query: 'Example',
          mediaType: 'person',
        ),
        isNull,
      );
    });
  });
}
