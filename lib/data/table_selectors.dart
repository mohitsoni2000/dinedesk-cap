import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

final floorCountsProvider = Provider<Map<String, int>>((ref) {
  final counts = <String, int>{};
  for (final t in ref.watch(tablesProvider)) {
    counts[t.floor] = (counts[t.floor] ?? 0) + 1;
  }
  return counts;
});

final orderedFloorNamesProvider = Provider<List<String>>((ref) {
  final present = ref.watch(tablesProvider).map((t) => t.floor).toSet();
  final ordered =
      ref.watch(floorNamesProvider).where(present.contains).toList();
  final leftover = present.difference(ordered.toSet()).toList()..sort();
  final all = [...ordered, ...leftover];
  return all.isNotEmpty ? all : const ['Ground'];
});
