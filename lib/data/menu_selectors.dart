import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

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
