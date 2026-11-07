import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/settings_repository.dart';
import '../../../explore/data/explore_language_provider.dart';
import 'settings_widgets.dart';

/// Lets users limit provider search to sources that advertise an audio language.
class PreferredAudioLanguageTile extends ConsumerStatefulWidget {
  const PreferredAudioLanguageTile({super.key});

  @override
  ConsumerState<PreferredAudioLanguageTile> createState() =>
      _PreferredAudioLanguageTileState();
}

class _PreferredAudioLanguageTileState
    extends ConsumerState<PreferredAudioLanguageTile> {
  String _language = 'all';

  @override
  void initState() {
    super.initState();
    _language = ref
        .read(settingsRepositoryProvider)
        .getPreferredAudioLanguage();
  }

  Future<void> _choose() async {
    final languages = ref.read(languageListProvider);
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Preferred audio language'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'all'),
            child: const ListTile(
              leading: Icon(Icons.public_rounded),
              title: Text('All available languages'),
              subtitle: Text('Do not filter search providers'),
            ),
          ),
          ...languages.map(
            (language) => SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, language.code.split('-').first),
              child: ListTile(
                leading: CircleAvatar(
                  radius: 16,
                  child: Text(language.code.substring(0, 2).toUpperCase()),
                ),
                title: Text(language.name),
                subtitle: Text(language.nativeName),
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    await ref
        .read(settingsRepositoryProvider)
        .setPreferredAudioLanguage(selected);
    if (mounted) setState(() => _language = selected);
  }

  String _label() {
    if (_language == 'all') return 'All available languages';
    LanguageOption? match;
    for (final entry in ref.read(languageListProvider)) {
      if (entry.code.split('-').first == _language) {
        match = entry;
        break;
      }
    }
    return match == null
        ? _language.toUpperCase()
        : '${match.name} · ${match.nativeName}';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsTile(
      icon: Icons.record_voice_over_rounded,
      title: 'Preferred audio language',
      subtitle: _label(),
      onTap: _choose,
    );
  }
}
