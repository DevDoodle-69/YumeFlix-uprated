import 'package:flutter/material.dart';

/// The floating Start button: the host's "go live" moment.
///
/// A flat, minimal filled button in the single muted accent — no bob,
/// no halo. Used on the Together tab while a room is pending and over
/// the player once the title is open.
class TogetherStartButton extends StatefulWidget {
  const TogetherStartButton({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  State<TogetherStartButton> createState() => _TogetherStartButtonState();
}

class _TogetherStartButtonState extends State<TogetherStartButton> {
  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: widget.onPressed,
      icon: const Icon(Icons.play_arrow_rounded, size: 26),
      label: const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Start watching together',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}
