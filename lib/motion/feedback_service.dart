import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'feedback_kind.dart';

class FeedbackService {
  FeedbackService(this._ref);

  final Ref _ref;

  final List<AudioPlayer> _pool = <AudioPlayer>[];
  int _nextPlayer = 0;
  static const int _poolSize = 3;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    for (int i = 0; i < _poolSize; i++) {
      try {
        final AudioPlayer p = AudioPlayer();
        await p.setReleaseMode(ReleaseMode.stop);
        _pool.add(p);
      } catch (_) {
        // Platform or MissingPlugin exceptions shouldn't crash app startup
      }
    }
    _initialized = true;
  }

  void fire(FeedbackKind kind) {
    if (!_initialized) return;
    final hapticOn = _ref.read(hapticEnabledProvider);
    if (hapticOn) unawaited(kind.triggerHaptic());
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
    } catch (_) {}
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
  final FeedbackService service = FeedbackService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});
