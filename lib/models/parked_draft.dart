/// What the phone keeps when a cashier parks a cart, or a gate usher parks a
/// ticket sale, to serve the next customer first: a [ParkedDraft] and the two
/// payloads it can carry.
///
/// Drafts live on the phone only; the desk never sees them. They are kept as
/// the plain JSON the rest of the app already speaks: money as rupees
/// ([Money.toWire] / [Money.fromWire]) and cart lines in the shape
/// `order:create` takes (`item_id`, `quantity`, `selected_options`,
/// `selected_addons`, `weight`, `notes`), plus a snapshot of what each part
/// cost, so a draft resumed days later can tell what has moved since.
///
/// Parsing is strict on purpose: anything this app cannot read throws a
/// [WireFormatException], and the store then skips that entry (and leaves it
/// on disk) rather than guess.
library;

import '../data/money.dart';
import '../data/providers.dart';
import 'entry_ticket.dart';
import 'token.dart';
import 'wire.dart';

/// What a draft is of. Stored by [name]: renaming a member would orphan the
/// drafts already on phones (they would be skipped, but never deleted).
enum ParkedKind {
  /// The counter's cart, parked from the builder.
  counterCart('cart'),

  /// A gate ticket sale, parked from the issue screen.
  ticketIssue('ticket sale');

  const ParkedKind(this.noun);

  /// How staff say it: "20 parked carts", "20 parked ticket sales".
  final String noun;

  String get plural => '${noun}s';

  /// Null for a name this app does not know (a draft from another version).
  static ParkedKind? fromName(Object? raw) {
    for (final kind in values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }
}

/// Whose drafts these are: the signed-in operator on the paired desk. A draft
/// is only ever shown to the scope it was parked under.
final class ParkedScope {
  const ParkedScope({required this.operatorId, required this.deskInstanceId});

  final String operatorId;
  final String deskInstanceId;

  @override
  bool operator ==(Object other) =>
      other is ParkedScope &&
      other.operatorId == operatorId &&
      other.deskInstanceId == deskInstanceId;

  @override
  int get hashCode => Object.hash(operatorId, deskInstanceId);

  @override
  String toString() =>
      'ParkedScope(operator: $operatorId, desk: $deskInstanceId)';
}

/// The part of a draft that is the cart or the ticket sale itself.
sealed class ParkedPayload {
  const ParkedPayload();

  ParkedKind get kind;

  /// Nothing in it, so nothing worth parking.
  bool get isEmpty;

  /// What it came to when parked, or null when what was saved cannot tell.
  Money? get total;

  /// "2× Masala Dosa, 1× Cold Coffee", for the list.
  String get summary;

  Map<String, dynamic> toJson();

  /// Throws [WireFormatException] for anything unreadable.
  static ParkedPayload fromJson(ParkedKind kind, Map<String, dynamic> json) =>
      switch (kind) {
        ParkedKind.counterCart => CounterCartDraft.fromJson(json),
        ParkedKind.ticketIssue => TicketIssueDraft.fromJson(json),
      };
}

String _summarize(List<String> parts) {
  const shown = 3;
  if (parts.length <= shown) return parts.join(', ');
  return '${parts.take(shown).join(', ')} +${parts.length - shown} more';
}

Never _unreadable(String entity, String field, String reason,
        [Object? received]) =>
    throw WireFormatException(
      entity: entity,
      field: field,
      reason: reason,
      received: received,
    );

/// One cart line as parked: what the cashier chose, and what it cost then.
final class ParkedCartLine {
  const ParkedCartLine({
    required this.itemId,
    required this.itemName,
    required this.qty,
    required this.itemPrice,
    this.weight,
    this.note = '',
    this.modsExtra = Money.zero,
    this.mods = const <String>[],
    this.variationId,
    this.variationName,
    this.variationPrice,
    this.options = const <SelectedOption>[],
    this.addons = const <SelectedAddonGroup>[],
  });

