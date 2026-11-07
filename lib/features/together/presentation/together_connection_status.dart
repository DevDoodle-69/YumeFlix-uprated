import 'package:flutter/material.dart';

import '../together_service.dart';

/// The Together connection status indicator: one small pill in the room UI
/// showing what the room is actually connected to.
///
/// * a green dot + `Connected via EMQX · 120 ms` once the relay answers
///   (the latency is a real measured MQTT round-trip — see
///   [TogetherService.roundTripMs] — and is only shown once measured);
/// * an amber dot + `Reconnecting… (attempt 2/5)` while a mid-room drop
///   is being retried, with the relay last tried;
/// * a grey dot + `Not connected` / `Connecting…` otherwise.
///
/// Nothing here is a guess: the relay name is the one that answered, the
/// latency is measured from heartbeat echoes, and the attempt count is the
/// service's own reconnect counter.
class TogetherConnectionStatus extends StatelessWidget {
  const TogetherConnectionStatus({required this.service, super.key});

  final TogetherService service;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connected = service.isConnected;
    final reconnecting = service.reconnecting;
    final dotColor = connected
        ? Colors.green
        : reconnecting
        ? Colors.amber
        : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              service.connectionStatusLabel,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
