import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/device_info_provider.dart';
import '../models.dart';
import '../together_provider.dart';
import '../together_service.dart';
import 'together_connection_status.dart';
import 'together_waiting_state.dart';

/// The Together tab: watch the same title on two phones, in sync.
///
/// Two big choices, Create Room or Join Room. The host picks a title
/// through the normal Search flow (nothing here rebuilds search), presses
/// the floating Start button once the player is open, and the guest's
/// player follows the host — play, pause and seeks — with drift-corrected
/// sync. Chat lives on the player, not here.
///
/// No account, no URL: the room is a 6-digit code on a public relay baked
/// into the app. Phone only — the tab is hidden on TV entirely, and this
/// screen says so if it is ever reached there anyway.
class TogetherScreen extends ConsumerStatefulWidget {
  const TogetherScreen({super.key});

  @override
  ConsumerState<TogetherScreen> createState() => _TogetherScreenState();
}

class _TogetherScreenState extends ConsumerState<TogetherScreen> {
  final TextEditingController _otpController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The rejoin card needs the snapshot before the first frame that could
    // show it.
    Future.microtask(
      () => ref.read(togetherServiceProvider).loadLastRoom(),
    );
  }

  @override
  void dispose() {
    _otpController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!ok && mounted) {
        final service = ref.read(togetherServiceProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              service.error ?? kTogetherRelayUnreachableMessage,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyOtp(String otp) {
    Clipboard.setData(ClipboardData(text: otp));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Room code copied — send it to your friend')),
    );
  }

  // The existing Search route, by path: navigating there reuses the whole
  // search/details flow (no import of the router, which would be circular —
  // the router imports this screen for the Together branch).
  void _pickTitle() => context.go('/search');

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final service = ref.watch(togetherServiceProvider);
    final colorScheme = Theme.of(context).colorScheme;

    if (profile?.isTv ?? false) {
      return Scaffold(
        appBar: AppBar(title: const Text('Together')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Together watch parties are for phones — the TV stays out '
              'of the room.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final media = service.currentMedia;

    // No Start button lives on this tab (2.8.0): Start appears only on
    // the floating orb, and only once the host is actually playing the
    // title in the player. The tab's job is creating / joining the room
    // and picking a title — the orb carries the room from there.
    // The room's text is capped at a 1.3x system text scale: the room code
    // (40 pt) and the waiting copy have no room to grow into, and an
    // uncapped scale lets them blow up, clip and overlap the card below.
    // The waiting state clamps itself again where it is embedded.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Together'),
        actions: [
          if (service.isSessionActive)
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await service.leaveRoom();
                      return true;
                    }),
              child: const Text('Leave'),
            ),
        ],
      ),
      body: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (service.error != null) _errorBanner(service, colorScheme),
              if (service.reconnecting)
                _reconnectingBanner(service, colorScheme),
              if (service.phase == TogetherPhase.idle &&
                  service.lastRoom != null)
                _rejoinCard(service, colorScheme),
              if (media != null) ...[
                _mediaCard(media, colorScheme),
                const SizedBox(height: 16),
              ],
              switch (service.phase) {
                TogetherPhase.idle => _idleChoices(service),
                TogetherPhase.error => _idleChoices(service),
                TogetherPhase.pendingHost => _pendingHostCard(service),
                // The waiting state is for the GUEST only. The phase is
                // role-derived today, but the switch must not be the only
                // thing standing between a host and the guest's waiting
                // screen: a host who ever landed here would see "Host is
                // still finding a movie…" about themselves, over their own
                // "Waiting for your friend to join" card. A non-guest gets
                // the host card instead.
                TogetherPhase.waitingGuest =>
                  service.role == TogetherRole.guest
                      ? _waitingCard(service)
                      : _pendingHostCard(service),
                TogetherPhase.live => _liveCard(service),
              },
              const SizedBox(height: 24),
              Text(
                'Low-latency, drift-corrected sync — the guest follows '
                'the host’s play, pause and seeks. Each phone streams '
                'the title itself; the room only carries timing and chat.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reconnectingBanner(TogetherService service, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // Attempt count and last relay tried: the reconnect is
              // visible work, not a silent spinner.
              'Connection dropped — ${service.connectionStatusLabel}. '
              'Your room is kept.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(TogetherService service, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              service.error ?? kTogetherRelayUnreachableMessage,
              style: TextStyle(color: colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: _busy ? null : () => _run(service.retry),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _rejoinCard(TogetherService service, ColorScheme colorScheme) {
    final last = service.lastRoom!;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rejoin room ${last.otp}?',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          if (last.media != null) ...[
            const SizedBox(height: 4),
            Text(
              last.media!.title,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () => _run(service.rejoinLastRoom),
                  child: const Text('Rejoin'),
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => ref
                          .read(togetherServiceProvider)
                          .dismissLastRoom(),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mediaCard(TogetherMediaIdentity media, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          if (media.posterUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                media.posterUrl!,
                width: 56,
                height: 84,
                fit: BoxFit.cover,
                errorBuilder: (context, _, _) => const SizedBox(
                  width: 56,
                  height: 84,
                  child: Icon(Icons.movie_rounded),
                ),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                // One S/E line, never two: the title already ends with
                // ` · S{n} E{n}` for a series episode, so the label is
                // printed only when it adds something the title lacks.
                // A movie has no label at all (see
                // togetherMediaIdentityFor), so nothing is printed.
                if (media.episodeLabel != null &&
                    !media.titleCarriesEpisodeLabel)
                  Text(
                    media.episodeLabel!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _idleChoices(TogetherService service) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _choiceCard(
          icon: Icons.group_add_rounded,
          title: 'Create a room',
          subtitle:
              'Get a 6-digit code — the Enjoy Together orb appears at once, '
              'while you browse. Pick something to watch, play it, then '
              'press Start on the orb.',
          buttonLabel: 'Create room',
          onPressed: _busy ? null : () => _run(service.createRoom),
        ),
        const SizedBox(height: 14),
        _choiceCard(
          icon: Icons.group_rounded,
          title: 'Join a room',
          subtitle: 'Enter the 6-digit code your friend sent you.',
          buttonLabel: null,
          onPressed: null,
          trailing: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: 'Room code',
                    hintText: '123456',
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => service.joinRoom(_otpController.text)),
                child: const Text('Join'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _choiceCard({
    required IconData icon,
    required String title,
    required String subtitle,
    String? buttonLabel,
    VoidCallback? onPressed,
    Widget? trailing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 28, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: TextStyle(color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 14),
          if (trailing != null)
            trailing
          else if (buttonLabel != null)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onPressed,
                child: Text(buttonLabel),
              ),
            ),
        ],
      ),
    );
  }

  Widget _pendingHostCard(TogetherService service) {
    final otp = service.otp ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _otpCard(service, otp),
        const SizedBox(height: 14),
        Text(
          service.guestPresent
              ? '✓ Your friend joined — pick something to watch, play it, '
                    'then press Start on the orb.'
              : 'Waiting for your friend to join with the code…',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          service.presenceLabel,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        Center(child: TogetherConnectionStatus(service: service)),
        const SizedBox(height: 6),
        const Text(
          'The Enjoy Together orb is now floating — drag it anywhere, '
          'tap it for the code. The Start button appears on the orb once '
          'your movie is playing.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _pickTitle,
          icon: const Icon(Icons.search_rounded),
          label: const Text('Pick a title to watch'),
        ),
      ],
    );
  }

  Widget _waitingCard(TogetherService service) {
    // Live waiting state: the host's real room status over MQTT, a
    // breathing orb, a waiting clock — and a real timeout / host-left
    // state instead of a dead spinner.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _otpCard(service, service.otp ?? ''),
        const SizedBox(height: 16),
        Center(child: TogetherConnectionStatus(service: service)),
        const SizedBox(height: 20),
        TogetherGuestWaitingState(
          service: service,
          onRetry: _busy ? () {} : () => _run(service.retry),
          onLeave: _busy
              ? () {}
              : () => _run(() async {
                    await service.leaveRoom();
                    return true;
                  }),
        ),
      ],
    );
  }

  Widget _liveCard(TogetherService service) {
    final isHost = service.role == TogetherRole.host;
    final otp = service.otp ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isHost) _otpCard(service, otp),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Icon(
                service.hostGone
                    ? Icons.person_off_rounded
                    : Icons.sync_rounded,
                size: 28,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 8),
              Text(
                service.hostGone
                    ? 'The host left — you’re watching on your own now, '
                          'from the last synced position.'
                    : isHost
                    ? 'Watching together — your phone is the host. Play, '
                          'pause and seeks follow you.'
                    : 'Watching together — the host controls playback, '
                          'your player follows along.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                // Live status, straight off the wire — never a local guess.
                service.reconnecting
                    ? 'Reconnecting to the relay…'
                    : service.roomStatus.label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                service.presenceLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 10),
              Center(child: TogetherConnectionStatus(service: service)),
              if (!isHost && service.roomState != null) ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _pickTitle,
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Find this title to join playback'),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Play the same title and Together syncs you to the host '
                  'automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _otpCard(TogetherService service, String otp) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(
            'Room code',
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          Text(
            otp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              letterSpacing: 8,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _copyOtp(otp),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy code'),
          ),
          const SizedBox(height: 4),
          Text(
            'Send this code to your friend — no link, no account.',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