  /// Snapshots [line] as the cart holds it.
  factory ParkedCartLine.fromCartLine(CartLine line) {
    final variationId = line.variationId;
    final variation = variationId == null
        ? null
        : line.item.variations.where((v) => v.id == variationId).firstOrNull;
    return ParkedCartLine(
      itemId: line.item.id,
      itemName: line.item.name,
      qty: line.qty,
      itemPrice: line.item.price,
      weight: line.weight,
      note: line.itemNote,
      modsExtra: line.modsExtra,
      mods: List<String>.of(line.mods),
      variationId: variationId,
      variationName: line.variationName,
      variationPrice: variation?.price,
      options: List<SelectedOption>.of(line.selectedOptions),
      addons: List<SelectedAddonGroup>.of(line.selectedAddons),
    );
  }

  factory ParkedCartLine.fromJson(Map<String, dynamic> m) {
    const entity = 'ParkedCartLine';
    final qty = requireInt(m, 'quantity', entity);
    if (qty < 1) _unreadable(entity, 'quantity', 'must be at least 1', qty);
    final rawWeight = m['weight'];
    if (rawWeight != null && (rawWeight is! num || !(rawWeight > 0))) {
      _unreadable(entity, 'weight', 'must be a positive number', rawWeight);
    }
    final rawNote = m['notes'];
    final rawMods = m['mods'];
    return ParkedCartLine(
      itemId: requireString(m, 'item_id', entity),
      itemName: stringOr(m, 'item_name', 'Item'),
      qty: qty,
      itemPrice: requireMoney(m, 'item_price', entity),
      weight: rawWeight is num ? rawWeight.toDouble() : null,
      note: rawNote is String ? rawNote : '',
      modsExtra: optionalMoney(m, 'mods_extra') ?? Money.zero,
      mods: rawMods is List
          ? <String>[for (final v in rawMods) v.toString()]
          : const <String>[],
      variationId: optionalString(m, 'variation_id'),
      variationName: optionalString(m, 'variation_name'),
      variationPrice: optionalMoney(m, 'variation_price'),
      options: <SelectedOption>[
        for (final o in mapList(m['selected_options']))
          SelectedOption(
            groupName: requireString(o, 'group_name', entity),
            optionName: requireString(o, 'option_name', entity),
            priceModifier: optionalMoney(o, 'price_modifier') ?? Money.zero,
          ),
      ],
      addons: <SelectedAddonGroup>[
        for (final g in mapList(m['selected_addons']))
          SelectedAddonGroup(
            groupId: requireString(g, 'group_id', entity),
            groupName: stringOr(g, 'group_name', ''),
            choices: <SelectedAddonChoice>[
              for (final c in mapList(g['choices']))
                SelectedAddonChoice(
                  choiceId: requireString(c, 'choice_id', entity),
                  name: stringOr(c, 'name', ''),
                  price: optionalMoney(c, 'price') ?? Money.zero,
                ),
            ],
          ),
      ],
    );
  }

  final String itemId;

  /// The name when parked, for lists and for saying what was lost.
  final String itemName;
  final int qty;

  /// The item's own price when parked.
  final Money itemPrice;

  /// Set for an item sold by weight (and only then).
  final double? weight;
  final String note;

  /// Extras the line carried over the base price (option modifiers and the
  /// variation's premium), as [CartLine.modsExtra] had them.
  final Money modsExtra;

  /// The labels the cart shows for the choices made.
  final List<String> mods;
  final String? variationId;
  final String? variationName;

  /// The chosen variation's own price when parked; null when unknown.
  final Money? variationPrice;
  final List<SelectedOption> options;
  final List<SelectedAddonGroup> addons;

  Money get addonsExtra => addons.map((g) => g.extraPrice).sumMoney();

  /// What one unit cost when parked, as [CartLine.unitPrice] works it out.
  Money get unitPrice => itemPrice + modsExtra + addonsExtra;

  Money get lineTotal {
    final grams = weight;
    return grams == null ? unitPrice.times(qty) : unitPrice.timesWeight(grams);
  }

  /// A weighed line counts once, whatever its weight.
  int get units => weight == null ? qty : 1;

