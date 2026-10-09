/// Puts a parked draft back against what the desk sells TODAY. Pure: no I/O,
/// no providers, nothing is changed; the answer is a new cart (or ticket
/// sale) plus the two lists the "Needs attention" summary shows.
///
/// A draft can be days old, so the menu may have moved on:
///
/// - an item or ticket type that is gone, or an item that is switched off, is
///   **dropped** (and so is an item that is now sold by weight, or no longer
///   is: its saved quantity would price it at nothing);
/// - a variation, option or add-on that is gone is **dropped** from its line,
///   and the line stays;
/// - a base, variation, option or add-on price that changed is **kept at the
///   current price** and the line is listed as **repriced**.
///
/// Nothing is dropped silently and nothing keeps a stale price.
library;

import '../data/currency.dart';
import '../data/money.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../models/parked_draft.dart';
import '../models/token.dart';

/// Why something could not come back.
enum DropIssue {
  itemRemoved,
  itemUnavailable,

  /// The item is now sold by weight (or no longer is).
  itemChanged,
  variationRemoved,
  optionRemoved,
  addonRemoved,
  typeRemoved,
}

/// Something that did not come back: a whole item or ticket type, or one
/// variation, option or add-on of a line that did.
final class DroppedEntry {
  const DroppedEntry({
    required this.issue,
    required this.itemName,
    this.detail,
    this.qty = 0,
  });

  final DropIssue issue;

  /// The item (or ticket type) it belonged to.
  final String itemName;

  /// The variation, option or add-on that went; null when the whole item or
  /// type did.
  final String? detail;

  /// How many were lost with a whole item or type (0 for a single choice).
  final int qty;

  String get _who => qty > 1 ? '$itemName ×$qty' : itemName;

  /// For the "Needs attention" list.
  String get message => switch (issue) {
        DropIssue.itemRemoved => '$_who — no longer on the menu',
        DropIssue.itemUnavailable => '$_who — not available right now',
        DropIssue.itemChanged =>
          '$_who — is sold differently now, add it again',
        DropIssue.typeRemoved => '$_who — no longer on sale',
        DropIssue.variationRemoved ||
        DropIssue.optionRemoved ||
        DropIssue.addonRemoved =>
          '$itemName — $detail is no longer offered',
      };
}

/// A line that came back at a different price.
final class RepricedEntry {
  const RepricedEntry({
    required this.itemName,
    required this.was,
    required this.now,
  });

  final String itemName;

  /// What one unit cost, for the parts that came back, when parked.
  final Money was;

  /// What one unit costs now.
  final Money now;

  String get message =>
      '$itemName — ${formatRupeesCompact(was)} → ${formatRupeesCompact(now)} '
      'each';
}

/// A parked draft after it has been put back against today's menu or ticket
/// types.
sealed class ResolvedDraft {
  const ResolvedDraft({required this.dropped, required this.repriced});

  final List<DroppedEntry> dropped;
  final List<RepricedEntry> repriced;

  /// Something was dropped or repriced: show the "Needs attention" summary.
  bool get needsAttention => dropped.isNotEmpty || repriced.isNotEmpty;

  /// Nothing came back.
  bool get isEmpty;
}

/// A parked cart, ready to go back into the cart.
final class ResolvedCart extends ResolvedDraft {
  const ResolvedCart({
    required this.lines,
    required this.notes,
    required this.fulfillment,
    required super.dropped,
    required super.repriced,
  });

  /// Lines built on today's menu items, with today's prices.
  final List<CartLine> lines;
  final String notes;
  final FulfillmentType? fulfillment;

  @override
  bool get isEmpty => lines.isEmpty;
}

/// A ticket type that is still on sale, and how many of it were parked.
final class ResolvedTicketLine {
  const ResolvedTicketLine({required this.type, required this.qty});

  final TicketType type;
  final int qty;
}

/// A parked ticket sale, ready to go back into the issue screen.
final class ResolvedTicketDraft extends ResolvedDraft {
  const ResolvedTicketDraft({
    required this.lines,
    required this.guestName,
    required this.guestPhone,
    required super.dropped,
    required super.repriced,
  });

  final List<ResolvedTicketLine> lines;
  final String? guestName;
  final String? guestPhone;

