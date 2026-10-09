import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/counter_providers.dart';
import '../data/currency.dart';
import '../data/providers.dart';
import '../models/token.dart';
import '../motion/motion.dart';
import '../services/offline_guard.dart';
import '../services/qsr_checkout_service.dart';
import '../theme/tokens.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/liquid_chrome.dart';
import '../widgets/order_submitting_overlay.dart';
import '../widgets/token_badge.dart';
import 'counter_checkout_screen.dart';

/// After a counter order: the token, big, for the cashier to call out and
/// the guest to see.
///
/// - **Fired:** the token, how the order leaves, its items and total, and
///   Paid or Pay at pickup. When the KOT itself is still on its way, the
///   token fills in live as the desk's broadcasts arrive.
/// - **Queued:** the desk is away. "QUEUED Q-3 — token is assigned when the
///   desk is back", with the kitchen slip's reference if it printed
///   directly. It turns into the token when the queue gets the order there.
/// - **Unconfirmed:** the desk did not answer a Pay & Fire. Retry sends the
///   same order (the desk replays it, never charges twice); nothing moves on
///   by itself.
///
/// Fired and queued count down [nextOrderSeconds] to the next order.
class TokenResultScreen extends ConsumerStatefulWidget {
  const TokenResultScreen({super.key});

  static const int nextOrderSeconds = 8;

  @override
  ConsumerState<TokenResultScreen> createState() => _TokenResultScreenState();
}

class _TokenResultScreenState extends ConsumerState<TokenResultScreen> {
  Timer? _tick;
  int _countdown = TokenResultScreen.nextOrderSeconds;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    // A queued order landing turns this screen over.
    ref.read(counterReplayWatcherProvider);
    if (_countsDown(ref.read(counterResultProvider))) {
      ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
      _startCountdown();
    }
  }

  bool _countsDown(CounterOrderResult? result) =>
      result != null && result.outcome != CounterOutcome.unconfirmed;

  void _startCountdown() {
    _tick?.cancel();
    _countdown = TokenResultScreen.nextOrderSeconds;
    _tick = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown > 1) {
        setState(() => _countdown--);
      } else {
        timer.cancel();
        _nextOrder();
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _nextOrder() {
    _tick?.cancel();
    context.go('/counter/order');
  }

  void _done() {
    _tick?.cancel();
    context.go('/counter');
  }

  Future<void> _retry() async {
    final pending = ref.read(pendingCheckoutProvider);
    if (pending == null || _retrying) return;
    if (!requireDesk(context, ref)) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _retrying = true);
    final done = Completer<bool>();
    final run = retryPendingCheckout(container, pending);
    unawaited(run.then((_) {
      if (!done.isCompleted) done.complete(true);
    }));
    await OrderSubmittingOverlay.show(context,
        completer: done,
        timeout: OrderSubmittingOverlay.moneyTimeout,
        title: 'Checking with the desk…',
        subtitle: 'Sending the same order again');
    final result = await run;
    if (!mounted) return;
    setState(() => _retrying = false);
    switch (result) {
      case QsrCheckoutOk():
        // The result turned to fired; the listener starts the countdown.
        break;
      case QsrCheckoutRejected(:final message):
        DynamicToast.error(context, '$message. Nothing was charged.');
        // Back to the cart, which was kept, to put it right.
        context.go('/counter/order');
      case QsrCheckoutUnconfirmed():
        DynamicToast.warning(context, kCheckoutNoAnswer);
      case QsrCheckoutOffline():
        DynamicToast.warning(context, kNeedsDeskMessage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(counterResultProvider);
    ref.listen<CounterOrderResult?>(counterResultProvider, (previous, next) {
      if (previous?.outcome == CounterOutcome.unconfirmed &&
          _countsDown(next)) {
        _startCountdown();
      }
    });
    final palette = context.palette;

    if (result == null) {
      return ColoredBox(
        color: palette.paper,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
            child:
                LiquidPrimaryButton(label: 'New order', onPressed: _nextOrder),
          ),
        ),
      );
    }

    final orderId = result.orderId;
    final token = result.token ??
        (orderId == null
            ? null
            : liveTokenFor(orderId,
                active: ref.watch(activeOrdersProvider),
                history: ref.watch(historyProvider)));

    final Widget hero = switch (result.outcome) {
      CounterOutcome.fired => _FiredCard(
          token: token,
          result: result,
          tokensOn: ref.watch(flagsProvider.select((f) => f.orderTokens)),
        ),
      CounterOutcome.queued => _QueuedCard(result: result),
      CounterOutcome.unconfirmed => const _UnconfirmedCard(),
    };

    final unconfirmed = result.outcome == CounterOutcome.unconfirmed;
    // Reached with go(): back has nothing under it, so it means "done".
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_retrying) _done();
      },
      child: ColoredBox(
        color: palette.paper,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    IconButton(
                      tooltip: 'Done',
                      icon: Icon(Icons.close, color: palette.ink70),
                      onPressed: _retrying ? null : _done,
                    ),
                  ]),
                  const Spacer(),
                  hero,
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FulfillmentChip(type: result.fulfillment),
                      if (!unconfirmed) PaymentTagChip(paid: result.paid),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${result.itemCount} ${result.itemCount == 1 ? 'item' : 'items'}'
                    ' · ${formatRupees(result.total)}',
                    textAlign: TextAlign.center,
                    style: AppTypography.title.copyWith(color: palette.ink70),
                  ),
                  const Spacer(),
                  if (unconfirmed) ...[
                    LiquidPrimaryButton(
                      label: _retrying ? 'Checking…' : 'Retry',
                      leadingIcon: Icons.refresh,
                      fullWidth: true,
                      onPressed: _retrying ? null : _retry,
                    ),
                    const SizedBox(height: 8),
                    LiquidSecondaryButton(
                      label: 'Back to the cart',
                      onPressed: _retrying ? null : _nextOrder,
                    ),
                  ] else ...[
                    LiquidPrimaryButton(
                      label: 'Next order ($_countdown)',
                      leadingIcon: Icons.add_shopping_cart,
                      fullWidth: true,
                      onPressed: _nextOrder,
                    ),
                    const SizedBox(height: 8),
                    LiquidSecondaryButton(label: 'Done', onPressed: _done),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The token, or a note that it is on its way.
class _FiredCard extends StatelessWidget {
  const _FiredCard({
    required this.token,
    required this.result,
    required this.tokensOn,
  });

  final TokenInfo? token;
  final CounterOrderResult result;

  /// With tokens off the desk gives none: the KOT is what there is to show.
  final bool tokensOn;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shown = token;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.all(AppRadii.xl),
        border: Border.all(color: AppColors.terra200, width: 1.5),
      ),
      child: Column(
        children: [
          Text(shown != null || tokensOn ? 'TOKEN' : 'SENT TO THE KITCHEN',
              style: AppTypography.micro
                  .copyWith(letterSpacing: 3, color: AppColors.terraDeep)),
          const SizedBox(height: 8),
          if (shown == null && !tokensOn)
            Text(result.kotNumber ?? 'KOT sent',
                style: AppTypography.displayMd.copyWith(color: palette.ink))
          else if (shown != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child:
                  TokenNumber(key: ValueKey(shown.label), label: shown.label),
            )
          else ...[
            Icon(Icons.hourglass_top, size: 48, color: palette.ink30),
            const SizedBox(height: 8),
            Text('Token on its way',
                style: AppTypography.headline.copyWith(color: palette.ink70)),
            const SizedBox(height: 4),
            Text(
              result.kotNumber == null
                  ? 'It shows here as soon as the kitchen has the KOT.'
                  : '${result.kotNumber} · it shows here as soon as the '
                      'kitchen has it.',
              textAlign: TextAlign.center,
              style: AppTypography.caption,
            ),
          ],
          if (result.offlineRef != null) ...[
            const SizedBox(height: 10),
            Text('Kitchen slip ${result.offlineRef}',
                style: AppTypography.caption),
          ],
        ],
      ),
    );
  }
}

