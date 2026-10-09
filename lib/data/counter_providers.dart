/// The counter's state on the phone: how the next order leaves (takeaway or
/// standing), what the token screen shows, a Pay & Fire still waiting for
/// the desk's answer, and the lists the Counter home shows.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server_models.dart';
import '../models/token.dart';
import '../services/log.dart';
import '../services/offline_order_queue_service.dart';
import '../services/qsr_checkout_service.dart';
import '../widgets/dynamic_toast.dart';
import 'money.dart';
import 'providers.dart';

const String _tag = '[Counter]';

/// Takeaway or standing for the next counter order, remembered on the phone
/// (`counter_fulfillment_v1`).
final counterFulfillmentProvider =
    StateNotifierProvider<CounterFulfillmentNotifier, FulfillmentType>(
        (_) => CounterFulfillmentNotifier());

class CounterFulfillmentNotifier extends StateNotifier<FulfillmentType> {
  CounterFulfillmentNotifier() : super(FulfillmentType.takeaway) {
    unawaited(_restore());
  }

  static const String prefsKey = 'counter_fulfillment_v1';

  /// Set once the cashier chose: a slow restore must not undo it.
  bool _chosen = false;

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = FulfillmentType.fromWire(prefs.getString(prefsKey));
      if (saved != null && mounted && !_chosen) state = saved;
    } catch (_) {}
  }

  Future<void> set(FulfillmentType value) async {
    _chosen = true;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, value.wire);
    } catch (_) {}
  }
}

/// A word for the cashier from something that ended after its screen did:
/// a queued order reaching the desk, a KOT the kitchen printer refused.
/// The counter screens show it (CounterNotices), once.
class CounterNotice {
  CounterNotice(this.message, {this.kind = ToastKind.error, DateTime? at})
      : at = at ?? DateTime.now();

  final String message;
  final ToastKind kind;
  final DateTime at;
}

final counterNoticeProvider = StateProvider<CounterNotice?>((_) => null);

/// The payment mode the counter last charged with, picked again for the next
/// order.
final lastCounterPayModeProvider = StateProvider<String?>((_) => null);

/// What became of a counter order, as the token screen shows it.
enum CounterOutcome {
  /// On the desk: fired, and its token given (or on its way).
  fired,

  /// Queued on this phone: the desk is not reachable; the token comes when
  /// it is back.
  queued,

  /// A Pay & Fire the desk did not answer: it may have gone through.
  unconfirmed,
}

/// The token screen's subject.
class CounterOrderResult {
  const CounterOrderResult({
    required this.outcome,
    required this.fulfillment,
    required this.paid,
    required this.itemCount,
    required this.total,
    this.totalBeforeTax = false,
    this.token,
    this.orderId,
    this.localRef,
    this.offlineRef,
    this.kotNumber,
  });

  final CounterOutcome outcome;
  final FulfillmentType fulfillment;

  /// Paid at the counter (Pay & Fire), or to pay at pickup (Fire KOT).
  final bool paid;
  final int itemCount;

  /// The bills' total for a paid order; the cart's estimate otherwise.
  final Money total;

  /// [total] is only the items' sum: the desk's total (with tax and
  /// charges) never came, as when the order queued without the desk.
  final bool totalBeforeTax;
  final TokenInfo? token;

  /// Known once the order is on the desk.
  final String? orderId;

  /// "Q-3", for an order queued on this phone.
  final String? localRef;

  /// The emergency slip's reference, when the KOT was printed straight to
  /// the kitchen printer while the desk was away.
  final String? offlineRef;
  final String? kotNumber;

  /// The queued order reached the desk as [orderId], with [token] if its KOT
  /// went too.
  CounterOrderResult landed({required String orderId, TokenInfo? token}) =>
      CounterOrderResult(
        outcome: CounterOutcome.fired,
        fulfillment: fulfillment,
        paid: paid,
        itemCount: itemCount,
        total: total,
        totalBeforeTax: totalBeforeTax,
        token: token ?? this.token,
        orderId: orderId,
        localRef: localRef,
        offlineRef: offlineRef,
        kotNumber: kotNumber,
      );
}

/// What the token screen shows; null when there is nothing to show.
final counterResultProvider = StateProvider<CounterOrderResult?>((_) => null);

/// A Pay & Fire the desk never answered. It may have gone through, so it is
/// kept: the only ways on are to retry it exactly (same request, same id, so
/// the desk replays rather than charges twice) or to drop it on purpose.
class PendingCheckout {
  const PendingCheckout({
    required this.request,
    required this.cart,
    required this.estimate,
    required this.operatorId,
  });

  final QsrCheckoutRequest request;

  /// Who sent it. The desk replays by operator, so another operator's retry
  /// would charge again: it is never theirs.
  final String operatorId;

