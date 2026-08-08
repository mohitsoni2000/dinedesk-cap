import '../data/money.dart';
import '../data/providers.dart';
import '../models/server_models.dart';
import '../models/wire.dart';

/// Menu parsing, extracted from `SyncService` so it can run off the UI thread.
///
/// Everything here is top-level and takes only plain decoded JSON — no `Ref`,
/// no `this` — which is what makes it eligible for `compute()`. The catalogue
/// carries nested option, variation and addon groups, so this is by far the
/// heaviest work a sync does; on a low-end device, doing it on the main
/// isolate stalls whatever is on screen at the time.

/// What a parse produces. [categories] used to be written straight to a
/// provider mid-parse; it's returned instead so the parse stays pure.
class MenuParseResult {
  final List<MenuItem> items;
  final List<MenuCategory> categories;
  const MenuParseResult(this.items, this.categories);
}

ServerMenuItem? _tryParseItem(Map<String, dynamic> m) {
  try {
    return ServerMenuItem.fromMap(m);
  } on WireFormatException {
    // One bad row must not blank the menu. It is dropped rather than
    // rendered with guessed values — an item with an unknown veg flag
    // would paint the wrong FSSAI dot.
    return null;
  }
}

/// Entry point for `compute()`.
MenuParseResult parseMenu(Map<String, dynamic> data) {
  final rawItems = data['items'];
  final rawCategories = data['categories'];
  final optionGroupsByItem = parseOptionGroupsByItem(data);
  final variationsByItem = parseVariationsByItem(data);
  final addonGroupsByItem = parseAddonGroupsByItem(data);
  final categoryById = categoryMap(rawCategories);

  final items = <MenuItem>[];

  ServerMenuItem attach(ServerMenuItem si) => si.copyWith(
        optionGroups: optionGroupsByItem[si.id] ?? const [],
        variations: variationsByItem[si.id] ?? const [],
        addonGroups: addonGroupsByItem[si.id] ?? const [],
      );

  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is Map) {
        final m = Map<String, dynamic>.from(entry);
        final categoryId = m['category_id']?.toString();
        if (categoryId != null && categoryById.containsKey(categoryId)) {
          final category = categoryById[categoryId]!;
          m['category_name'] = category.name;
          m['category_type'] ??= category.type;
        }
        final parsed = _tryParseItem(m);
        if (parsed != null) items.add(serverMenuItemToLocal(attach(parsed)));
      }
    }
  } else if (rawCategories is List) {
    // Older payload shape: items nested under their category.
    for (final cat in rawCategories) {
      if (cat is Map) {
        final catMap = Map<String, dynamic>.from(cat);
        final catName = catMap['name']?.toString() ?? 'Other';
        final catType = catMap['type']?.toString() ?? 'food';
        final catItems = catMap['items'];
        if (catItems is List) {
          for (final entry in catItems) {
            if (entry is Map) {
              final m = Map<String, dynamic>.from(entry);
              m['category_name'] = catName;
              m['category_type'] = catType;
              final parsed = _tryParseItem(m);
              if (parsed != null) {
                items.add(serverMenuItemToLocal(attach(parsed)));
              }
            }
          }
        }
      }
    }
  }

  return MenuParseResult(items, parseCategoryOrder(rawCategories));
}

Map<String, List<ServerAddonGroup>> parseAddonGroupsByItem(
  Map<String, dynamic> data,
) {
  final rawGroupDefs = data['addon_groups'];
  final rawLinks = data['item_addon_groups'];
  final rawChoices = data['addon_group_choices'];

  final choicesByGroup = <String, List<ServerAddonChoice>>{};
  if (rawChoices is List) {
    for (final raw in rawChoices) {
      if (raw is! Map) continue;
      final c = ServerAddonChoice.fromMap(Map<String, dynamic>.from(raw));
      if (c.groupId.isEmpty) continue;
      choicesByGroup.putIfAbsent(c.groupId, () => []).add(c);
    }
  }

  final groupDefById = <String, ({String name, String selectionType})>{};
  if (rawGroupDefs is List) {
    for (final raw in rawGroupDefs) {
      if (raw is! Map) continue;
      final g = Map<String, dynamic>.from(raw);
      final id = g['id']?.toString();
      if (id == null || id.isEmpty) continue;
      groupDefById[id] = (
        name: g['name']?.toString() ?? 'Add-ons',
        selectionType: g['selection_type']?.toString() ?? 'S',
      );
    }
  }

  final byItem = <String, List<ServerAddonGroup>>{};
  if (rawLinks is List) {
    for (final raw in rawLinks) {
      if (raw is! Map) continue;
      final link = Map<String, dynamic>.from(raw);
      final itemId = link['item_id']?.toString();
      final groupId = link['group_id']?.toString();
      if (itemId == null || itemId.isEmpty) continue;
      if (groupId == null || groupId.isEmpty) continue;
      final def = groupDefById[groupId];
      if (def == null) continue;
      byItem.putIfAbsent(itemId, () => []).add(ServerAddonGroup(
            id: groupId,
            itemId: itemId,
            name: def.name,
            selectionType: def.selectionType,
            minSelect: intOr(link, 'min_select', 0),
            maxSelect: intOr(link, 'max_select', 1),
            choices: choicesByGroup[groupId] ?? const [],
          ));
    }
  }
  return byItem;
}

Map<String, List<ServerItemVariation>> parseVariationsByItem(
  Map<String, dynamic> data,
) {
  final rawVariations = data['item_variations'] ?? data['variations'];
  final byItem = <String, List<ServerItemVariation>>{};
  if (rawVariations is List) {
    for (final raw in rawVariations) {
      if (raw is! Map) continue;
      final v = ServerItemVariation.fromMap(Map<String, dynamic>.from(raw));
      if (v.itemId.isEmpty) continue;
      byItem.putIfAbsent(v.itemId, () => []).add(v);
    }
  }
  return byItem;
}

