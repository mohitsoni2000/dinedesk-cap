import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/counter_providers.dart';
import '../data/currency.dart';
import '../data/money.dart';
import '../data/parked_providers.dart' show moneyScopeProvider;
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../models/pay_mode.dart';
import '../models/token.dart';
import '../services/entry_ticket_service.dart' show refusedCovers;
import '../services/kot_queue_service.dart';
import '../services/log.dart';
import '../services/offline_guard.dart';
import '../services/offline_kot_coordinator.dart';
import '../services/offline_order_queue_service.dart';
import '../services/pending_money_store.dart';
import '../services/pin_guard.dart';
import '../services/qsr_checkout_service.dart';
import '../theme/tokens.dart';
import '../utils/request_id.dart';
import '../utils/tender_allocation.dart';
import '../widgets/app_card.dart';
import '../widgets/cart_row.dart';
import '../widgets/counter_notices.dart';
import '../widgets/counter_park_actions.dart';
import '../widgets/cover_redeem_section.dart';
import '../widgets/desk_offline_strip.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/tender_form.dart';
import '../widgets/token_badge.dart';

const String _tag = '[Counter]';

/// Applies a Pay & Fire the desk confirmed: the order into history, the
/// token for the token screen, the receipts to the printer, the cart cleared
/// if it is still the one [attempt] sent, and nothing kept any more (here or
/// on the phone). Works off [container] so a screen that went away meanwhile
/// cannot drop a charge the desk took.
void applyPayAndFire(
  ProviderContainer container,
  QsrCheckoutAck ack, {
  required PendingCheckout attempt,
}) {
  final request = attempt.request;
  final sentCart = attempt.cart;
  container
      .read(syncServiceProvider)
      .applyOrderAck(ack.raw, includeHistory: true);
  container.read(lastKotIdProvider.notifier).state = ack.kotNumber;
  container.read(lastTokenProvider.notifier).state = ack.token;
  if (container.read(flagsProvider).billPrinting) {
    // The guest's receipt: it carries the token and the pickup line.
    final socket = container.read(socketServiceProvider);
    for (final bill in ack.bills) {
      socket.emit('print:bill', <String, dynamic>{'bill_id': bill.id});
    }
  }
  if (identical(container.read(cartProvider), sentCart)) {
    container.read(cartProvider.notifier).clear();
    container.read(orderNotesProvider.notifier).state = '';
  }
  unawaited(container.read(pendingCheckoutProvider.notifier).settle(attempt));
  for (final line in request.payments) {
    if (line.isCover) continue;
    container.read(lastCounterPayModeProvider.notifier).state = line.mode;
    break;
  }
  container.read(counterResultProvider.notifier).state = CounterOrderResult(
    outcome: CounterOutcome.fired,
    fulfillment: request.fulfillment,
    paid: true,
    itemCount: attempt.itemCount,
    total: ack.bills.isEmpty ? attempt.estimate : ack.total,
    token: ack.token,
    orderId: ack.orderId,
    kotNumber: ack.kotNumber,
  );
}

/// Sends the kept Pay & Fire again, exactly as it went (same request, same
/// id): if the first one landed, the desk replays it instead of charging
/// twice.
///
/// Only a business refusal proves it never went through, so only that drops
/// the attempt. Any other refusal keeps it, as unanswered; one that wants
/// the PIN raises the PIN prompt, so the next Retry can go.
Future<QsrCheckoutResult> retryPendingCheckout(
    ProviderContainer container, PendingCheckout pending) async {
  // Never under another operator's name: the desk would charge again.
  // Theirs stays on the phone for them.
  if (pending.operatorId != container.read(operatorProvider)?.id) {
    return const QsrCheckoutRejected(
      code: kOtherOperatorCode,
      message: 'Another operator started that order, so it was set aside. '
          'Check the desk before charging it again.',
    );
  }
  final result = await container.read(qsrCheckoutServiceProvider).payAndFire(
        pending.request,
      );
  switch (result) {
    case QsrCheckoutOk(:final ack):
      applyPayAndFire(container, ack, attempt: pending);
    case QsrCheckoutRejected(isBusinessRefusal: true):
      unawaited(
          container.read(pendingCheckoutProvider.notifier).settle(pending));
    case QsrCheckoutRejected(needsPin: true):
      unawaited(container.read(syncServiceProvider).handleReauthRequired());
    case QsrCheckoutRejected() ||
          QsrCheckoutUnconfirmed() ||
          QsrCheckoutOffline():
      break;
  }
  return result;
}