  @override
  bool get isEmpty => lines.isEmpty;
}

/// Resolves whichever kind [payload] is.
ResolvedDraft resolveDraft(
  ParkedPayload payload, {
  required List<MenuItem> menu,
  required List<TicketType> ticketTypes,
}) =>
    switch (payload) {
      final CounterCartDraft cart => resolveCounterCart(cart, menu),
      final TicketIssueDraft sale => resolveTicketIssue(sale, ticketTypes),
    };

/// [draft] put back against [menu].
ResolvedCart resolveCounterCart(CounterCartDraft draft, List<MenuItem> menu) {
  final byId = <String, MenuItem>{for (final item in menu) item.id: item};
  final lines = <CartLine>[];
  final dropped = <DroppedEntry>[];
  final repriced = <RepricedEntry>[];

  for (final saved in draft.lines) {
    final item = byId[saved.itemId];
    if (item == null) {
      dropped.add(_wholeItem(DropIssue.itemRemoved, saved));
      continue;
    }
    if (!item.available) {
      dropped.add(_wholeItem(DropIssue.itemUnavailable, saved));
      continue;
    }
    if (item.isWeighed != (saved.weight != null)) {
      dropped.add(_wholeItem(DropIssue.itemChanged, saved));
      continue;
    }
    final resolved = _resolveLine(saved, item);
    lines.add(resolved.line);
    dropped.addAll(resolved.dropped);
    final moved = resolved.repriced;
    if (moved != null) repriced.add(moved);
  }

  return ResolvedCart(
    lines: _mergeIdentical(lines),
    notes: draft.notes,
    fulfillment: draft.fulfillment,
    dropped: dropped,
    repriced: repriced,
  );
}

/// [draft] put back against the ticket types now [types] on sale.
ResolvedTicketDraft resolveTicketIssue(
  TicketIssueDraft draft,
  List<TicketType> types,
) {
  final byId = <String, TicketType>{for (final type in types) type.id: type};
  final lines = <ResolvedTicketLine>[];
  final dropped = <DroppedEntry>[];
  final repriced = <RepricedEntry>[];

  for (final saved in draft.lines) {
    final type = byId[saved.ticketTypeId];
    if (type == null) {
      dropped.add(DroppedEntry(
        issue: DropIssue.typeRemoved,
        itemName: saved.name ?? 'Ticket',
        qty: saved.qty,
      ));
      continue;
    }
    lines.add(ResolvedTicketLine(type: type, qty: saved.qty));
    final was = saved.unitTotal;
    if (was != null && was != type.unitTotal) {
      repriced.add(RepricedEntry(
        itemName: type.name,
        was: was,
        now: type.unitTotal,
      ));
    }
  }

  return ResolvedTicketDraft(
    lines: lines,
    guestName: draft.guestName,
    guestPhone: draft.guestPhone,
    dropped: dropped,
    repriced: repriced,
  );
}

DroppedEntry _wholeItem(DropIssue issue, ParkedCartLine saved) => DroppedEntry(
      issue: issue,
      itemName: saved.itemName,
      qty: saved.units,
    );

typedef _ResolvedLine = ({
  CartLine line,
  List<DroppedEntry> dropped,
  RepricedEntry? repriced,
});

