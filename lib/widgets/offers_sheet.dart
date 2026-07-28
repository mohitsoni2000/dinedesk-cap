

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../data/currency.dart';
import '../theme/tokens.dart';
import '../utils/socket_helpers.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

class _AppliedOffer {
  final String id;
  final String offerId;
  final String offerName;
  final String source;
  final double totalDiscount;
  const _AppliedOffer({
    required this.id,
    required this.offerId,
    required this.offerName,
    required this.source,
    required this.totalDiscount,
  });

  factory _AppliedOffer.fromMap(Map<String, dynamic> m) => _AppliedOffer(
        id: m['id']?.toString() ?? '',
        offerId: m['offer_id']?.toString() ?? '',
        offerName: m['offer_name']?.toString() ?? 'Offer',
        source: m['source']?.toString() ?? 'manual',
        totalDiscount: (m['total_discount'] as num?)?.toDouble() ?? 0,
      );
}

class OffersSheet {

  static Future<Map<String, dynamic>?> show(
    BuildContext context, {
    required String orderId,
  }) {
    return showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) => _OffersSheet(orderId: orderId),
    );
  }
}

class _OffersSheet extends ConsumerStatefulWidget {
  final String orderId;
  const _OffersSheet({required this.orderId});
  @override
  ConsumerState<_OffersSheet> createState() => _OffersSheetState();
}

