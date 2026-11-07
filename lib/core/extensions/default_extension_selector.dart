/// A provider identity used when choosing a first-run default.
typedef ExtensionProviderIdentity = ({
  String packageName,
  String name,
  bool isDebug,
});

/// Returns the stable ID of the installed, non-debug provider named `4K HD`.
///
/// This chooses a provider, not a stream resolution: an extension cannot
/// guarantee that every title or device has a 4K source. No extension is
/// downloaded or installed by this helper.
String? preferred4kHdProviderId(
  Iterable<ExtensionProviderIdentity> providers, {
  bool hasSavedSelection = false,
}) {
  if (hasSavedSelection) return null;

  final matches =
      providers
          .where(
            (provider) =>
                !provider.isDebug &&
                _normalizeProviderName(provider.name) == '4khd',
          )
          .map((provider) => provider.packageName.trim())
          .where((id) => id.isNotEmpty)
          .toList(growable: false)
        ..sort();

  return matches.isEmpty ? null : matches.first;
}

String _normalizeProviderName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