/// Queued on this phone: the local ref until the desk gives the token.
class _QueuedCard extends StatelessWidget {
  const _QueuedCard({required this.result});

  final CounterOrderResult result;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.10),
        borderRadius: const BorderRadius.all(AppRadii.xl),
        border: Border.all(
            color: AppColors.amber.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        children: [
          Text('QUEUED',
              style: AppTypography.micro
                  .copyWith(letterSpacing: 3, color: AppColors.warn)),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              result.localRef ?? '—',
              maxLines: 1,
              style: const TextStyle(
                fontFamily: AppTypography.inter,
                fontSize: 96,
                fontWeight: FontWeight.w800,
                height: 1.0,
                color: AppColors.warn,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The token is assigned when the desk is back.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMd,
          ),
          if (result.offlineRef != null) ...[
            const SizedBox(height: 6),
            Text('Kitchen slip printed · ${result.offlineRef}',
                textAlign: TextAlign.center, style: AppTypography.caption),
          ],
        ],
      ),
    );
  }
}

/// A Pay & Fire the desk did not answer.
class _UnconfirmedCard extends StatelessWidget {
  const _UnconfirmedCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.06),
        borderRadius: const BorderRadius.all(AppRadii.xl),
        border: Border.all(
            color: AppColors.danger.withValues(alpha: 0.35), width: 1.5),
      ),
      child: const Column(
        children: [
          Icon(Icons.sync_problem_outlined, size: 48, color: AppColors.danger),
          SizedBox(height: 8),
          Text('NOT CONFIRMED',
              style: TextStyle(
                  fontFamily: AppTypography.inter,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 3,
                  color: AppColors.danger)),
          SizedBox(height: 10),
          Text(kCheckoutNoAnswer,
              textAlign: TextAlign.center, style: AppTypography.bodyMd),
        ],
      ),
    );
  }
}
