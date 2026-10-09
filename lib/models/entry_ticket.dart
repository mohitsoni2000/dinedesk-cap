/// Entry tickets: the types the gate sells (sync `entry_ticket_types`), the
/// cover settings (`entry_ticket_config`), and the `ticket:*` acks.
///
/// Money is rupees on the wire, read with [Money.fromWire]. Parsing is
/// lenient like the rest of the wire layer: a row missing its identity is
/// dropped, anything else falls back.
library;

import 'package:collection/collection.dart';

import '../data/ist_time.dart';
import '../data/money.dart';
import '../services/log.dart';
import 'feature_flags.dart';
import 'wire.dart';

/// Whether this user may take a guest's cover as payment on a bill. There is
/// no separate redeem permission: cover rides on the entry-ticket module plus
/// the right to collect payment, and needs the desk to name its cover mode.
bool canRedeemCover(FeatureFlags flags, TicketConfig config) =>
    flags.entryTickets &&
    flags.collectPayment &&
    config.coverPaymentMode != null;

/// One ticket type on sale at the gate.
class TicketType {
  final String id;
  final String name;

  /// The configured price (GST-exclusive when [gstInclusive] is false).
  final Money price;

  /// GST percent on the entry part.
  final double gstRate;
  final bool gstInclusive;

  /// The part of each ticket the guest can spend on today's food and drinks.
  final Money coverAmount;

  /// Guests one ticket admits.
  final int pax;

  /// `#RRGGBB` for the tile, or null.
  final String? color;
  final int sortOrder;

  /// What one ticket costs the guest, GST included. The phone charges this
  /// and never does tax math itself.
  final Money unitTotal;

  const TicketType({
    required this.id,
    required this.name,
    required this.price,
    required this.gstRate,
    required this.gstInclusive,
    required this.coverAmount,
    required this.pax,
    required this.sortOrder,
    required this.unitTotal,
    this.color,
  });

  bool get hasCover => coverAmount.isPositive;

  factory TicketType.fromMap(Map<String, dynamic> m) {
    const entity = 'TicketType';
    final unitTotal = requireMoney(m, 'unit_total', entity);
    final pax = intOr(m, 'pax', 1);
    return TicketType(
      id: requireString(m, 'id', entity),
      name: stringOr(m, 'name', 'Ticket'),
      price: optionalMoney(m, 'price') ?? unitTotal,
      gstRate: _double(m['gst_rate']) ?? 0,
      gstInclusive: boolOr(m, 'gst_inclusive', true),
      coverAmount: optionalMoney(m, 'cover_amount') ?? Money.zero,
      pax: pax < 1 ? 1 : pax,
      color: optionalString(m, 'color'),
      sortOrder: intOr(m, 'sort_order', 0),
      unitTotal: unitTotal,
    );
  }

  /// The types in [raw] (the sync list), in the desk's sort order. A row
  /// that cannot be charged (no id or no `unit_total`) is dropped.
  static List<TicketType> listFrom(Object? raw) {
    final types = parseEach(mapList(raw), TicketType.fromMap, 'TicketType');
    // Stable: types sharing a sort_order keep the desk's order.
    mergeSort<TicketType>(types,
        compare: (a, b) => a.sortOrder.compareTo(b.sortOrder));
    return types;
  }
}

/// The desk's cover and QR settings (`entry_ticket_config`).
class TicketConfig {
  static const String defaultQrPrefix = 'CDT:';

  /// The payment-mode code cover is recorded under (`cover_ticket`), or null
  /// when this desk takes no cover as payment.
  final String? coverPaymentMode;

  /// What every ticket QR starts with.
  final String qrPrefix;

  const TicketConfig({this.coverPaymentMode, this.qrPrefix = defaultQrPrefix});

  /// No entry tickets on this desk (or an older desk).
  static const TicketConfig none = TicketConfig();

