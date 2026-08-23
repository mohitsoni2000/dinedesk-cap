import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/kot_queue_service.dart';

class RejectedKotsNotifier extends StateNotifier<List<RejectedKot>> {
  RejectedKotsNotifier(this._queue) : super(const <RejectedKot>[]) {
    _load();
    _sub = _queue.rejections.listen((rejected) {
      if (!mounted) return;
      state = <RejectedKot>[...state, rejected];
    });
  }

  final KotQueueService _queue;
  StreamSubscription<RejectedKot>? _sub;

  Future<void> _load() async {
    final stored = await _queue.rejectedKots();
    if (!mounted || stored.isEmpty) return;
    state = stored;
  }

  Future<void> acknowledgeAll() async {
    state = const <RejectedKot>[];
    await _queue.clearRejected();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final rejectedKotsProvider =
    StateNotifierProvider<RejectedKotsNotifier, List<RejectedKot>>(
  (ref) => RejectedKotsNotifier(ref.read(kotQueueProvider)),
);