  /// "2× Masala Dosa", or "Loose Paneer (0.5)" for a weighed line.
  String get label {
    final grams = weight;
    if (grams == null) return '$qty× $itemName';
    final shown =
        grams == grams.roundToDouble() ? grams.toStringAsFixed(0) : '$grams';
    return '$itemName ($shown)';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'item_id': itemId,
        'item_name': itemName,
        'quantity': qty,
        if (weight != null) 'weight': weight,
        'notes': note,
        'item_price': itemPrice.toWire(),
        'mods_extra': modsExtra.toWire(),
        'mods': mods,
        if (variationId != null) 'variation_id': variationId,
        if (variationName != null) 'variation_name': variationName,
        if (variationPrice != null) 'variation_price': variationPrice!.toWire(),
        'selected_options': options.map((o) => o.toJson()).toList(),
        'selected_addons': addons.map((g) => g.toJson()).toList(),
      };
}

/// A parked counter cart: its lines, the order notes and how it leaves the
/// counter.
final class CounterCartDraft extends ParkedPayload {
  const CounterCartDraft({
    required this.lines,
    this.notes = '',
    this.fulfillment,
  });

  /// Snapshots the cart as the builder holds it.
  factory CounterCartDraft.fromCart(
    List<CartLine> cart, {
    String notes = '',
    FulfillmentType? fulfillment,
  }) =>
      CounterCartDraft(
        lines: <ParkedCartLine>[
          for (final line in cart) ParkedCartLine.fromCartLine(line),
        ],
        notes: notes,
        fulfillment: fulfillment,
      );

  factory CounterCartDraft.fromJson(Map<String, dynamic> m) {
    const entity = 'CounterCartDraft';
    final raw = m['lines'];
    if (raw is! List || raw.isEmpty) {
      _unreadable(entity, 'lines', 'missing or empty', raw);
    }
    final rawNotes = m['notes'];
    return CounterCartDraft(
      lines: <ParkedCartLine>[
        for (final line in raw)
          if (line is Map)
            ParkedCartLine.fromJson(Map<String, dynamic>.from(line))
          else
            _unreadable(entity, 'lines', 'a line is not an object', line),
      ],
      notes: rawNotes is String ? rawNotes : '',
      fulfillment: FulfillmentType.fromWire(m['fulfillment']),
    );
  }

  final List<ParkedCartLine> lines;
  final String notes;
  final FulfillmentType? fulfillment;

  @override
  ParkedKind get kind => ParkedKind.counterCart;

  @override
  bool get isEmpty => lines.isEmpty;

  @override
  Money get total => lines.map((line) => line.lineTotal).sumMoney();

  @override
  String get summary => _summarize(<String>[for (final l in lines) l.label]);

  @override
  Map<String, dynamic> toJson() => <String, dynamic>{
        'lines': lines.map((line) => line.toJson()).toList(),
        if (notes.isNotEmpty) 'notes': notes,
        if (fulfillment != null) 'fulfillment': fulfillment!.wire,
      };
}

/// One ticket type and how many of it, in a parked sale. Only the id and the
/// count matter to the sale; the name and unit total are what the usher saw
/// when parking, kept so the list can show them and a later price change can
/// be noticed.
final class ParkedTicketLine {
  const ParkedTicketLine({
    required this.ticketTypeId,
    required this.qty,
    this.name,
    this.unitTotal,
  });

  /// [qty] of [type], with the name and price as they are now.
  factory ParkedTicketLine.of(TicketType type, int qty) => ParkedTicketLine(
        ticketTypeId: type.id,
        qty: qty,
        name: type.name,
        unitTotal: type.unitTotal,
      );

  factory ParkedTicketLine.fromJson(Map<String, dynamic> m) {
    const entity = 'ParkedTicketLine';
    final qty = requireInt(m, 'qty', entity);
    if (qty < 1) _unreadable(entity, 'qty', 'must be at least 1', qty);
    return ParkedTicketLine(
      ticketTypeId: requireString(m, 'ticket_type_id', entity),
      qty: qty,
      name: optionalString(m, 'name'),
      unitTotal: optionalMoney(m, 'unit_total'),
    );
  }

  final String ticketTypeId;
  final int qty;
  final String? name;