  /// Null when [raw] is not a map.
  static TicketConfig? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    return TicketConfig(
      coverPaymentMode: optionalString(m, 'cover_payment_mode'),
      qrPrefix: optionalString(m, 'qr_prefix') ?? defaultQrPrefix,
    );
  }

  /// Whether [raw] is a ticket QR payload: the prefix and 16 base32
  /// characters (`CDT:` + `[A-Z2-7]{16}`). The gate drops anything else
  /// without asking the desk.
  bool matchesQr(String raw) =>
      RegExp('^${RegExp.escape(qrPrefix)}[A-Z2-7]{16}\$').hasMatch(raw.trim());
}

enum TicketStatus {
  issued('issued'),
  checkedIn('checked_in'),
  cancelled('cancelled'),
  unknown('');

  const TicketStatus(this.wire);
  final String wire;

  static TicketStatus fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    if (key == null || key.isEmpty) return unknown;
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return unknown;
  }
}

/// What a printed slip says, written by the desk (one shared builder for desk
/// and Crew slips); the phone only lays it out.
class TicketSlipContent {
  /// Venue name first, then address / GSTIN lines.
  final List<String> header;
  final String ticketNo;
  final String title;

  /// The big line under the title, e.g. "ADMITS 2 PAX".
  final String? highlight;
  final List<String> lines;
  final List<String> footer;

  /// The QR payload to print; the ticket's own `qr_code` when absent.
  final String? qrData;

  const TicketSlipContent({
    required this.header,
    required this.ticketNo,
    required this.title,
    required this.lines,
    required this.footer,
    this.highlight,
    this.qrData,
  });

  static TicketSlipContent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final ticketNo = optionalString(m, 'ticket_no');
    if (ticketNo == null) return null;
    return TicketSlipContent(
      header: _strings(m['header']),
      ticketNo: ticketNo,
      title: stringOr(m, 'title', ''),
      highlight: optionalString(m, 'highlight'),
      lines: _strings(m['lines']),
      footer: _strings(m['footer']),
      qrData: optionalString(m, 'qr_data'),
    );
  }
}

/// One issued ticket (one slip, one QR) as the `ticket:issue` and
/// `ticket:lookup` acks carry it.
class EntryTicket {
  final String id;
  final String ticketNumber;
  final String qrCode;
  final String? typeId;
  final String typeName;
  final int pax;
  final Money price;
  final Money taxableAmount;
  final Money gstAmount;
  final Money coverAmount;

  /// What the guest can still spend on a bill today: 0 once the ticket is
  /// cancelled or its day has passed (unused cover is forfeited at the
  /// cutover).
  final Money coverBalance;
  final TicketStatus status;
  final DateTime? issuedAt;

  /// The business day the ticket (and its cover) is valid for.
  final String? validDate;
  final TicketSlipContent? slip;

  const EntryTicket({
    required this.id,
    required this.ticketNumber,
    required this.qrCode,
    required this.typeName,
    required this.pax,
    required this.price,
    required this.taxableAmount,
    required this.gstAmount,
    required this.coverAmount,
    required this.coverBalance,
    required this.status,
    this.typeId,
    this.issuedAt,
    this.validDate,
    this.slip,
  });

  factory EntryTicket.fromMap(Map<String, dynamic> m) {
    const entity = 'EntryTicket';
    return EntryTicket(
      id: requireString(m, 'id', entity),
      ticketNumber: requireString(m, 'ticket_number', entity),
      // A paid ticket is never dropped for a missing QR: its number still
      // admits the guest when typed in.
      qrCode: optionalString(m, 'qr_code') ?? '',
      typeId: optionalString(m, 'type_id'),
      typeName: stringOr(m, 'type_name', 'Ticket'),
      pax: intOr(m, 'pax', 1),
      price: optionalMoney(m, 'price') ?? Money.zero,
      taxableAmount: optionalMoney(m, 'taxable_amount') ?? Money.zero,
      gstAmount: optionalMoney(m, 'gst_amount') ?? Money.zero,
      coverAmount: optionalMoney(m, 'cover_amount') ?? Money.zero,
      coverBalance: optionalMoney(m, 'cover_balance') ?? Money.zero,
      status: TicketStatus.fromWire(m['status']),
      issuedAt: parseDbTimestamp(optionalString(m, 'issued_at')),
      validDate: optionalString(m, 'valid_date'),
      slip: TicketSlipContent.tryParse(m['slip']),
    );
  }
}

