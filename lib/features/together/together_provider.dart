// Riverpod 3 moved ChangeNotifierProvider out of the main barrel file;
// it still ships in legacy.dart, which also re-exports the core types.
import 'package:flutter_riverpod/legacy.dart';

import 'together_service.dart';

/// The single Together room for the app.
///
/// Kept alive across tabs: a room created on the Together tab has to still
/// be there when the viewer comes back from Search or the player, and the
/// player hook reads the same instance the tab writes.
final togetherServiceProvider =
    ChangeNotifierProvider<TogetherService>((ref) {
      final service = TogetherService();
      ref.onDispose(service.dispose);
      return service;
    });
