import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The current hero artwork accent. Null means use the brand seed color.
class ArtworkAccentNotifier extends Notifier<Color?> {
  @override
  Color? build() => null;

  void setAccent(Color? accent) => state = accent;
}

final artworkAccentProvider = NotifierProvider<ArtworkAccentNotifier, Color?>(
  ArtworkAccentNotifier.new,
);

/// Samples a tiny decoded version of a backdrop instead of decoding the full
/// poster-sized image. This is deliberately best-effort: the app keeps its
/// brand palette when a CDN is unavailable or the image is still loading.
Future<Color?> extractArtworkAccent(String url) async {
  if (url.isEmpty) return null;
  final stream = ResizeImage(
    CachedNetworkImageProvider(url),
    width: 32,
    height: 32,
  ).resolve(const ImageConfiguration());
  final completer = Completer<Color?>();
  late final ImageStreamListener listener;
  Timer? timeout;
  void finish(Color? color) {
    timeout?.cancel();
    stream.removeListener(listener);
    if (!completer.isCompleted) completer.complete(color);
  }

  listener = ImageStreamListener((info, _) async {
    try {
      final bytes = await info.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (bytes == null) return finish(null);
      var r = 0, g = 0, b = 0, count = 0;
      for (var i = 0; i + 3 < bytes.lengthInBytes; i += 16) {
        final alpha = bytes.getUint8(i + 3);
        if (alpha < 100) continue;
        r += bytes.getUint8(i);
        g += bytes.getUint8(i + 1);
        b += bytes.getUint8(i + 2);
        count++;
      }
      if (count == 0) return finish(null);
      final sampled = Color.fromARGB(255, r ~/ count, g ~/ count, b ~/ count);
      final hsl = HSLColor.fromColor(sampled);
      // Keep the result vivid enough to read as an accent, while avoiding neon
      // colors that make text and focus rings uncomfortable on TV.
      finish(
        hsl
            .withSaturation(hsl.saturation.clamp(0.28, 0.72))
            .withLightness(hsl.lightness.clamp(0.28, 0.52))
            .toColor(),
      );
    } catch (_) {
      finish(null);
    }
  }, onError: (_, stackTrace) => finish(null));
  timeout = Timer(const Duration(seconds: 4), () => finish(null));
  stream.addListener(listener);
  return completer.future;
}