class TicketSaleTotals {
  /// The entry part before GST (the cover is not in it).
  final Money subtotal;
  final Money gst;
  final Money roundOff;
  final Money total;

  /// Cover advance across the sale's tickets.
  final Money coverTotal;

  const TicketSaleTotals({
    required this.subtotal,
    required this.gst,
    required this.roundOff,
    required this.total,
    required this.coverTotal,
  });

  factory TicketSaleTotals.fromMap(Map<String, dynamic> m) => TicketSaleTotals(
        subtotal: optionalMoney(m, 'subtotal') ?? Money.zero,
        gst: optionalMoney(m, 'gst') ?? Money.zero,
        roundOff: optionalMoney(m, 'round_off') ?? Money.zero,
        total: optionalMoney(m, 'total') ?? Money.zero,
        coverTotal: optionalMoney(m, 'cover_total') ?? Money.zero,
      );
}

/// One tender on a ticket sale.
class TicketPayment {
  final String mode;
  final Money amount;
  final String? referenceNumber;

  /// A custom mode's printed name; null for a built-in mode.
  final String? printName;

  const TicketPayment({
    required this.mode,
    required this.amount,
    this.referenceNumber,
    this.printName,
  });

  factory TicketPayment.fromMap(Map<String, dynamic> m) {
    const entity = 'TicketPayment';
    final mode = optionalStringAny(m, <String>['payment_mode', 'mode']);
    if (mode == null) {
      throw const WireFormatException(
          entity: entity, field: 'payment_mode', reason: 'missing');
    }
    return TicketPayment(
      mode: mode,
      amount: requireMoney(m, 'amount', entity),
      referenceNumber: optionalString(m, 'reference_number'),
      printName: optionalString(m, 'mode_print_name'),
    );
  }
}

/// A ticket sale: one invoice for one or more tickets.
class TicketSale {
  final String id;
  final String saleNumber;
  final DateTime? issuedAt;
  final String? businessDate;
  final String? guestName;

  /// Only the last four digits ever reach the phone.
  final String? guestPhoneLast4;
  final TicketSaleTotals totals;
  final List<TicketPayment> payments;
  final String? issuedByName;

  /// `active` or `cancelled`.
  final String status;

  /// `desk` or `crew`.
  final String? issuedFrom;

  const TicketSale({
    required this.id,
    required this.saleNumber,
    required this.totals,
    required this.payments,
    required this.status,
    this.issuedAt,
    this.businessDate,
    this.guestName,
    this.guestPhoneLast4,
    this.issuedByName,
    this.issuedFrom,
  });

  factory TicketSale.fromMap(Map<String, dynamic> m) {
    const entity = 'TicketSale';
    return TicketSale(
      id: requireString(m, 'id', entity),
      saleNumber: stringOr(m, 'sale_number', ''),
      issuedAt: parseDbTimestamp(optionalString(m, 'issued_at')),
      businessDate: optionalString(m, 'business_date'),
      guestName: optionalString(m, 'guest_name'),
      guestPhoneLast4: optionalString(m, 'guest_phone_last4'),
      totals: TicketSaleTotals.fromMap(asMap(m['totals'])),
      payments: parseEach(
          mapList(m['payments']), TicketPayment.fromMap, 'TicketPayment'),
      issuedByName: optionalString(m, 'issued_by_name'),
      status: stringOr(m, 'status', 'active'),
      issuedFrom: optionalString(m, 'issued_from'),
    );
  }
}

/// The `ticket:issue` success ack: the sale and one ticket per unit sold.
class TicketIssueResult {
  final TicketSale sale;
  final List<EntryTicket> tickets;

  const TicketIssueResult({required this.sale, required this.tickets});

