import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/currency.dart';
import '../data/gate_providers.dart';
import '../data/money.dart';
import '../data/parked_providers.dart';
import '../data/providers.dart';
import '../models/parked_draft.dart';
import '../models/pay_mode.dart';
import '../services/entry_ticket_service.dart';
import '../services/log.dart';
import '../services/offline_guard.dart';
import '../services/pin_guard.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/gate/gate_offline_strip.dart';
import '../widgets/gate/ticket_park_actions.dart';
import '../widgets/gate/ticket_type_tile.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/tender_form.dart';

const String _tag = '[Gate]';

/// Selling entry tickets: the types on sale as tiles with counts, the guest
/// (optional), and the payment through the shared tender form, limited to
/// what may pay for a ticket. One `ticket:issue` sells it all; the desk
/// prices it again and refuses a total it does not agree with.
///
/// The sale lives in [ticketIssueFormProvider], so it survives leaving the
/// screen, and can be parked to serve the next guest first. A sale the desk
/// never answered is kept ([pendingTicketIssueProvider]) and locks the form
/// until it is retried (the same request) or dropped on purpose.
class TicketIssueScreen extends ConsumerStatefulWidget {
  const TicketIssueScreen({super.key});

  @override
  ConsumerState<TicketIssueScreen> createState() => _TicketIssueScreenState();
}

