import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/kot_queue_service.dart';

/// The KOTs the desk refused, held where the UI can see them.
///
/// [KotQueueService] has always quarantined these into a durable dead-letter
/// list and published them on its `rejections` stream. Nothing read either
/// one. The stream had a single subscriber that raised a toast — which is the
/// wrong instrument for this: a toast is gone in three seconds, and if the
/// phone was in a pocket or the app was backgrounded when the desk said no,
/// the operator never saw it at all. The persisted list had no reader
/// whatsoever, so a rejection also did not survive a restart.
///
/// The consequence is the worst failure this app has: the waiter believes the
/// order is with the kitchen, the kitchen never received it, and nobody finds
/// out until the customer asks where their food is.
///
/// So rejections are state, not a notification. They load from disk on start,
/// accumulate while the app runs, and stay on screen until the operator
/// explicitly clears them.
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

  /// Clears both the in-memory list and the durable one. This is the operator
  /// saying "I have dealt with it" — by re-entering the round, or by walking
  /// to the pass and telling the kitchen. It is deliberately the only action
  /// offered; see the note on retry in [RejectedKotsSheet].
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
