import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yumeflix/features/together/models.dart';
import 'package:yumeflix/features/together/presentation/host_crown_icon.dart';
import 'package:yumeflix/features/together/presentation/together_member_list.dart';

/// 2.12.0 no-emoji audit: the app's own UI contains zero emoji
/// characters — in string literals AND in comments.
///
/// Scans every `.dart` file under `lib/`, excluding the generated
/// localizations (`lib/l10n/generated/`, Indic-script text with
/// zero-width joiners that naive emoji regexes flag). No other
/// exceptions: the last one (a crown-emoji character in a comment in
/// `floating_together_orb.dart`) was removed by the coordinator during
/// reconciliation, and this audit now covers that file too.
///
/// The crown the host used to carry as a character is a vector icon
/// now ([HostCrownIcon]); the widget test pins that the host identity
/// renders an icon and no `Text` widget contains the crown character.
void main() {
  group('no-emoji audit (lib)', () {
    test('no emoji code points in lib', () {
      final emoji = RegExp(
        r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{1F1E6}-\u{1F1FF}]',
        unicode: true,
      );
      final lib = Directory('lib');
      final offenders = <String>[];
      for (final entity in lib.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final path = entity.path.replaceAll('\\', '/');
        if (path.contains('lib/l10n/generated/')) continue;
        final content = entity.readAsStringSync();
        for (final match in emoji.allMatches(content)) {
          final line = content.substring(0, match.start).split('\n').length;
          offenders.add('$path:$line: ${match.group(0)}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'Emoji in app UI strings/comments:\n${offenders.join('\n')}',
      );
    });

    test('host labels carry no emoji character', () {
      const host = TogetherMember(clientId: 'host-1', role: 'host');
      expect(host.displayLabel, 'HOST');
      expect(host.displayLabel.contains('\u{1F451}'), isFalse);
      expect(
        togetherChatSenderDisplayName(
          const TogetherChatMessage(
            id: 'm1',
            senderId: 'host-1',
            senderLabel: 'Friend',
            text: 'hi',
            timestampMs: 0,
            senderRole: 'host',
          ),
          mine: false,
        ),
        'HOST',
      );
    });
  });

  group('host crown icon', () {
    testWidgets('host identity renders a crown icon, not a character', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TogetherMemberList(
              members: [
                TogetherMember(clientId: 'host-1', role: 'host'),
                TogetherMember(
                  clientId: 'guest-a',
                  role: 'guest',
                  displayName: 'Aisha',
                ),
              ],
              ownClientId: 'guest-a',
            ),
          ),
        ),
      );
      // The label is plain HOST text plus the vector crown.
      expect(find.text('HOST'), findsOneWidget);
      expect(find.text('Aisha'), findsOneWidget);
      expect(find.byType(HostCrownIcon), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      // No Text widget anywhere in the list contains the crown emoji.
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .toList();
      expect(texts.any((t) => t.contains('\u{1F451}')), isFalse);
      expect(texts.any((t) => t.contains('HOST')), isTrue);
    });

    testWidgets('HostIdentityLabel renders HOST + crown icon', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HostIdentityLabel())),
      );
      expect(find.text('HOST'), findsOneWidget);
      expect(find.byType(HostCrownIcon), findsOneWidget);
    });
  });
}
