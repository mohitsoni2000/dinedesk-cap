import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Derived menu state, memoized by Riverpod.
///
/// These only watch [menuProvider]/[menuCategoriesProvider], so a cart tap —
/// or any other unrelated provider change — cannot invalidate them. Doing this
/// grouping and sorting inline in a screen's `build()` meant re-sorting the
/// whole catalogue on every `+`/`-`.

/// Menu items grouped by section, each section sorted by the admin's
/// `sortOrder` with an alphabetical tiebreak.
final sortedMenuBySectionProvider =
    Provider<Map<String, List<MenuItem>>>((ref) {
  final menu = ref.watch(menuProvider);
  final sections = <String, List<MenuItem>>{};
  for (final m in menu) {
    sections.putIfAbsent(m.section, () => []).add(m);
  }
  for (final items in sections.values) {
    items.sort((a, b) {
      final cmp = a.sortOrder.compareTo(b.sortOrder);
      return cmp != 0 ? cmp : a.name.compareTo(b.name);
    });
  }
  return sections;
});

/// Tab order follows the admin's configured category order, not the order
/// categories happen to first appear in a globally item-sorted list. Falls
/// back to alphabetical for any section absent from the category sync (older
/// payload shape).
final orderedCategoryNamesProvider = Provider<List<String>>((ref) {
  final present = ref.watch(menuProvider).map((m) => m.section).toSet();
  final ordered = ref
      .watch(menuCategoriesProvider)
      .map((c) => c.name)
      .where(present.contains)
      .toList();
  final leftover = present.difference(ordered.toSet()).toList()..sort();
  return [...ordered, ...leftover];
});