  /// What one ticket cost, GST included, when parked; null when not known.
  final Money? unitTotal;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ticket_type_id': ticketTypeId,
        'qty': qty,
        if (name != null) 'name': name,
        if (unitTotal != null) 'unit_total': unitTotal!.toWire(),
      };
}

/// A parked gate sale: the ticket types and counts, and the guest if the
/// usher had taken one down.
final class TicketIssueDraft extends ParkedPayload {
  const TicketIssueDraft({
    required this.lines,
    this.guestName,
    this.guestPhone,
  });

  factory TicketIssueDraft.fromJson(Map<String, dynamic> m) {
    const entity = 'TicketIssueDraft';
    final raw = m['lines'];
    if (raw is! List || raw.isEmpty) {
      _unreadable(entity, 'lines', 'missing or empty', raw);
    }
    return TicketIssueDraft(
      lines: <ParkedTicketLine>[
        for (final line in raw)
          if (line is Map)
            ParkedTicketLine.fromJson(Map<String, dynamic>.from(line))
          else
            _unreadable(entity, 'lines', 'a line is not an object', line),
      ],
      guestName: optionalString(m, 'guest_name'),
      guestPhone: optionalString(m, 'guest_phone'),
    );
  }

  final List<ParkedTicketLine> lines;
  final String? guestName;
  final String? guestPhone;

  @override
  ParkedKind get kind => ParkedKind.ticketIssue;

  @override
  bool get isEmpty => lines.isEmpty;

  @override
  Money? get total {
    var sum = Money.zero;
    for (final line in lines) {
      final unit = line.unitTotal;
      if (unit == null) return null;
      sum += unit.times(line.qty);
    }
    return sum;
  }

  @override
  String get summary => _summarize(
      <String>[for (final l in lines) '${l.qty}× ${l.name ?? 'Ticket'}']);

  @override
  Map<String, dynamic> toJson() {
    final name = guestName?.trim();
    final phone = guestPhone?.trim();
    return <String, dynamic>{
      'lines': lines.map((line) => line.toJson()).toList(),
      if (name != null && name.isNotEmpty) 'guest_name': name,
      if (phone != null && phone.isNotEmpty) 'guest_phone': phone,
    };
  }
}

/// A draft as it sits in the store.
final class ParkedDraft {
  const ParkedDraft({
    required this.id,
    required this.scope,
    required this.createdAt,
    required this.seq,
    required this.payload,
  });

  /// Throws [WireFormatException] for anything unreadable, including a kind
  /// this app does not know.
  factory ParkedDraft.fromJson(Map<String, dynamic> m) {
    const entity = 'ParkedDraft';
    final kind = ParkedKind.fromName(m['kind']);
    if (kind == null) _unreadable(entity, 'kind', 'unknown kind');
    final created = DateTime.tryParse(requireString(m, 'created_at', entity));
    if (created == null) _unreadable(entity, 'created_at', 'not a time');
    final seq = requireInt(m, 'seq', entity);
    if (seq < 1) _unreadable(entity, 'seq', 'must be at least 1', seq);
    final payload = optionalMap(m, 'payload');
    if (payload == null) _unreadable(entity, 'payload', 'missing');
    return ParkedDraft(
      id: requireString(m, 'id', entity),
      scope: ParkedScope(
        operatorId: requireString(m, 'operator_id', entity),
        deskInstanceId: requireString(m, 'desk_instance_id', entity),
      ),
      createdAt: created.toUtc(),
      seq: seq,
      payload: ParkedPayload.fromJson(kind, payload),
    );
  }

  final String id;
  final ParkedScope scope;

  /// When it was parked, as an instant.
  final DateTime createdAt;

  /// Its number among the day's drafts of its kind for this operator.
  final int seq;
  final ParkedPayload payload;

  ParkedKind get kind => payload.kind;

  /// The local label, "P1", "P2"…: numbered per operator and kind, starting
  /// again at P1 each IST day.
  String get label => 'P$seq';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.name,
        'operator_id': scope.operatorId,
        'desk_instance_id': scope.deskInstanceId,
        'created_at': createdAt.toUtc().toIso8601String(),
        'seq': seq,
        'payload': payload.toJson(),
      };
}