/// What the cashier is told when a retried Pay & Fire is refused: nothing
/// was charged only when the refusal proves it.
String retryRefusalCopy(QsrCheckoutRejected refused) =>
    refused.code == kOtherOperatorCode
        ? refused.message
        : refused.isBusinessRefusal
            ? '${refused.message}. Nothing was charged.'
            : kCheckoutNoAnswer;

/// Runs [work] behind the money overlay. The overlay closes when [work]
/// ends, however it ends, and its result or error comes back to the caller.
Future<T> runBehindMoneyOverlay<T>(
  BuildContext context,
  Future<T> work, {
  required String title,
  required String subtitle,
  Duration timeout = OrderSubmittingOverlay.moneyTimeout,
}) async {
  final done = Completer<bool>();
  unawaited(work.then((_) {
    if (!done.isCompleted) done.complete(true);
  }, onError: (Object _) {
    if (!done.isCompleted) done.complete(false);
  }));
  await OrderSubmittingOverlay.show(context,
      completer: done, timeout: timeout, title: title, subtitle: subtitle);
  return work;
}

/// `order:preview-totals` items for [cart], amounts in rupees.
List<Map<String, dynamic>> _previewItems(List<CartLine> cart) => cart
    .map((l) => <String, dynamic>{
          'item_id': l.item.id,
          'item_type': l.item.kitchenSection,
          'total_price': l.lineTotal.toWire(),
        })
    .toList();

/// Counter checkout: the cart, a note, an optional customer, the desk's
/// total, and the actions the desk's payment flow allows.
///
/// - **Pay & Fire** (prepaid, needs the desk): one `qsr:checkout` takes the
///   payment, fires the KOT and gives the token. The tenders come from the
///   shared tender form with no bill yet: each cover ticket carries the
///   amount shown for it (its balance, up to what the estimate leaves, in
///   the order added), and the last tender carries none, so the desk fills
///   it; the screen shows an estimate and the ack the real figures. A
///   ticket whose cover changed since its scan is refused (`cover_changed`),
///   never quietly made up by the other tender.
/// - **Fire KOT** (pay at pickup): `order:create` + `kot:send` through the
///   offline queue, so it still goes, queued, when the desk is away.
class CounterCheckoutScreen extends ConsumerStatefulWidget {
  const CounterCheckoutScreen({super.key});

  @override
  ConsumerState<CounterCheckoutScreen> createState() =>
      _CounterCheckoutScreenState();
}

class _CounterCheckoutScreenState extends ConsumerState<CounterCheckoutScreen> {
  final TenderFormController _tender = TenderFormController();
  final List<AppliedCover> _covers = <AppliedCover>[];
  late final TextEditingController _notes =
      TextEditingController(text: ref.read(orderNotesProvider));
  Map<String, dynamic>? _customer;

  /// The desk's total for the cart (`order:preview-totals`); null until it
  /// answers.
  Money? _estimate;
  bool _estimateFailed = false;
  int _previewSeq = 0;
  Timer? _previewDebounce;

  bool _busy = false;

  /// One Fire KOT's ids, kept across retries until it goes or queues.
  String? _fireOrderRequestId;
  String? _fireKotRequestId;
  OfflineKotAttempt? _offlinePrint;

