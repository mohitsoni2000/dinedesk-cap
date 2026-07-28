import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Derived tables state, memoized by Riverpod.
///
/// The Tables screen sits in front of the operator all shift, and every table
/// event used to re-run this arithmetic inside `build()`.

/// Table count per floor, for the floor tab badges. One pass instead of the
/// O(floors × tables) map comprehension this replaces.
final floorCountsProvider = Provider<Map<String, int>>((ref) {
  final counts = <String, int>{};
  for (final t in ref.watch(tablesProvider)) {
    counts[t.floor] = (counts[t.floor] ?? 0) + 1;
  }
  return counts;
});

/// Tab order follows the admin's configured floor display_order, not whichever
/// floor a table happens to appear under first — falls back to
/// table-occurrence order for any floor absent from the floor sync (older
/// payload shape). Never empty, so the screen always has a floor to show.
final orderedFloorNamesProvider = Provider<List<String>>((ref) {
  final present = ref.watch(tablesProvider).map((t) => t.floor).toSet();
  final ordered =
      ref.watch(floorNamesProvider).where(present.contains).toList();
  final leftover = present.difference(ordered.toSet()).toList()..sort();
  final all = [...ordered, ...leftover];
  return all.isNotEmpty ? all : const ['Ground'];
});
