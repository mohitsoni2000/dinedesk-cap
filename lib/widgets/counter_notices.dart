import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/counter_providers.dart';
import 'dynamic_toast.dart';

/// Shows the counter's notices ([counterNoticeProvider]) where the cashier
/// is. Each counter screen carries one; it takes no space.
///
/// A notice is shown once, by the first screen to get to it. One that
/// waited longer than [maxAge] for a counter screen (the cashier was
/// elsewhere) is dropped unseen rather than shown out of its moment.
class CounterNotices extends ConsumerWidget {
  const CounterNotices({super.key});

  static const Duration maxAge = Duration(seconds: 30);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(counterNoticeProvider);
    if (notice != null) {
      // Not while building: the toast goes in after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        // Another screen got to it first.
        if (!identical(ref.read(counterNoticeProvider), notice)) return;
        ref.read(counterNoticeProvider.notifier).state = null;
        if (DateTime.now().difference(notice.at) > maxAge) return;
        DynamicToast.show(context,
            message: notice.message,
            kind: notice.kind,
            duration: const Duration(seconds: 4));
      });
    }
    return const SizedBox.shrink();
  }
}