  @override
  void initState() {
    super.initState();
    // Before the listener: a pick made here needs no rebuild (and initState
    // may not ask for one).
    _preselectLastMode();
    _tender.addListener(_onTenderChanged);
    _notes.addListener(
        () => ref.read(orderNotesProvider.notifier).state = _notes.text.trim());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _schedulePreview(ref.read(cartProvider), now: true);
    });
  }

  void _onTenderChanged() {
    if (mounted) setState(() {});
  }

  /// The mode the counter charged with last time, when it needs nothing typed.
  void _preselectLastMode() {
    final code = ref.read(lastCounterPayModeProvider);
    if (code == null) return;
    final modes = payModeCatalog(
        flags: ref.read(flagsProvider), listed: ref.read(payModesProvider));
    for (final mode in modes) {
      if (mode.code != code) continue;
      if (!mode.needsReference && !mode.asksModeReason) _tender.select(mode);
      return;
    }
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _tender.removeListener(_onTenderChanged);
    _tender.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _schedulePreview(List<CartLine> cart, {bool now = false}) {
    _previewDebounce?.cancel();
    if (cart.isEmpty) {
      setState(() {
        _estimate = null;
        _estimateFailed = false;
      });
      return;
    }
    _previewDebounce = Timer(
        now ? Duration.zero : const Duration(milliseconds: 250),
        () => unawaited(_fetchPreview(cart)));
  }

  /// Asks the desk what [cart] comes to; returns it, or null when it could
  /// not.
  Future<Money?> _fetchPreview(List<CartLine> cart) async {
    final seq = ++_previewSeq;
    final ack = await ref.read(socketServiceProvider).emitAck(
        'order:preview-totals',
        <String, dynamic>{'items': _previewItems(cart)});
    if (!mounted || seq != _previewSeq) return null;
    final totals = ack['kind'] == 'success' ? ack['totals'] : null;
    final total = totals is Map ? Money.fromWire(totals['totalAmount']) : null;
    setState(() {
      _estimate = total;
      _estimateFailed = total == null;
    });
    return total;
  }

  bool get _coverOn =>
      canRedeemCover(ref.read(flagsProvider), ref.read(ticketConfigProvider));

  /// Covers, tenders and the note can change: nothing kept or in flight.
  bool get _editable => ref.read(pendingCheckoutProvider) == null && !_busy;

  /// The staged tickets at what they pay now: each its balance, up to what
  /// the estimate still leaves, in the order added. The chips, the totals
  /// and Pay & Fire all use these, so what is sent is what was shown.
  List<AppliedCover> get _activeCovers => _coverOn
      ? planCovers(_covers, _estimate ?? _subtotal)
      : const <AppliedCover>[];

  Money get _subtotal =>
      ref.read(cartProvider).map((l) => l.lineTotal).sumMoney();

  /// What the tenders must cover, by the estimate: the total less cover.
  Money get _tenderDue {
    final due = (_estimate ?? _subtotal) -
        _activeCovers.map((c) => c.amount).sumMoney();
    return due.isNegative ? Money.zero : due;
  }

  /// The Pay & Fire request for what is on screen, or null (with a toast
  /// saying why) when it is not ready.
  QsrCheckoutRequest? _buildRequest() {
    final cart = ref.read(cartProvider);
    final estimate = _estimate;
    if (cart.isEmpty) return null;
    if (estimate == null) {
      DynamicToast.warning(context, 'Wait for the total from the desk');
      return null;
    }
    final flags = ref.read(flagsProvider);
    final coverMode = ref.read(ticketConfigProvider).coverPaymentMode;
    var pay = const <TenderLine>[];
    if (_tenderDue.isPositive) {
      if (_tender.creditBlocked(hasCustomer: _customer != null)) {
        DynamicToast.error(
            context, 'Link a customer before using Credit payment');
        return null;
      }
      if (flags.splitPayment &&
          _tender.splits.isNotEmpty &&
          !_tender.splitsCover(_tenderDue)) {
        DynamicToast.error(context,
            'Add a payment for the remaining ${formatRupeesCompact(_tenderDue - _tender.splitTotal)}');
        return null;
      }
      final lines = _tender.lines(
          due: _tenderDue, splitMode: flags.splitPayment, fill: true);
      if (lines == null || lines.isEmpty) {
        DynamicToast.error(
            context,
            _tender.selected == null
                ? 'Pick a payment mode first'
                : 'Fill in what ${_tender.selected!.label} needs first');
        return null;
      }
      // The desk fills the last tender from the real bill, so an estimate is
      // never short or over.
      pay = <TenderLine>[
        ...lines.take(lines.length - 1),
        lines.last.withAmount(null),
      ];
    }
    return QsrCheckoutRequest(
      fulfillment: ref.read(counterFulfillmentProvider),
      items: orderItemsPayload(cart),
      payments: <TenderLine>[
        // Each at the amount shown; a ticket the estimate leaves nothing
        // for is not sent.
        if (coverMode != null)
          for (final cover in _activeCovers)
            if (cover.amount.isPositive) cover.toLine(coverMode),
        ...pay,
      ],
      notes: _notes.text,
      customerId: _customer?['id']?.toString(),
      expectedTotal: estimate,
    );
  }

  Future<void> _payAndFire() async {
    if (_busy) return;
    final pending = ref.read(pendingCheckoutProvider);
    if (pending != null) {
      await _retry(pending);
      return;
    }
    if (isDeskOffline(ref)) {
      await _offerParkOffline();
      return;
    }
    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;
    final request = _buildRequest();
    if (request == null) return;
    // Busy until the whole attempt is over, a changed total's question and
    // its resend included: no second attempt, no stacked dialogs.
    setState(() => _busy = true);
    try {
      await _send(request);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// One attempt; the caller holds [_busy].
  Future<void> _send(QsrCheckoutRequest request) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final scope = container.read(moneyScopeProvider);
    final attempt = PendingCheckout(
      request: request,
      cart: ref.read(cartProvider),
      estimate: request.expectedTotal ?? _subtotal,
      operatorId: scope?.operatorId ?? '',
      desk: scope?.deskInstanceId ?? '',
    );
    PendingMoneyNotifier<PendingCheckout> pending() =>
        container.read(pendingCheckoutProvider.notifier);
    // On the phone before it goes: a crash, a restart or a sign-out while
    // the desk answers cannot lose its id.
    await pending().writeAhead(attempt);
    if (!mounted) {
      unawaited(pending().settle(attempt));
      return;
    }
    final result = await runBehindMoneyOverlay(
      context,
      container.read(qsrCheckoutServiceProvider).payAndFire(request),
      title: 'Taking payment…',
      subtitle: 'The kitchen gets the KOT once it is paid',
    );
    switch (result) {
      case QsrCheckoutOk(:final ack):
        applyPayAndFire(container, ack, attempt: attempt);
        if (mounted) context.go('/counter/order/token');
      case QsrCheckoutRejected(isBusinessRefusal: true):
        unawaited(pending().settle(attempt));
        if (!mounted) return;
        if (result.priceChanged) {
          await _onPriceChanged(request, result);
        } else {
          _dropRefusedCovers(request, result);
          DynamicToast.error(context, result.message);
        }
      case QsrCheckoutUnconfirmed() || QsrCheckoutRejected():
        // No answer, or a refusal that does not prove nothing happened: it
        // may have gone through. Keep it, exactly, for the retry.
        if (result case QsrCheckoutRejected(needsPin: true)) {
          unawaited(container.read(syncServiceProvider).handleReauthRequired());
        }
        pending().hold(attempt);
        container.read(counterResultProvider.notifier).state =
            CounterOrderResult(
          outcome: CounterOutcome.unconfirmed,
          fulfillment: request.fulfillment,
          paid: true,
          itemCount: attempt.itemCount,
          total: attempt.estimate,
        );
        if (mounted) context.go('/counter/order/token');
      case QsrCheckoutOffline():
        // Never sent.
        unawaited(pending().settle(attempt));
        if (mounted) await _offerParkOffline();
    }
  }

  /// A refusal about a cover ticket itself (its cover changed or ran out
  /// elsewhere, it was cancelled…): nothing was charged, so that ticket
  /// comes off the payment, to be scanned again at what it has now.
  void _dropRefusedCovers(
      QsrCheckoutRequest request, QsrCheckoutRejected refused) {
    final codes = <String?>{
      for (final line in request.payments)
        if (line.isCover) line.ticketCode,
    };
    final drop = refusedCovers(
      code: refused.code,
      refusal: refused.message,
      sent: <AppliedCover>[
        for (final cover in _covers)
          if (codes.contains(cover.code)) cover,
      ],
    );
    if (drop.isEmpty) return;
    logD(_tag,
        '${drop.length} cover ticket(s) taken off after a ${refused.code} refusal');
    setState(() => _covers.removeWhere(drop.contains));
  }

  /// The desk's bill came to another total than the one shown: show it, and
  /// charge it only once the cashier says so (a new attempt).
  Future<void> _onPriceChanged(
      QsrCheckoutRequest request, QsrCheckoutRejected rejected) async {
    final fresh =
        rejected.newTotal ?? await _fetchPreview(ref.read(cartProvider));
    if (!mounted) return;
    if (fresh == null || fresh == request.expectedTotal) {
      DynamicToast.error(context,
          "${rejected.message}. The desk's total can't be read here — check it at the desk.");
      return;
    }
    setState(() => _estimate = fresh);
    final charge = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('The total changed', style: AppTypography.title),
        content: Text(
            "The desk's total is now ${formatRupees(fresh)} (this phone "
            'showed ${formatRupees(request.expectedTotal ?? Money.zero)}). '
            'Charge ${formatRupees(fresh)}?',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Charge ${formatRupeesCompact(fresh)}'),
          ),
        ],
      ),
    );
    if (charge != true || !mounted) return;
    // Built again for the new total: the cover tickets re-planned against
    // it, so each still goes at the amount the screen now shows.
    final again = _buildRequest();
    if (again != null) await _send(again);
  }

  Future<void> _retry(PendingCheckout pending) async {
    if (isDeskOffline(ref)) {
      DynamicToast.warning(context, kNeedsDeskMessage);
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _busy = true);
    QsrCheckoutResult? result;
    try {
      result = await runBehindMoneyOverlay(
        context,
        retryPendingCheckout(container, pending),
        title: 'Checking with the desk…',
        subtitle: 'Sending the same order again',
      );
    } catch (error) {
      // The desk answered but this phone could not take it in; the attempt
      // stays kept unless it was settled, so Retry asks again.
      logE(
          _tag, 'a retried pay & fire could not be applied', error.runtimeType);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    switch (result) {
      case QsrCheckoutOk():
        context.go('/counter/order/token');
      case QsrCheckoutRejected():
        if (result.isBusinessRefusal) {
          _dropRefusedCovers(pending.request, result);
        }
        DynamicToast.error(context, retryRefusalCopy(result));
      case QsrCheckoutUnconfirmed() || null:
        DynamicToast.warning(context, kCheckoutNoAnswer);
      case QsrCheckoutOffline():
        DynamicToast.warning(context, kNeedsDeskMessage);
    }
  }

  /// Drops the unanswered attempt on purpose, after a warning: if it did go
  /// through, charging again takes the money twice.
  Future<void> _dropPending(PendingCheckout pending) async {
    final drop = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('Drop this Pay & Fire?', style: AppTypography.title),
        content: const Text(
            'Only if the desk shows no such order. If it went through, '
            'charging again takes the money twice.',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Drop it',
                style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (drop != true || !mounted) return;
    logD(_tag, 'an unanswered pay & fire was dropped by the cashier');
    unawaited(ref.read(pendingCheckoutProvider.notifier).settle(pending));
  }

  /// Pay & Fire needs the desk; money never queues. Offer to park the cart.
  Future<void> _offerParkOffline() async {
    final park = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title:
            const Text('The desk is not reachable', style: AppTypography.title),
        content: const Text(
            'Pay & Fire needs the desk. Park this cart and charge it when '
            'the desk is back.',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Park cart'),
          ),
        ],
      ),
    );
    if (park != true || !mounted) return;
    final label = await parkCounterCart(context, ref);
    if (label != null && mounted) _back();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/counter/order');
    }
  }

  /// Runs when the KOT is about to be parked in the outbox: puts it on the
  /// kitchen printer straight away, and hands the outbox what the desk must
  /// know so it does not print it again. The slip says Takeaway or
  /// Standing, as the order leaves.
  BeforeQueueHook _directPrintHook(
      List<CartLine> cart, String notes, FulfillmentType fulfillment) {
    final coordinator = ref.read(offlineKotCoordinatorProvider);
    return () async {
      final attempt = await coordinator.printForQueuedKot(
        cart: cart,
        slotId: '',
        isRoom: false,
        isTakeaway: true,
        orderNotes: notes,
        fulfillment: fulfillment,
      );
      _offlinePrint = attempt;
      return attempt.fields;
    };
  }

  /// Fire now, pay at pickup: `order:create` with how it leaves, then its
  /// KOT, through the offline queue.
  Future<void> _fire() async {
    if (_busy) return;
    final pinOk = isDeskOffline(ref)
        ? true
        : await requirePinIfNeeded(context, ref, 'kot');
    if (!pinOk || !mounted) return;
    final cart = ref.read(cartProvider);
    if (cart.isEmpty) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final fulfillment = ref.read(counterFulfillmentProvider);
    final notes = _notes.text.trim();
    final itemCount = cart.fold<int>(0, (sum, line) => sum + line.qty);
    // Without the desk's estimate (the usual case when it is away) the total
    // is only the items' sum, and says so.
    final beforeTax = _estimate == null;
    final total = _estimate ?? _subtotal;
    final socket = ref.read(socketServiceProvider);
    _offlinePrint = null;
    final orderRequestId = _fireOrderRequestId ??= newRequestId();
    final kotRequestId = _fireKotRequestId ??= newRequestId();
    setState(() => _busy = true);
    OrderSubmitResult? result;
    try {
      result = await runBehindMoneyOverlay(
        context,
        container.read(offlineOrderQueueProvider).submitOrder(
              socket,
              orderEvent: 'order:create',
              orderPayload: <String, dynamic>{
                'items': orderItemsPayload(cart),
                'notes': notes,
                'order_type': 'takeaway',
                'fulfillment_type': fulfillment.wire,
                if (_customer?['id'] != null) 'customer_id': _customer!['id'],
              },
              orderRequestId: orderRequestId,
              kotRequestId: kotRequestId,
              beforeQueue: _directPrintHook(cart, notes, fulfillment),
              meta: QueuedCounterOrder.meta(
                  itemCount: itemCount, total: total, fulfillment: fulfillment),
            ),
        title: 'Sending to kitchen…',
        subtitle: 'Payment at pickup',
        timeout: OrderSubmittingOverlay.defaultTimeout,
      );
    } catch (error) {
      logE(_tag, 'fire failed', error.runtimeType);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (result == null || result.isRejected) {
      if (!mounted) return;
      final refused = result?.orderAck['kind'] == 'error'
          ? result?.orderAck['message']
          : result?.kotAck['message'];
      DynamicToast.error(
          context,
          refused == null
              ? "Couldn't send the order — try again"
              : 'The desk refused it: $refused');
      return;
    }
    _fireOrderRequestId = null;
    _fireKotRequestId = null;
    final offlineRef = _offlinePrint?.fields['offline_ref']?.toString();
    final CounterOrderResult shown;
    if (result.isQueued) {
      shown = CounterOrderResult(
        outcome: CounterOutcome.queued,
        fulfillment: fulfillment,
        paid: false,
        itemCount: itemCount,
        total: total,
        totalBeforeTax: beforeTax,
        localRef: result.localRef,
        offlineRef: offlineRef,
      );
      container.read(counterReplayWatcherProvider);
    } else {
      final sync = container.read(syncServiceProvider);
      sync.applyOrderAck(result.orderAck, includeHistory: true);
      final kotWent = result.kotAck['kind'] != 'queued';
      if (kotWent) sync.applyOrderAck(result.kotAck, includeHistory: true);
      final token = TokenInfo.fromAck(result.kotAck) ??
          TokenInfo.fromAck(result.orderAck);
      final orderMap = result.orderAck['order'];
      final kotMap = result.kotAck['kot'];
      final kotNumber = kotMap is Map ? kotMap['kot_number']?.toString() : null;
      container.read(lastKotIdProvider.notifier).state = kotNumber;
      container.read(lastTokenProvider.notifier).state = token;
      // The desk prints the KOT, unless this phone already did.
      if (kotWent && !(_offlinePrint?.printedAnything ?? false)) {
        final orderId = orderMap is Map ? orderMap['id']?.toString() : null;
        if (orderId != null) {
          // As the table flow: a refused print is the only sign the kitchen
          // has no slip. This screen is gone by then, so the counter screen
          // that is up says it (CounterNotices).
          socket.emit('print:kot', <String, dynamic>{'order_id': orderId},
              onAck: (response) {
            if (response['kind'] != 'error') return;
            container.read(counterNoticeProvider.notifier).state =
                CounterNotice(response['message']?.toString() ??
                    'KOT print failed — check the kitchen printer');
          });
        }
      }
      shown = CounterOrderResult(
        outcome: CounterOutcome.fired,
        fulfillment: fulfillment,
        paid: false,
        itemCount: itemCount,
        total: total,
        totalBeforeTax: beforeTax,
        token: token,
        orderId: orderMap is Map ? orderMap['id']?.toString() : null,
        kotNumber: kotNumber,
        offlineRef: offlineRef,
      );
    }
    if (identical(container.read(cartProvider), cart)) {
      container.read(cartProvider.notifier).clear();
      container.read(orderNotesProvider.notifier).state = '';
    }
    container.read(counterResultProvider.notifier).state = shown;
    if (mounted) context.go('/counter/order/token');
  }

  Future<void> _linkCustomer() async {
    final picked = await ref
        .read(customerLinkServiceProvider)
        .pickAndLinkCustomer(context);
    if (picked != null && mounted) setState(() => _customer = picked);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<List<CartLine>>(
        cartProvider, (_, next) => _schedulePreview(next));
    final cart = ref.watch(cartProvider);
    final flags = ref.watch(flagsProvider);
    final qsr = ref.watch(qsrConfigProvider);
    final fulfillment = ref.watch(counterFulfillmentProvider);
    final pending = ref.watch(pendingCheckoutProvider);
    final coverOn = canRedeemCover(flags, ref.watch(ticketConfigProvider));
    final canCharge = qsr.canPayNow && flags.collectPayment;
    final canFire = qsr.canPayLater;
    final estimate = _estimate;
    final covers = _activeCovers;
    final covered = covers.map((c) => c.amount).sumMoney();
    final coverPaysAll = covers.isNotEmpty && _tenderDue.isZero;
    final editable = pending == null && !_busy;
    // Rebuilt when the link drops or returns; read on every build: a tap
    // without the desk says so and offers to park.
    ref.watch(connectionProvider.select((c) => c.online));
    final offline = isDeskOffline(ref);

    final bool payReady;
    if (pending != null) {
      payReady = !_busy;
    } else if (_busy || cart.isEmpty) {
      payReady = false;
    } else if (offline) {
      payReady = true;
    } else if (estimate == null) {
      payReady = false;
    } else if (coverPaysAll) {
      payReady = true;
    } else if (flags.splitPayment && _tender.splits.isNotEmpty) {
      payReady = _tender.splitsCover(_tenderDue);
    } else {
      payReady = _tender.selectedComplete &&
          !_tender.creditBlocked(hasCustomer: _customer != null);
    }

    final Widget actions = Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + context.sheetBottomInset),
      child: pending != null
          ? Row(children: [
              Expanded(
                child: LiquidSecondaryButton(
                  label: 'Drop it',
                  leadingIcon: Icons.delete_outline,
                  onPressed: _busy ? null : () => _dropPending(pending),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LiquidPrimaryButton(
                  label: 'Retry Pay & Fire',
                  leadingIcon: Icons.refresh,
                  fullWidth: true,
                  onPressed: payReady ? _payAndFire : null,
                ),
              ),
            ])
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!canCharge && !canFire)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      'This counter takes payment first, and your role '
                      "can't take payment. Ask a cashier to charge it.",
                      textAlign: TextAlign.center,
                      style: AppTypography.caption
                          .copyWith(color: context.palette.ink70),
                    ),
                  ),
                if (canFire)
                  canCharge
                      ? LiquidSecondaryButton(
                          label: 'Fire KOT · pay at pickup',
                          leadingIcon: Icons.local_fire_department_outlined,
                          onPressed: _busy || cart.isEmpty ? null : _fire,
                        )
                      : LiquidPrimaryButton(
                          label: 'Fire KOT · pay at pickup',
                          leadingIcon: Icons.local_fire_department_outlined,
                          fullWidth: true,
                          onPressed: _busy || cart.isEmpty ? null : _fire,
                        ),
                if (canFire && canCharge) const SizedBox(height: 8),
                if (canCharge)
                  LiquidPrimaryButton(
                    label: estimate == null
                        ? (_estimateFailed || offline
                            ? 'Pay & Fire'
                            : 'Calculating total…')
                        : 'Pay & Fire ${formatRupeesCompact(estimate)}',
                    leadingIcon: Icons.payments_outlined,
                    fullWidth: true,
                    onPressed: payReady ? _payAndFire : null,
                  ),
              ],
            ),
    );

    return ColoredBox(
      color: context.palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      icon:
                          Icon(Icons.arrow_back, color: context.palette.ink70),
                      onPressed: _busy ? null : _back,
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Text('Checkout', style: AppTypography.sheetTitle),
                    ),
                    FulfillmentChip(
                        type: pending?.request.fulfillment ?? fulfillment),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    if (offline) ...[
                      DeskOfflineStrip(
                          message: counterOfflineMessage(
                              canCharge: canCharge, canFire: canFire)),
                      const SizedBox(height: 12),
                    ],
                    if (pending != null)
                      _PendingCheckoutCard(pending: pending)
                    else if (cart.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(children: [
                          Icon(Icons.shopping_basket_outlined,
                              size: 48, color: context.palette.ink30),
                          const SizedBox(height: 12),
                          const Text('Cart is empty',
                              style: AppTypography.title),
                        ]),
                      )
                    else ...[
                      if (flags.customers) ...[
                        AppCard(
                          onTap: _customer == null ? _linkCustomer : null,
                          child: Row(children: [
                            Icon(
                                _customer == null
                                    ? Icons.person_add_outlined
                                    : Icons.person,
                                size: 20,
                                color: _customer == null
                                    ? context.palette.ink70
                                    : AppColors.terra600),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _customer == null
                                    ? 'Add customer (optional)'
                                    : _customer!['name']?.toString() ??
                                        'Customer',
                                style: AppTypography.bodyMd,
                              ),
                            ),
                            if (_customer != null)
                              IconButton(
                                tooltip: 'Remove customer',
                                visualDensity: VisualDensity.compact,
                                onPressed: editable
                                    ? () => setState(() => _customer = null)
                                    : null,
                                icon: Icon(Icons.close,
                                    size: 18, color: context.palette.ink50),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],
                      AppCard(
                        padding: EdgeInsets.zero,
                        child: Column(children: [
                          for (var i = 0; i < cart.length; i++) ...[
                            CartRow(line: cart[i], index: i),
                            if (i < cart.length - 1)
                              Divider(height: 1, color: context.palette.ink10),
                          ],
                        ]),
                      ),
                      const SizedBox(height: 12),
                      AppCard(
                        child: TextField(
                          controller: _notes,
                          enabled: editable,
                          maxLines: 2,
                          maxLength: 500,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Order note (allergies, packing…)',
                            isDense: true,
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _TotalsCard(
                        subtotal: _subtotal,
                        estimate: estimate,
                        failed: _estimateFailed,
                        covered: covered,
                        onRetry: () =>
                            unawaited(_fetchPreview(ref.read(cartProvider))),
                      ),
                      if (canCharge) ...[
                        if (coverOn)
                          CoverRedeemSection(
                            // At what each pays now, as Pay & Fire sends it.
                            covers: covers,
                            coverable: estimate == null
                                ? Money.zero
                                : (estimate - covered).isNegative
                                    ? Money.zero
                                    : estimate - covered,
                            enabled: editable,
                            // A lookup may answer after Pay & Fire locked
                            // the screen: nothing is added under it.
                            onAdd: (cover) {
                              if (_editable) {
                                setState(() => _covers.add(cover));
                              }
                            },
                            onRemove: (cover) {
                              if (_editable) {
                                setState(() => _covers
                                    .removeWhere((c) => c.key == cover.key));
                              }
                            },
                          ),
                        if (coverPaysAll) ...[
                          const SizedBox(height: 12),
                          const Row(children: [
                            Icon(Icons.check_circle_outline,
                                color: AppColors.success, size: 18),
                            SizedBox(width: 8),
                            Text('Cover pays it all, by the estimate',
                                style: AppTypography.bodyMd),
                          ]),
                        ] else ...[
                          const SizedBox(height: 4),
                          TenderForm(
                            controller: _tender,
                            modes: payModeCatalog(
                                flags: flags,
                                listed: ref.watch(payModesProvider)),
                            due: _tenderDue,
                            allowSplit: flags.splitPayment,
                            hasCustomer: _customer != null,
                            enabled: editable,
                          ),
                        ],
                      ],
                    ],
                  ],
                ),
              ),
              actions,
              const CounterNotices(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The estimate: the items, then the desk's total (GST and charges in).
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({
    required this.subtotal,
    required this.estimate,
    required this.failed,
    required this.covered,
    required this.onRetry,
  });

  final Money subtotal;
  final Money? estimate;
  final bool failed;
  final Money covered;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final total = estimate;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Text('Items', style: AppTypography.bodyMd),
            const Spacer(),
            Text(formatRupeesCompact(subtotal), style: AppTypography.bodyMd),
          ]),
          if (covered.isPositive) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Text('Cover', style: AppTypography.bodyMd),
              const Spacer(),
              Text('−${formatRupeesCompact(covered)}',
                  style: AppTypography.bodyMd),
            ]),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Text('Total',
                style: AppTypography.title
                    .copyWith(fontWeight: FontWeight.w800, fontSize: 15.5)),
            const Spacer(),
            Text(total == null ? '—' : formatRupees(total),
                style: AppTypography.headline),
          ]),
          const SizedBox(height: 4),
          if (total != null)
            const Text(
                'Estimate with GST and charges — the bill has the final '
                'figures',
                style: AppTypography.caption)
          else if (failed)
            GestureDetector(
              onTap: onRetry,
              child: Text("Couldn't get the total from the desk — tap to retry",
                  style: AppTypography.caption.copyWith(color: AppColors.warn)),
            )
          else
            const Text('Calculating the total…', style: AppTypography.caption),
        ],
      ),
    );
  }
}

/// The Pay & Fire the desk never answered, held for a retry.
class _PendingCheckoutCard extends StatelessWidget {
  const _PendingCheckoutCard({required this.pending});

  final PendingCheckout pending;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      background: AppColors.amber.withValues(alpha: 0.10),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.sync_problem_outlined, color: AppColors.warn, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text('Not confirmed yet', style: AppTypography.title),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(kCheckoutNoAnswer, style: AppTypography.bodyMd),
          const SizedBox(height: 10),
          Text(
            '${pending.itemCount} ${pending.itemCount == 1 ? 'item' : 'items'}'
            ' · ${formatRupeesCompact(pending.estimate)} · '
            '${pending.request.fulfillment.label}',
            style: AppTypography.caption.copyWith(color: context.palette.ink70),
          ),
        ],
      ),
    );
  }
}
