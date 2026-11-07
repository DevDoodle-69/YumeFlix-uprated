import 'dart:ui';

import 'package:flutter/material.dart';

/// The glass Together chat button for the player controls row.
///
/// One round glass button (translucent + backdrop blur, so the film stays
/// visible behind it) with the chat icon and, when a message arrived while
/// the panel was closed, a glowing pulsing unread dot.
///
/// This is the reusable component for the controls row. The player screen
/// already wires a chat button into [VlcPlayerControls] via `onTogetherChat`
/// (see `vlc_player_controls.dart`, "Together chat, first in the row") —
/// the coordinator can either keep that inline button or swap it for this
/// widget (3 lines, see the 2.6.0 integration snippet). Either way the
/// button opens the existing [TogetherChatPanel] over the blurred movie;
/// chat itself still travels over the same MQTT room topic, with replies,
/// emoji and image send unchanged.
class TogetherPlayerChatButton extends StatefulWidget {
  const TogetherPlayerChatButton({
    required this.onPressed,
    this.hasUnread = false,
    this.size = 44,
    super.key,
  });

  /// Opens the glass chat panel over the video.
  final VoidCallback onPressed;

  /// A message arrived while the panel was closed: light the unread dot.
  final bool hasUnread;

  /// Button diameter. 44 matches the other player control buttons.
  final double size;

  @override
  State<TogetherPlayerChatButton> createState() =>
      _TogetherPlayerChatButtonState();
}

class _TogetherPlayerChatButtonState extends State<TogetherPlayerChatButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colorScheme.surface.withValues(alpha: 0.45),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: IconButton(
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                tooltip: 'Together chat',
                color: colorScheme.onSurface,
                padding: EdgeInsets.zero,
                onPressed: widget.onPressed,
              ),
            ),
          ),
        ),
        if (widget.hasUnread)
          Positioned(
            top: 2,
            right: 2,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                return Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: colorScheme.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.black, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: colorScheme.primary.withValues(
                          alpha: 0.5 + 0.4 * _pulse.value,
                        ),
                        blurRadius: 4 + 4 * _pulse.value,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
