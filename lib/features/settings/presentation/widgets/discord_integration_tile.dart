import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/discord_presence_service.dart';
import '../../../../core/storage/settings_repository.dart';
import 'settings_widgets.dart';

class DiscordIntegrationTile extends ConsumerStatefulWidget {
  const DiscordIntegrationTile({super.key});

  @override
  ConsumerState<DiscordIntegrationTile> createState() =>
      _DiscordIntegrationTileState();
}

class _DiscordIntegrationTileState
    extends ConsumerState<DiscordIntegrationTile> {
  bool _enabled = false;
  String _token = '';
  bool _loaded = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final repo = ref.read(settingsRepositoryProvider);
    final token = await repo.getDiscordToken() ?? '';
    if (!mounted) return;
    setState(() {
      _enabled = repo.isDiscordEnabled() && token.isNotEmpty;
      _token = token;
    });
    await DiscordPresenceService.instance.configure(
      enabled: _enabled,
      token: _token,
    );
  }

  Future<void> _openDialog() async {
    if (_saving) return;
    final controller = TextEditingController(text: _token);
    var enabled = _enabled;
    final result = await showDialog<({String token, bool enabled})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Discord Integration'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Use the same Discord authorization token you already use for this integration. Never enter your Discord password.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Discord authorization token',
                    helperText: 'Stored in the platform secure storage.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show watching activity'),
                  subtitle: const Text(
                    'Share the current movie or episode and its poster on Discord.',
                  ),
                  value: enabled,
                  onChanged: (value) => setDialogState(() => enabled = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                token: controller.text.trim(),
                enabled: enabled,
              )),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;

    setState(() => _saving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final shouldEnable = result.enabled && result.token.isNotEmpty;
      await repo.setDiscordToken(result.token);
      await repo.setDiscordEnabled(shouldEnable);
      if (!mounted) return;
      setState(() {
        _token = result.token;
        _enabled = shouldEnable;
      });
      await DiscordPresenceService.instance.configure(
        enabled: shouldEnable,
        token: result.token,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save Discord settings.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _statusText(DiscordPresenceService service) {
    if (!_enabled || _token.isEmpty) return 'Not connected';
    final profile = service.profile;
    return switch (service.connectionState) {
      DiscordConnectionState.connected when profile != null =>
        'Connected as ${profile.displayName} (@${profile.username})',
      DiscordConnectionState.connected => 'Connected to Discord',
      DiscordConnectionState.connecting => 'Connecting to Discord…',
      DiscordConnectionState.reconnecting =>
        profile == null
            ? 'Reconnecting to Discord…'
            : 'Reconnecting as ${profile.displayName}…',
      DiscordConnectionState.invalidToken =>
        'Discord rejected the authorization token',
      DiscordConnectionState.disconnected => 'Disconnected from Discord',
    };
  }

  Widget _accountAvatar(BuildContext context, DiscordAccountProfile? profile) {
    final avatarUrl = profile?.avatarUrl;
    return CircleAvatar(
      radius: 15,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      backgroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl),
      child: avatarUrl == null
          ? Icon(
              Icons.person_rounded,
              size: 17,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = DiscordPresenceService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => SettingsTile(
        icon: Icons.forum_rounded,
        title: 'Discord Integration',
        subtitle: _statusText(service),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _accountAvatar(context, service.profile),
            const SizedBox(width: 8),
            Switch.adaptive(
              value: _enabled && _token.isNotEmpty,
              onChanged: _saving ? null : (_) => _openDialog(),
            ),
          ],
        ),
        onTap: _openDialog,
      ),
    );
  }
}
