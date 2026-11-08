/// The Together room member list: who is in the room, with names.
///
/// The host is always `HOST 👑` — crown + label, never colour alone — and
/// each guest is shown by the name they typed. The phone's own row carries
/// a small `(you)` suffix. Minimal professional styling: small grey rows,
/// no colour coding, no badges. Used by the Together screen and by the
/// floating orb's expanded card, so the two can never disagree about the
/// room.
library;

import 'package:flutter/material.dart';

import '../models.dart';

class TogetherMemberList extends StatelessWidget {
  const TogetherMemberList({
    required this.members,
    required this.ownClientId,
    super.key,
  });

  /// Members in room order (host first) — see
  /// `TogetherService.members`.
  final List<TogetherMember> members;

  /// This phone's client id, for the `(you)` suffix.
  final String ownClientId;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final member in members)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // The crown is the 👑 in the label itself (there is no
                // crown in the Material icon set): icon + label, never
                // colour alone.
                Flexible(
                  child: Text(
                    member.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                      fontWeight: member.isHost
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (member.clientId == ownClientId)
                  Text(
                    ' (you)',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