Map<String, List<ServerMenuOptionGroup>> parseOptionGroupsByItem(
  Map<String, dynamic> data,
) {
  final rawGroups = data['item_option_groups'] ?? data['option_groups'];
  final rawOptions = data['item_options'] ?? data['options'];
  final optionsByGroup = <String, List<ServerMenuOption>>{};

  if (rawOptions is List) {
    for (final raw in rawOptions) {
      if (raw is! Map) continue;
      final option = ServerMenuOption.fromMap(Map<String, dynamic>.from(raw));
      if (option.groupId.isEmpty) continue;
      optionsByGroup.putIfAbsent(option.groupId, () => []).add(option);
    }
  }

  final groupsByItem = <String, List<ServerMenuOptionGroup>>{};
  if (rawGroups is List) {
    for (final raw in rawGroups) {
      if (raw is! Map) continue;
      final group =
          ServerMenuOptionGroup.fromMap(Map<String, dynamic>.from(raw));
      if (group.itemId.isEmpty) continue;
      groupsByItem.putIfAbsent(group.itemId, () => []).add(
            group.copyWith(options: optionsByGroup[group.id] ?? const []),
          );
    }
  }
  return groupsByItem;
}

List<MenuCategory> parseCategoryOrder(dynamic rawCategories) {
  if (rawCategories is! List) return const [];
  final list = <MenuCategory>[];
  for (final raw in rawCategories) {
    if (raw is! Map) continue;
    final category = Map<String, dynamic>.from(raw);
    final name = category['name']?.toString() ?? 'Other';
    final sortOrder = int.tryParse('${category['sort_order'] ?? 0}') ?? 0;
    list.add(MenuCategory(name: name, sortOrder: sortOrder));
  }
  list.sort((a, b) {
    final cmp = a.sortOrder.compareTo(b.sortOrder);
    return cmp != 0 ? cmp : a.name.compareTo(b.name);
  });
  return list;
}

Map<String, ({String name, String type})> categoryMap(dynamic rawCategories) {
  final map = <String, ({String name, String type})>{};
  if (rawCategories is! List) return map;
  for (final raw in rawCategories) {
    if (raw is! Map) continue;
    final category = Map<String, dynamic>.from(raw);
    final id = category['id']?.toString();
    if (id == null || id.isEmpty) continue;
    map[id] = (
      name: category['name']?.toString() ?? 'Other',
      type: category['type']?.toString() ?? 'food',
    );
  }
  return map;
}

/// The price shown on a menu tile.
///
/// A zero base price with variations means "priced by variation" — show the
/// cheapest, and the detail sheet forces a choice before the line is added.
/// A zero base price with *no* variations is a real zero and stays zero.
Money effectivePrice(ServerMenuItem si) {
  if (si.basePrice.isPositive) return si.basePrice;
  final priced =
      si.variations.map((v) => v.price).where((p) => p.isPositive).toList();
  if (priced.isEmpty) return si.basePrice;
  return priced.reduce((a, b) => a < b ? a : b);
}

/// Resolves fast-add ids against the already-parsed catalogue.
///
/// Fast-add tiles used to be rebuilt straight from `ServerMenuItem.fromMap`,
/// which hardcodes empty option/variation/addon lists — those are joined
/// later, in `parseMenu`. So a Quick Add chip for a Half/Full item reported
/// no variations, skipped the detail sheet, and was added at the base price
/// with no portion for the kitchen. If the base price was zero (priced by
/// variation) it went in at 0 rupees.
///
/// Ids the catalogue doesn't know are dropped: a tile we cannot price
/// correctly must not be tappable.
List<MenuItem> resolveFastAddItems(
  List<Map<String, dynamic>> rows,
  List<MenuItem> catalogue,
) {
  final byId = <String, MenuItem>{
    for (final item in catalogue) item.id: item,
  };
  final out = <MenuItem>[];
  for (final row in rows) {
    final id = optionalStringAny(row, <String>['id', 'item_id']);
    if (id == null) continue;
    final resolved = byId[id];
    if (resolved != null) out.add(resolved);
  }
  return out;
}

MenuItem serverMenuItemToLocal(ServerMenuItem si) {
  return MenuItem(
    id: si.id,
    name: si.name,
    section: si.categoryName,
    kitchenSection: si.categoryType,
    price: effectivePrice(si),
    isVeg: si.isVeg,
    available: si.isAvailable,
    note: si.note,
    measureUnit: si.measureUnit,
    sortOrder: si.sortOrder,
    addonGroups: si.addonGroups
        .map((g) => AddonGroup(
              id: g.id,
              itemId: g.itemId,
              name: g.name,
              selectionType: g.selectionType,
              minSelect: g.minSelect,
              maxSelect: g.maxSelect,
              choices: g.choices
                  .map((c) => AddonChoice(
                        id: c.id,
                        groupId: c.groupId,
                        name: c.name,
                        price: c.price,
                      ))
                  .toList(),
            ))
        .toList(),
    optionGroups: si.optionGroups
        .map((g) => MenuOptionGroup(
              id: g.id,
              itemId: g.itemId,
              name: g.name,
              isRequired: g.isRequired,
              minSelect: g.minSelect,
              maxSelect: g.maxSelect,
              options: g.options
                  .map((o) => MenuOption(
                        id: o.id,
                        groupId: o.groupId,
                        name: o.name,
                        priceModifier: o.priceModifier,
                      ))
                  .toList(),
            ))
        .toList(),
    variations: si.variations
        .map((v) => MenuItemVariation(
              id: v.id,
              name: v.name,
              price: v.price,
            ))
        .toList(),
  );
}
