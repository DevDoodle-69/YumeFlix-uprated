import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Retained for API compatibility only. 2.7.0 removed artwork-derived
/// colour entirely: no colour wash, no surface tinting, no accent
/// sampled from poster art. The canvas is always the single neutral
/// [YumeDesign] background and the only accent is the muted slate-blue
/// there. Nothing in the app sets this provider any more, and
/// [extractArtworkAccent] always returns null.
class ArtworkAccentNotifier extends Notifier<Color?> {
  @override
  Color? build() => null;

  void setAccent(Color? accent) => state = accent;
}

final artworkAccentProvider = NotifierProvider<ArtworkAccentNotifier, Color?>(
  ArtworkAccentNotifier.new,
);

/// 2.7.0: artwork is never sampled for colour. Kept so existing call
/// sites keep compiling; always resolves to null.
Future<Color?> extractArtworkAccent(String url) async => null;