  /// The cart as it was sent. A confirmed retry clears the cart only if it
  /// is still this one, so nothing added since is lost.
  final List<CartLine> cart;
  final Money estimate;

  int get itemCount => cart.fold<int>(0, (sum, line) => sum + line.qty);
}

/// The unanswered Pay & Fire, its operator's alone: when another operator
/// signs in (or the session is revoked) it is gone, so nobody else retries
/// it. Signing out and back in as the same operator keeps it.
final pendingCheckoutProvider = StateProvider<PendingCheckout?>((ref) {
  ref.watch(operatorProvider.select((op) => op?.id));
  return null;
});

/// `order:create` / `qsr:checkout` items for [cart].
List<Map<String, dynamic>> orderItemsPayload(List<CartLine> cart) => cart
    .map((l) => <String, dynamic>{
          'item_id': l.item.id,
          if (l.variationId != null) 'variation_id': l.variationId,
          'quantity': l.qty,
          'selected_options': l.selectedOptions.map((o) => o.toJson()).toList(),
          if (l.selectedAddons.isNotEmpty)
            'selected_addons': l.selectedAddons.map((g) => g.toJson()).toList(),
          if (l.weight != null) 'weight': l.weight,
          'notes': l.itemNote,
        })
    .toList();

/// The Counter home's list.
///
/// With tokens: today's tokens not yet collected (paid and cooking, ready,
/// or waiting to be paid at pickup), by number. Without: today's counter
/// orders still to be paid, oldest first. "Today" is the latest business day
/// among them.
List<HistoryOrder> openCounterOrders(
  List<HistoryOrder> history, {
  required bool tokens,
}) {
  final open = <HistoryOrder>[
    for (final o in history)
      if (o.status != OrderStatus.cancelled &&
          (tokens
              ? o.tokenLabel != null && o.tokenStatus != TokenStatus.collected
              : o.fulfillmentType != null && o.status != OrderStatus.paid))
        o,
  ];
  String? today;
  for (final o in open) {
    if (o.date.isNotEmpty && (today == null || o.date.compareTo(today) > 0)) {
      today = o.date;
    }
  }
  final list = <HistoryOrder>[
    for (final o in open)
      if (today == null || o.date == today) o,
  ];
  if (tokens) {
    list.sort((a, b) {
      final byNumber = (tokenNumberOf(a.tokenLabel!) ?? 0)
          .compareTo(tokenNumberOf(b.tokenLabel!) ?? 0);
      return byNumber != 0 ? byNumber : a.tokenLabel!.compareTo(b.tokenLabel!);
    });
  } else {
    list.sort((a, b) => a.time.compareTo(b.time));
  }
  return list;
}

final openCounterOrdersProvider = Provider<List<HistoryOrder>>((ref) =>
    openCounterOrders(ref.watch(historyProvider),
        tokens: ref.watch(flagsProvider.select((f) => f.orderTokens))));

/// The token the desk has since given [orderId], from the live order or its
/// history entry; null while it has none.
TokenInfo? liveTokenFor(
  String orderId, {
  required List<ServerOrder> active,
  required List<HistoryOrder> history,
}) {
  for (final o in active) {
    if (o.id == orderId && o.token != null) return o.token;
  }
  for (final h in history) {
    final label = h.tokenLabel;
    if (h.orderId == orderId && label != null) {
      return TokenInfo(
          label: label, status: h.tokenStatus ?? TokenStatus.unknown);
    }
  }
  return null;
}

/// The counter orders waiting in this phone's outbox, re-read whenever the
/// outbox changes.
final queuedCounterOrdersProvider =
    FutureProvider<List<QueuedCounterOrder>>((ref) {
  ref.watch(outboxPendingCountProvider);
  return ref.read(offlineOrderQueueProvider).queuedCounterOrders();
});

/// Watches queued counter orders reach the desk. Tells the cashier "Q-3 →
/// Token #42", and turns the token screen over when it is showing that
/// order. Read once by the counter screens; it then lives with the app.
final counterReplayWatcherProvider = Provider<void>((ref) {
  final sub = ref.read(offlineOrderQueueProvider).replayed.listen((replayed) {
    final localRef = replayed.localRef;
    if (localRef == null) return;
    final token = replayed.token;
    logD(_tag, 'a queued counter order reached the desk');
    ref.read(counterNoticeProvider.notifier).state = CounterNotice(
      token == null
          ? '$localRef reached the desk — its token comes with the KOT'
          : '$localRef → Token ${tokenDisplay(token.label)}',
      kind: ToastKind.success,
    );
    final shown = ref.read(counterResultProvider);
    if (shown != null && shown.localRef == localRef) {
      ref.read(counterResultProvider.notifier).state =
          shown.landed(orderId: replayed.orderId, token: token);
    }
  });
  ref.onDispose(sub.cancel);
});
