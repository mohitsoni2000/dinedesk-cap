import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'feedback_kind.dart';

class FeedbackService {
  FeedbackService();

  final List<AudioPlayer> _pool = <AudioPlayer>[];
  int _nextPlayer = 0;
  static const int _poolSize = 3;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    for (int i = 0; i < _poolSize; i++) {
      final AudioPlayer p = AudioPlayer();
      await p.setReleaseMode(ReleaseMode.stop);
      _pool.add(p);
    }
    _initialized = true;
  }

  void fire(FeedbackKind kind) {
    if (!_initialized) return;
    unawaited(kind.triggerHaptic());
    final String? asset = kind.audioAsset;
    if (asset != null) {
      final AudioPlayer player = _pool[_nextPlayer];
      _nextPlayer = (_nextPlayer + 1) % _poolSize;
      unawaited(_playAsset(player, asset));
    }
  }

  Future<void> _playAsset(AudioPlayer player, String asset) async {
    try {
      await player.stop();
      await player.play(AssetSource(asset));
    } catch (_) {
      // Audio failures are non-fatal. Haptic still fired.
    }
  }

  Future<void> dispose() async {
    for (final AudioPlayer p in _pool) {
      await p.dispose();
    }
    _pool.clear();
    _initialized = false;
  }
}

final Provider<FeedbackService> feedbackServiceProvider =
    Provider<FeedbackService>((Ref ref) {
  final FeedbackService service = FeedbackService();
  ref.onDispose(() => service.dispose());
  return service;
});
