import 'package:flutter/material.dart';

import '../../../core/theme/design_tokens.dart';

/// The Together Start run button: the host's "go live" moment, kept
/// deliberately small.
///
/// A compact dark pill — [YumeDesign.surfaceRaised] fill, hairline
/// border, muted slate-blue play icon, white 13 pt "Start" label — no
/// red, no underline, no glow, no large filled block. It renders only
/// while the service says the room is ready
/// ([TogetherService.startState] == `ready`): a title picked, a player
/// open, and the movie actually playing. The moment it is tapped the
/// room goes live and the button vanishes, replaced by the tiny Live
/// indicator; pausing or leaving the player hides it again until
/// playback resumes.
///
/// The single Start control in the app (2.9.0): the floating orb's
/// collapsed pill in the `ready` state IS this widget, and no other
/// Start button exists anywhere — the orb's expanded card never renders
/// one. Keep it that way: a second Start is how the user ended up seeing
/// two at once in the player.
///
/// The pill looks compact but its hit target is a full 44 dp tall
/// (13 dp vertical padding around the 18 dp icon), so it is tappable
/// without being big.
class TogetherStartButton extends StatelessWidget {
  const TogetherStartButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Start watching together',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: YumeDesign.pillRadius,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: YumeDesign.surfaceRaised,
              borderRadius: YumeDesign.pillRadius,
              border: Border.all(color: YumeDesign.hairlineStrong),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.play_arrow_rounded,
                  size: 18,
                  color: YumeDesign.accentLight,
                ),
                SizedBox(width: 6),
                Text(
                  'Start',
                  style: TextStyle(
                    color: YumeDesign.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