  /// Throws [WireFormatException] unless the sale and EVERY ticket parse. A
  /// paid sale must never pass as an empty one, or as fewer slips than were
  /// paid for: the guest would be short a ticket with nothing on screen.
  factory TicketIssueResult.fromAck(Map<String, dynamic> ack) {
    const entity = 'TicketIssueResult';
    final sale = optionalMap(ack, 'sale');
    if (sale == null) {
      throw const WireFormatException(
          entity: entity, field: 'sale', reason: 'missing');
    }
    final rows = ack['tickets'];
    if (rows is! List || rows.isEmpty) {
      throw WireFormatException(
          entity: entity,
          field: 'tickets',
          reason: 'missing or empty',
          received: rows);
    }
    final tickets = <EntryTicket>[
      for (final row in rows)
        if (row is Map)
          EntryTicket.fromMap(Map<String, dynamic>.from(row))
        else
          throw WireFormatException(
              entity: entity,
              field: 'tickets',
              reason: 'a row is not an object',
              received: row),
    ];
    return TicketIssueResult(sale: TicketSale.fromMap(sale), tickets: tickets);
  }
}

/// The short form of a ticket: the `ticket:check_in` ack's ticket and the
/// `ticket:recent` rows. Fields a given ack does not send read as empty.
class TicketSummary {
  final String id;
  final String ticketNumber;
  final String typeName;
  final int pax;
  final TicketStatus status;
  final Money coverAmount;

  /// Usable today: 0 once cancelled or expired (see [EntryTicket.coverBalance]).
  final Money coverBalance;
  final String? guestName;
  final String? guestPhoneLast4;
  final DateTime? issuedAt;
  final DateTime? checkedInAt;
  final String? validDate;

  const TicketSummary({
    required this.id,
    required this.ticketNumber,
    required this.typeName,
    required this.pax,
    required this.status,
    required this.coverAmount,
    required this.coverBalance,
    this.guestName,
    this.guestPhoneLast4,
    this.issuedAt,
    this.checkedInAt,
    this.validDate,
  });

  factory TicketSummary.fromMap(Map<String, dynamic> m) {
    const entity = 'TicketSummary';
    return TicketSummary(
      id: requireString(m, 'id', entity),
      ticketNumber: requireString(m, 'ticket_number', entity),
      typeName: stringOr(m, 'type_name', 'Ticket'),
      pax: intOr(m, 'pax', 1),
      status: TicketStatus.fromWire(m['status']),
      coverAmount: optionalMoney(m, 'cover_amount') ?? Money.zero,
      coverBalance: optionalMoney(m, 'cover_balance') ?? Money.zero,
      guestName: optionalString(m, 'guest_name'),
      guestPhoneLast4: optionalString(m, 'guest_phone_last4'),
      issuedAt: parseDbTimestamp(optionalString(m, 'issued_at')),
      checkedInAt: parseDbTimestamp(optionalString(m, 'checked_in_at')),
      validDate: optionalString(m, 'valid_date'),
    );
  }

  static TicketSummary? tryParse(Object? raw) {
    if (raw is! Map) return null;
    try {
      return TicketSummary.fromMap(Map<String, dynamic>.from(raw));
    } on WireFormatException catch (e) {
      logE('[Wire]', 'dropped one TicketSummary', e);
      return null;
    }
  }
}

/// A check-in's business outcome. Every one of them is a success ack; only
/// validation, permission and transport problems are errors.
enum CheckInOutcome {
  valid('valid'),
  alreadyUsed('already_used'),
  expired('expired'),
  cancelled('cancelled'),
  notFound('not_found'),

  /// A word this app does not know (a newer desk). Treat as "not admitted".
  unknown('');

  const CheckInOutcome(this.wire);
  final String wire;

  static CheckInOutcome fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    if (key == null || key.isEmpty) return unknown;
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return unknown;
  }
}

/// The `ticket:check_in` ack.
class CheckInResult {
  final CheckInOutcome outcome;

  /// Null for [CheckInOutcome.notFound].
  final TicketSummary? ticket;