class _OffersSheetState extends ConsumerState<_OffersSheet> {
  final _couponController = TextEditingController();
  final List<_AppliedOffer> _applied = [];
  bool _submitting = false;
  String? _pendingOfferId;
  Map<String, dynamic>? _lastOrder;

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
  }

  void _applyOffer(String offerId) => _submit({
        'order_id': widget.orderId,
        'offer_id': offerId,
      }, pendingKey: offerId);

  void _applyCoupon() {
    final code = _couponController.text.trim();
    if (code.isEmpty) return;
    _submit({
      'order_id': widget.orderId,
      'coupon_code': code,
    }, pendingKey: 'coupon');
  }

  void _removeOffer(String offerId) => _submit(
        {'order_id': widget.orderId, 'offer_id': offerId},
        pendingKey: offerId,
        event: 'offer:remove',
      );

  void _submit(Map<String, dynamic> payload,
      {required String pendingKey, String event = 'offer:apply'}) {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _pendingOfferId = pendingKey;
    });
    HapticFeedback.selectionClick();

    final socketService = ref.read(socketServiceProvider);
    socketService.emit(event, payload, onAck: (response) {
      if (!mounted) return;
      if (response['kind'] == 'error') {
        setState(() {
          _submitting = false;
          _pendingOfferId = null;
        });
        DynamicToast.show(context,
            message: response['message']?.toString() ?? 'Offer action failed',
            kind: ToastKind.error);
        return;
      }
      final orderMap = response['order'];
      setState(() {
        _submitting = false;
        _pendingOfferId = null;
        if (event == 'offer:apply') _couponController.clear();
        if (orderMap is Map) {
          _lastOrder = Map<String, dynamic>.from(orderMap);
          final rawOffers = _lastOrder!['applied_offers'];
          _applied
            ..clear()
            ..addAll((rawOffers is List ? rawOffers : const [])
                .whereType<Map>()
                .map((m) => _AppliedOffer.fromMap(Map<String, dynamic>.from(m))));
        }
      });
    });

    scheduleSocketTimeout(
      duration: const Duration(seconds: 10),
      isMounted: () => mounted,
      isStillWaiting: () => _submitting,
      onTimeout: () {
        setState(() {
          _submitting = false;
          _pendingOfferId = null;
        });
        DynamicToast.show(context,
            message: 'Offer request timed out — please retry',
            kind: ToastKind.error);
      },
    );
  }

  Map<String, dynamic>? _resultForCaller() {
    if (_applied.isEmpty) return null;
    final totalDiscount =
        _applied.fold<double>(0, (sum, a) => sum + a.totalDiscount);
    final label = _applied.length == 1
        ? _applied.first.offerName
        : '${_applied.length} offers';
    return {
      'order': _lastOrder,
      'discount_amount': totalDiscount,
      'discount_label': label,
    };
  }

  @override
  Widget build(BuildContext context) {
    final offers = ref.watch(offersProvider);
    final manualOffers =
        offers.where((o) => !o.autoApply && o.couponCode == null).toList();
    final autoOffers = offers.where((o) => o.autoApply).toList();
    final appliedIds = _applied.map((a) => a.offerId).toSet();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (_, scrollCtrl) => AppSurface(
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 16 + context.sheetBottomInset),
        child: ListView(
          controller: scrollCtrl,
          children: [
            Center(child: const SheetHandle()),
            const SizedBox(height: 16),
            Row(
              children: [
                const Icon(Icons.local_activity_outlined,
                    color: AppColors.terra, size: 22),
                const SizedBox(width: 10),
                const Text('Offers', style: AppTypography.sheetTitle),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_resultForCaller()),
                  child: const Text('Done'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            if (_applied.isNotEmpty) ...[
              Text('APPLIED',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 10),
              for (final a in _applied) ...[
                _AppliedOfferTile(
                  offer: a,
                  removing: _submitting && _pendingOfferId == a.offerId,
                  onRemove: _submitting ? null : () => _removeOffer(a.offerId),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 12),
            ],

            if (manualOffers.isNotEmpty) ...[
              Text('AVAILABLE OFFERS',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 10),
              for (final o in manualOffers) ...[
                _OfferTile(
                  offer: o,
                  applied: appliedIds.contains(o.id),
                  loading: _submitting && _pendingOfferId == o.id,
                  onApply: _submitting ? null : () => _applyOffer(o.id),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 12),
            ],

            if (autoOffers.isNotEmpty) ...[
              Text('AUTO-APPLIED WHEN ELIGIBLE',
                  style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in autoOffers)
                    Chip(
                      label: Text(o.name, style: AppTypography.caption),
                      avatar: const Icon(Icons.auto_awesome, size: 14),
                      backgroundColor: context.palette.surface,
                      side: BorderSide(color: context.palette.hairline),
                    ),
                ],
              ),
              const SizedBox(height: 16),
            ],

            if (manualOffers.isEmpty && autoOffers.isEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('No offers configured right now',
                    style: AppTypography.caption),
              ),
              const SizedBox(height: 8),
            ],

            Text('HAVE A COUPON CODE?',
                style: AppTypography.micro.copyWith(letterSpacing: 1.2)),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: context.palette.surface,
                borderRadius: const BorderRadius.all(AppRadii.sm),
                border: Border.all(color: context.palette.hairline, width: 1.5),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: TextField(
                controller: _couponController,
                cursorColor: AppColors.terra,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Enter coupon code',
                  icon: Icon(Icons.confirmation_number_outlined,
                      color: context.palette.ink50),
                ),
                onSubmitted: (_) => _applyCoupon(),
              ),
            ),
            const SizedBox(height: 12),
            LiquidPrimaryButton(
              label: _submitting && _pendingOfferId == 'coupon'
                  ? 'Applying...'
                  : 'Apply Coupon',
              fullWidth: true,
              leadingIcon: _submitting && _pendingOfferId == 'coupon'
                  ? Icons.hourglass_top
                  : Icons.check_circle_outline,
              onPressed: _submitting ? null : _applyCoupon,
            ),
          ],
        ),
      ),
    );
  }
}

class _OfferTile extends StatelessWidget {
  final Offer offer;
  final bool applied;
  final bool loading;
  final VoidCallback? onApply;
  const _OfferTile({
    required this.offer,
    required this.applied,
    required this.loading,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shadow: const [],
      child: Row(
        children: [
          Expanded(
            child: Text(offer.name,
                style: AppTypography.bodyMd
                    .copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          if (applied)
            const Icon(Icons.check_circle, color: AppColors.success, size: 20)
          else
            LiquidSecondaryButton(
              label: loading ? '...' : 'Apply',
              onPressed: onApply,
            ),
        ],
      ),
    );
  }
}

class _AppliedOfferTile extends StatelessWidget {
  final _AppliedOffer offer;
  final bool removing;
  final VoidCallback? onRemove;
  const _AppliedOfferTile({
    required this.offer,
    required this.removing,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      borderRadius: const BorderRadius.all(AppRadii.sm),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shadow: const [],
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppColors.success, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(offer.offerName,
                    style: AppTypography.bodyMd
                        .copyWith(fontWeight: FontWeight.w600)),
                if (offer.totalDiscount > 0)
                  Text('-${formatRupeesCompact(offer.totalDiscount)}',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.success)),
              ],
            ),
          ),
          IconButton(
            icon: removing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