/// One line against its item as it is today.
///
/// A unit costs `item.price + modsExtra + add-ons`, so a changed price is
/// carried by adjusting `modsExtra` (options and the variation's premium over
/// the base) and by taking add-on prices from today's choices. Two sums keep
/// the "repriced" verdict honest:
///
/// - `shifted`: how much the parts that CAME BACK moved. Nothing moved (or
///   moves cancelled out) means no warning, even if the base price changed.
/// - `removed`: what the parts that were DROPPED used to add, so "was" and
///   "now" describe the same configuration, not the one before a drop and the
///   one after it.
_ResolvedLine _resolveLine(ParkedCartLine saved, MenuItem item) {
  final dropped = <DroppedEntry>[];
  void drop(DropIssue issue, String detail) => dropped.add(DroppedEntry(
        issue: issue,
        itemName: item.name,
        detail: detail,
      ));

  final mods = List<String>.of(saved.mods);
  // The cart lists the choices made by name; a choice renamed since keeps its
  // place in that list under its new name.
  void relabel(String? from, String to) {
    final at = from == null ? -1 : mods.indexOf(from);
    if (at >= 0) mods[at] = to;
  }

  var modsExtra = saved.modsExtra;
  var shifted = item.price - saved.itemPrice;
  var removed = Money.zero;

  String? variationId;
  String? variationName;
  final savedVariationId = saved.variationId;
  if (savedVariationId != null) {
    final variation =
        item.variations.where((v) => v.id == savedVariationId).firstOrNull;
    final savedPrice = saved.variationPrice;
    final savedPremium =
        savedPrice == null ? null : savedPrice - saved.itemPrice;
    if (variation == null) {
      drop(
        DropIssue.variationRemoved,
        saved.variationName ?? 'the chosen variation',
      );
      final label = saved.variationName;
      if (label != null) mods.remove(label);
      if (savedPremium != null) {
        modsExtra -= savedPremium;
        removed += savedPremium;
      }
    } else {
      variationId = variation.id;
      variationName = variation.name;
      relabel(saved.variationName, variation.name);
      if (savedPremium != null) {
        final moved = (variation.price - item.price) - savedPremium;
        modsExtra += moved;
        shifted += moved;
      }
    }
  }

  final options = <SelectedOption>[];
  for (final savedOption in saved.options) {
    final option = item.optionGroups
        .where((g) => g.name == savedOption.groupName)
        .expand((g) => g.options)
        .where((o) => o.name == savedOption.optionName)
        .firstOrNull;
    if (option == null) {
      drop(DropIssue.optionRemoved, savedOption.optionName);
      mods.remove(savedOption.optionName);
      modsExtra -= savedOption.priceModifier;
      removed += savedOption.priceModifier;
      continue;
    }
    options.add(SelectedOption(
      groupName: savedOption.groupName,
      optionName: savedOption.optionName,
      priceModifier: option.priceModifier,
    ));
    final moved = option.priceModifier - savedOption.priceModifier;
    modsExtra += moved;
    shifted += moved;
  }

  final addons = <SelectedAddonGroup>[];
  for (final savedGroup in saved.addons) {
    final group =
        item.addonGroups.where((g) => g.id == savedGroup.groupId).firstOrNull;
    final choices = <SelectedAddonChoice>[];
    for (final savedChoice in savedGroup.choices) {
      final choice =
          group?.choices.where((c) => c.id == savedChoice.choiceId).firstOrNull;
      if (choice == null) {
        drop(DropIssue.addonRemoved, savedChoice.name);
        mods.remove(savedChoice.name);
        removed += savedChoice.price;
        continue;
      }
      choices.add(SelectedAddonChoice(
        choiceId: choice.id,
        name: choice.name,
        price: choice.price,
      ));
      relabel(savedChoice.name, choice.name);
      shifted += choice.price - savedChoice.price;
    }
    if (choices.isEmpty) continue;
    addons.add(SelectedAddonGroup(
      groupId: savedGroup.groupId,
      groupName: group?.name ?? savedGroup.groupName,
      choices: choices,
    ));
  }

  final line = CartLine(
    item: item,
    qty: saved.qty,
    mods: mods,
    selectedOptions: options,
    selectedAddons: addons,
    modsExtra: modsExtra,
    itemNote: saved.note,
    variationId: variationId,
    variationName: variationName,
    weight: saved.weight,
  );
  return (
    line: line,
    dropped: dropped,
    repriced: shifted.isZero
        ? null
        : RepricedEntry(
            itemName: item.name,
            was: saved.unitPrice - removed,
            now: line.unitPrice,
          ),
  );
}

/// Lines that ended up the same configuration (a drop made them alike) merge
/// into one, the way the cart merges them as they are added.
List<CartLine> _mergeIdentical(List<CartLine> lines) {
  final merged = <CartLine>[];
  for (final line in lines) {
    final at = merged.indexWhere((m) => m.configKey == line.configKey);
    if (at < 0) {
      merged.add(line);
    } else {
      merged[at] = merged[at].copyWith(qty: merged[at].qty + line.qty);
    }
  }
  return merged;
}