class _TicketIssueScreenState extends ConsumerState<TicketIssueScreen> {
  final TenderFormController _tender = TenderFormController();
  late final TextEditingController _guestName =
      TextEditingController(text: ref.read(ticketIssueFormProvider).guestName);
  late final TextEditingController _guestPhone =
      TextEditingController(text: ref.read(ticketIssueFormProvider).guestPhone);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _tender.addListener(_onTenderChanged);
    _guestName.addListener(() {
      final form = ref.read(ticketIssueFormProvider);
      if (form.guestName != _guestName.text) {
        ref.read(ticketIssueFormProvider.notifier).setGuestName(_guestName.text);
      }
    });
    _guestPhone.addListener(() {
      final form = ref.read(ticketIssueFormProvider);
      if (form.guestPhone != _guestPhone.text) {
        ref
            .read(ticketIssueFormProvider.notifier)
            .setGuestPhone(_guestPhone.text);
      }
    });
  }

  void _onTenderChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tender.removeListener(_onTenderChanged);
    _tender.dispose();
    _guestName.dispose();
    _guestPhone.dispose();
    super.dispose();
  }

  List<PayMode> _modes() => ticketPayModes(
        payModeCatalog(
            flags: ref.read(flagsProvider), listed: ref.read(payModesProvider)),
        coverMode: ref.read(ticketConfigProvider).coverPaymentMode,
      );

  /// The sale on screen as a request, or null (with a toast saying why)
  /// when it is not ready.
  TicketIssueRequest? _buildRequest() {
    final form = ref.read(ticketIssueFormProvider);
    final types = ref.read(ticketTypesProvider);
    final lines = form.linesOn(types);
    if (lines.isEmpty) {
      DynamicToast.warning(context, 'Pick the tickets first');
      return null;
    }
    if (!isGuestPhoneValid(form.guestPhone)) {
      DynamicToast.error(context, 'The phone number needs 6 to 20 digits');
      return null;
    }
    final total = form.totalOn(types);
    var pay = const <TenderLine>[];
    if (total.isPositive) {
      final tendered = _tender.lines(
          due: total, splitMode: ref.read(flagsProvider).splitPayment);
      if (tendered == null || tendered.isEmpty) {
        DynamicToast.error(
            context,
            _tender.selected == null
                ? 'Pick a payment mode first'
                : 'Fill in what ${_tender.selected!.label} needs first');
        return null;
      }
      // The last tender takes whatever is left, so a total the desk rounds
      // is never short or over.
      pay = <TenderLine>[
        ...tendered.take(tendered.length - 1),
        tendered.last.withAmount(null),
      ];
    }
    return TicketIssueRequest(
      lines: <TicketIssueLine>[
        for (final line in lines)
          TicketIssueLine(ticketTypeId: line.type.id, qty: line.qty),
      ],
      payments: pay,
      expectedTotal: total,
      guestName: form.guestName.trim(),
      guestPhone: guestPhoneDigits(form.guestPhone),
    );
  }

  Future<void> _issue() async {
    if (_busy) return;
    final pending = ref.read(pendingTicketIssueProvider);
    if (pending != null) {
      await _retry(pending);
      return;
    }
    if (isDeskOffline(ref)) {
      await _offerParkOffline();
      return;
    }
    if (_buildRequest() == null) return;
    final pinOk = await requirePinIfNeeded(context, ref, 'payment');
    if (!pinOk || !mounted) return;
    // Built again: the form may have moved while the PIN sheet was up.
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

  /// Runs [work] behind the money overlay.
  Future<T> _behindOverlay<T>(
    Future<T> work, {
    required String title,
    required String subtitle,
  }) async {
    final done = Completer<bool>();
    unawaited(work.then((_) {
      if (!done.isCompleted) done.complete(true);
    }, onError: (Object _) {
      if (!done.isCompleted) done.complete(false);
    }));
    await OrderSubmittingOverlay.show(context,
        completer: done,
        timeout: OrderSubmittingOverlay.moneyTimeout,
        title: title,
        subtitle: subtitle);
    return work;
  }

  /// One attempt; the caller holds [_busy].
  Future<void> _send(TicketIssueRequest request) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final sentForm = ref.read(ticketIssueFormProvider);
    final summary =
        ticketLinesSummary(sentForm.linesOn(ref.read(ticketTypesProvider)));
    final outcome = await _behindOverlay(
      container.read(entryTicketServiceProvider).issue(request),
      title: 'Issuing tickets…',
      subtitle: 'Waiting for the desk',
    );
    switch (outcome) {
      case TicketIssueOk(:final result):
        applyTicketSale(container, result, sentForm: sentForm);
        _tender.reset();
        if (mounted) context.go('/gate/issue/result');
      case TicketIssueRejected(isBusinessRefusal: true):
        if (!mounted) return;
        if (outcome.priceChanged) {
          await _onPriceChanged(request, outcome);
        } else {
          if (outcome.code == 'type_unavailable') unawaited(_refreshTypes());
          DynamicToast.error(context, outcome.message);
        }
      case TicketIssueUnconfirmed() || TicketIssueRejected():
        // No answer, or a refusal that does not prove nothing happened: it
        // may have gone through. Keep it, exactly, for the retry.
        container.read(pendingTicketIssueProvider.notifier).state =
            PendingTicketIssue(
                request: request, summary: summary, form: sentForm);
        if (mounted) {
          DynamicToast.warning(
              context,
              outcome is TicketIssueRejected && outcome.needsPin
                  ? outcome.message
                  : kIssueNoAnswer);
        }
      case TicketIssueOffline():
        if (mounted) await _offerParkOffline();
      case TicketIssueUnreadable():
        clearTicketFormIfUnchanged(container, sentForm);
        _tender.reset();
        if (mounted) await _showUnreadable();
    }
  }

  /// Asks the desk for its ticket types again (they changed under us).
  Future<bool> _refreshTypes() => ref
      .read(syncServiceProvider)
      .requestResync()
      .timeout(const Duration(seconds: 10), onTimeout: () => false)
      .catchError((Object _) => false);

  /// The desk's prices differ from this phone's: get its ticket types, show
  /// the new total, and sell at it only once the usher says so (a new
  /// attempt).
  Future<void> _onPriceChanged(
      TicketIssueRequest request, TicketIssueRejected rejected) async {
    final refreshed = await _behindOverlay(_refreshTypes(),
        title: 'Getting the new prices…', subtitle: 'Asking the desk');
    if (!mounted) return;
    final form = ref.read(ticketIssueFormProvider);
    final fresh = rejected.newTotal ??
        (refreshed ? form.totalOn(ref.read(ticketTypesProvider)) : null);
    if (fresh == null || fresh == request.expectedTotal) {
      DynamicToast.error(context,
          "${rejected.message}. The desk's total can't be read here — check it at the desk.");
      return;
    }
    final sell = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('The total changed', style: AppTypography.title),
        content: Text(
            "The desk's total is now ${formatRupees(fresh)} (this phone "
            'showed ${formatRupees(request.expectedTotal)}). '
            'Issue the tickets for ${formatRupees(fresh)}?',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text('Issue for ${formatRupeesCompact(fresh)}'),
          ),
        ],
      ),
    );
    if (sell == true && mounted) {
      await _send(request.withExpectedTotal(fresh));
    }
  }

  Future<void> _retry(PendingTicketIssue pending) async {
    if (isDeskOffline(ref)) {
      DynamicToast.warning(context, kNeedsDeskMessage);
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _busy = true);
    final TicketIssueOutcome outcome;
    try {
      outcome = await _behindOverlay(
        retryPendingIssue(container, pending),
        title: 'Checking with the desk…',
        subtitle: 'Sending the same sale again',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    switch (outcome) {
      case TicketIssueOk():
        _tender.reset();
        context.go('/gate/issue/result');
      case TicketIssueRejected():
        DynamicToast.error(context, retryIssueRefusalCopy(outcome));
      case TicketIssueUnconfirmed():
        DynamicToast.warning(context, kIssueNoAnswer);
      case TicketIssueOffline():
        DynamicToast.warning(context, kNeedsDeskMessage);
      case TicketIssueUnreadable():
        _tender.reset();
        await _showUnreadable();
    }
  }

  /// Drops the unanswered sale on purpose, after a warning: if it did go
  /// through, selling again charges the guest twice.
  Future<void> _dropPending() async {
    final drop = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('Drop this sale?', style: AppTypography.title),
        content: const Text(
            'Only if the desk shows no such sale (check Recent). If it went '
            'through, selling again charges the guest twice.',
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
    logD(_tag, 'an unanswered ticket sale was dropped by the usher');
    ref.read(pendingTicketIssueProvider.notifier).state = null;
  }

  Future<void> _showUnreadable() async {
    final recent = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('Check this sale', style: AppTypography.title),
        content: const Text(kIssueUnreadable, style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('OK'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Open Recent'),
          ),
        ],
      ),
    );
    if (recent == true && mounted) await context.push('/gate/recent');
  }

  /// Selling needs the desk; money never queues. Offer to park the sale.
  Future<void> _offerParkOffline() async {
    final park = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title:
            const Text('The desk is not reachable', style: AppTypography.title),
        content: const Text(
            'Issuing tickets needs the desk. Park this sale and finish it '
            'when the desk is back.',
            style: AppTypography.bodyMd),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Park sale'),
          ),
        ],
      ),
    );
    if (park == true && mounted) await parkTicketSale(context, ref);
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/gate');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Resume and clear change the guest from outside these fields.
    ref.listen<TicketIssueForm>(ticketIssueFormProvider, (_, next) {
      if (_guestName.text != next.guestName) _guestName.text = next.guestName;
      if (_guestPhone.text != next.guestPhone) {
        _guestPhone.text = next.guestPhone;
      }
    });
    final flags = ref.watch(flagsProvider);
    final canIssue = flags.entryTickets && flags.ticketIssue;
    final types = ref.watch(ticketTypesProvider);
    final form = ref.watch(ticketIssueFormProvider);
    final pending = ref.watch(pendingTicketIssueProvider);
    final parked = ref.watch(parkedCountProvider(ParkedKind.ticketIssue));
    ref.watch(payModesProvider);
    ref.watch(connectionProvider.select((c) => c.online));
    final offline = isDeskOffline(ref);
    final lines = form.linesOn(types);
    final units = lines.fold<int>(0, (sum, line) => sum + line.qty);
    final total = form.totalOn(types);
    final missing = form.missingOn(types);
    final editable = pending == null && !_busy;
    final phoneOk = isGuestPhoneValid(form.guestPhone);
    final palette = context.palette;

    final bool issueReady;
    if (pending != null) {
      issueReady = !_busy;
    } else if (_busy || lines.isEmpty || !phoneOk) {
      issueReady = false;
    } else if (offline || !total.isPositive) {
      issueReady = true;
    } else if (flags.splitPayment && _tender.splits.isNotEmpty) {
      issueReady = true;
    } else {
      issueReady = _tender.selectedComplete;
    }

    final Widget actions = Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 12 + context.sheetBottomInset),
      child: pending != null
          ? Row(children: [
              Expanded(
                child: LiquidSecondaryButton(
                  label: 'Drop it',
                  leadingIcon: Icons.delete_outline,
                  onPressed: _busy ? null : _dropPending,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LiquidPrimaryButton(
                  label: 'Retry sale',
                  leadingIcon: Icons.refresh,
                  fullWidth: true,
                  onPressed: issueReady ? _issue : null,
                ),
              ),
            ])
          : Row(children: [
              Expanded(
                child: LiquidSecondaryButton(
                  key: const ValueKey<String>('issue-park'),
                  label: 'Park',
                  leadingIcon: Icons.bookmark_add_outlined,
                  onPressed: editable && lines.isNotEmpty
                      ? () => parkTicketSale(context, ref)
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: LiquidPrimaryButton(
                  key: const ValueKey<String>('issue-go'),
                  label: lines.isEmpty
                      ? 'Issue'
                      : 'Issue ${formatRupeesCompact(total)}',
                  leadingIcon: Icons.confirmation_number_outlined,
                  fullWidth: true,
                  onPressed: issueReady ? _issue : null,
                ),
              ),
            ]),
    );

    return ColoredBox(
      color: palette.paper,
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
                      icon: Icon(Icons.arrow_back, color: palette.ink70),
                      onPressed: _busy ? null : _back,
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child:
                          Text('Issue tickets', style: AppTypography.sheetTitle),
                    ),
                    if (canIssue)
                      TextButton.icon(
                        key: const ValueKey<String>('issue-parked'),
                        onPressed: editable && parked > 0
                            ? () => resumeTicketSale(context, ref)
                            : null,
                        icon: const Icon(Icons.bookmark_outline, size: 18),
                        label: Text('Parked ($parked)'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: !canIssue
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            "You can't sell entry tickets — ask the desk",
                            textAlign: TextAlign.center,
                            style: palette.caption,
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        children: [
                          if (offline) ...[
                            const GateOfflineStrip(
                                message: "Desk unreachable – can't issue "
                                    'tickets. Park the sale and finish it '
                                    'when the desk is back.'),
                            const SizedBox(height: 12),
                          ],
                          if (pending != null) ...[
                            _PendingIssueCard(pending: pending),
                            const SizedBox(height: 12),
                          ],
                          if (types.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 40),
                              child: Column(children: [
                                Icon(Icons.confirmation_number_outlined,
                                    size: 48, color: palette.ink30),
                                const SizedBox(height: 12),
                                const Text('No ticket types on sale',
                                    style: AppTypography.title),
                                const SizedBox(height: 4),
                                Text('Set them up on the desk',
                                    style: palette.caption),
                              ]),
                            )
                          else
                            _TypeGrid(
                              children: [
                                for (final type in types)
                                  TicketTypeTile(
                                    type: type,
                                    qty: form.qtyOf(type.id),
                                    enabled: editable,
                                    onAdd: () {
                                      if (units >= kMaxTicketsPerSale) {
                                        DynamicToast.warning(context,
                                            'At most $kMaxTicketsPerSale tickets in one sale');
                                        return;
                                      }
                                      ref
                                          .read(
                                              ticketIssueFormProvider.notifier)
                                          .add(type.id);
                                    },
                                    onRemove: () => ref
                                        .read(ticketIssueFormProvider.notifier)
                                        .remove(type.id),
                                  ),
                              ],
                            ),
                          if (missing > 0) ...[
                            const SizedBox(height: 8),
                            Text(
                              '$missing ${missing == 1 ? 'ticket is' : 'tickets are'} '
                              'of a type no longer on sale and left out',
                              style: AppTypography.caption
                                  .copyWith(color: AppColors.warn),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Text('GUEST (OPTIONAL)',
                              style: AppTypography.micro
                                  .copyWith(letterSpacing: 1.2)),
                          const SizedBox(height: 8),
                          AppCard(
                            child: Column(children: [
                              TextField(
                                key: const ValueKey<String>('guest-name'),
                                controller: _guestName,
                                enabled: editable,
                                maxLength: 100,
                                textCapitalization: TextCapitalization.words,
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'Name',
                                  isDense: true,
                                  counterText: '',
                                ),
                              ),
                              Divider(height: 12, color: palette.ink10),
                              TextField(
                                key: const ValueKey<String>('guest-phone'),
                                controller: _guestPhone,
                                enabled: editable,
                                maxLength: 24,
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintText: 'Phone',
                                  isDense: true,
                                  counterText: '',
                                  errorText: phoneOk
                                      ? null
                                      : '6 to 20 digits, or leave it blank',
                                ),
                              ),
                            ]),
                          ),
                          if (types.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            _TotalCard(units: units, total: total),
                            if (total.isPositive)
                              TenderForm(
                                controller: _tender,
                                modes: _modes(),
                                due: total,
                                allowSplit: flags.splitPayment,
                                enabled: editable,
                              ),
                          ],
                        ],
                      ),
              ),
              if (canIssue) actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// Two tiles a row on a phone, more on a wider screen.
class _TypeGrid extends StatelessWidget {
  const _TypeGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const gap = 10.0;
      final columns = constraints.maxWidth >= 600 ? 3 : 2;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    });
  }
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.units, required this.total});

  final int units;
  final Money total;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(children: [
        Expanded(
          child: Text(
            units == 0
                ? 'No tickets yet'
                : '$units ${units == 1 ? 'ticket' : 'tickets'}',
            style: AppTypography.bodyMd,
          ),
        ),
        Text(formatRupees(total), style: AppTypography.headline),
      ]),
    );
  }
}

/// The sale the desk never answered, held for a retry.
class _PendingIssueCard extends StatelessWidget {
  const _PendingIssueCard({required this.pending});

  final PendingTicketIssue pending;

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
          const Text(kIssueNoAnswer, style: AppTypography.bodyMd),
          const SizedBox(height: 10),
          Text(
            '${pending.summary} · '
            '${formatRupeesCompact(pending.request.expectedTotal)}',
            style: AppTypography.caption.copyWith(color: context.palette.ink70),
          ),
        ],
      ),
    );
  }
}