  /// The (first) check-in: now for [CheckInOutcome.valid], the earlier one
  /// for [CheckInOutcome.alreadyUsed]; null otherwise. Desk time, UTC.
  final DateTime? checkedInAt;
  final String? checkedInByName;

  const CheckInResult({
    required this.outcome,
    this.ticket,
    this.checkedInAt,
    this.checkedInByName,
  });

  factory CheckInResult.fromAck(Map<String, dynamic> ack) => CheckInResult(
        outcome: CheckInOutcome.fromWire(ack['result']),
        ticket: TicketSummary.tryParse(ack['ticket']),
        checkedInAt: parseDbTimestamp(optionalString(ack, 'checked_in_at')),
        checkedInByName: optionalString(ack, 'checked_in_by_name'),
      );
}

/// Why a looked-up ticket cannot pay a bill.
enum LookupReason {
  notFound('not_found'),
  cancelled('cancelled'),
  expired('expired'),
  noCover('no_cover'),
  usedUp('used_up'),

  /// Any other reason the desk gives.
  other('');

  const LookupReason(this.wire);
  final String wire;

  /// Null when there is no reason.
  static LookupReason? fromWire(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    if (key == null || key.isEmpty) return null;
    for (final v in values) {
      if (v.wire == key) return v;
    }
    return other;
  }
}

/// The `ticket:lookup` ack. An unknown code is a success with no ticket.
class LookupResult {
  final EntryTicket? ticket;

  /// Usable today: 0 once cancelled or expired (see [EntryTicket.coverBalance]).
  final Money coverBalance;
  final bool canRedeem;
  final LookupReason? reason;

  const LookupResult({
    required this.coverBalance,
    required this.canRedeem,
    this.ticket,
    this.reason,
  });

  factory LookupResult.fromAck(Map<String, dynamic> ack) {
    final raw = optionalMap(ack, 'ticket');
    EntryTicket? ticket;
    if (raw != null) {
      try {
        ticket = EntryTicket.fromMap(raw);
      } on WireFormatException catch (e) {
        logE('[Wire]', 'dropped one EntryTicket', e);
      }
    }
    return LookupResult(
      ticket: ticket,
      coverBalance: optionalMoney(ack, 'cover_balance') ?? Money.zero,
      canRedeem: boolOr(ack, 'can_redeem', false),
      reason: LookupReason.fromWire(ack['reason']),
    );
  }
}

/// The gate's counters for the business day.
class GateStats {
  final int issued;
  final int paxIssued;
  final int checkedIn;
  final int paxInside;

  const GateStats({
    required this.issued,
    required this.paxIssued,
    required this.checkedIn,
    required this.paxInside,
  });

  factory GateStats.fromMap(Map<String, dynamic> m) => GateStats(
        issued: intOr(m, 'issued', 0),
        paxIssued: intOr(m, 'pax_issued', 0),
        checkedIn: intOr(m, 'checked_in', 0),
        paxInside: intOr(m, 'pax_inside', 0),
      );
}

/// The `ticket:recent` ack: today's tickets, newest first.
class RecentTickets {
  final String? businessDate;
  final List<TicketSummary> tickets;
  final GateStats stats;

  const RecentTickets({
    required this.tickets,
    required this.stats,
    this.businessDate,
  });

  factory RecentTickets.fromAck(Map<String, dynamic> ack) => RecentTickets(
        businessDate: optionalString(ack, 'business_date'),
        tickets: parseEach(
            mapList(ack['tickets']), TicketSummary.fromMap, 'TicketSummary'),
        stats: GateStats.fromMap(asMap(ack['stats'])),
      );
}

double? _double(Object? raw) {
  if (raw is num) return raw.isFinite ? raw.toDouble() : null;
  if (raw is String) return double.tryParse(raw.trim());
  return null;
}

List<String> _strings(Object? raw) => raw is List
    ? <String>[
        for (final e in raw)
          if (e != null) e.toString(),
      ]
    : const <String>[];
