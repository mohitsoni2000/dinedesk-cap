/// The list of parked carts (or parked ticket sales) the signed-in operator
/// has, with Resume and Discard on each.
///
/// ```dart
/// final resumed = await showParkedSheet(
///   context,
///   kind: ParkedKind.counterCart,
///   // Optional. A cart already in progress: ask park / replace / cancel here.
///   // Return false to stop the resume; the draft stays parked.
///   beforeResume: (draft) async => await askWhatToDoWithTheCurrentCart(),
/// );
/// if (resumed == null) return; // closed without resuming
/// final cart = resumed.cart!;   // ResolvedCart: lines, notes, fulfillment
/// ```
///
/// Resume puts the draft back against today's menu (or ticket types) with
/// the pure resolver. When anything was dropped or repriced the cashier is
/// shown the "Needs attention" summary first and can back out, which costs
/// nothing. The draft is then taken off the phone, and only once that write
/// has gone through is it handed back: a write that fails resumes nothing
/// and says so, so the same draft is never resumed twice. The host applies
/// what it gets synchronously, right after `await showParkedSheet(...)`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/currency.dart';
import '../data/parked_providers.dart';
import '../data/providers.dart';
import '../models/parked_draft.dart';
import '../services/log.dart';
import '../services/parked_cart_resolver.dart';
import '../services/parked_drafts_store.dart';
import '../theme/tokens.dart';
import 'app_card.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

const String _tag = '[ParkedSheet]';

/// What Resume hands back: the draft that was parked, and it put back
/// against today's menu or ticket types.
final class ParkedResume {
  const ParkedResume({required this.draft, required this.resolved});

  final ParkedDraft draft;
  final ResolvedDraft resolved;

  /// The cart, for a resumed [ParkedKind.counterCart]; null otherwise.
  ResolvedCart? get cart {
    final r = resolved;
    return r is ResolvedCart ? r : null;
  }

  /// The ticket sale, for a resumed [ParkedKind.ticketIssue]; null otherwise.
  ResolvedTicketDraft? get tickets {
    final r = resolved;
    return r is ResolvedTicketDraft ? r : null;
  }
}

/// Opens the sheet for [kind] and completes with what the operator resumed,
/// or null if they closed it.
///
/// [beforeResume] runs when they have decided to resume [draft] (after any
/// "Needs attention" summary they agreed to) and before anything is handed
/// back. Return false to cancel; the draft stays parked and the sheet stays
/// open. It may park the cart in progress first; if it throws, the resume is
/// abandoned the same way.
Future<ParkedResume?> showParkedSheet(
  BuildContext context, {
  required ParkedKind kind,
  Future<bool> Function(ParkedDraft draft)? beforeResume,
}) {
  return showModalBottomSheet<ParkedResume>(
    context: context,
    isScrollControlled: true,
    // Swiping closed is the inner DraggableScrollableSheet's, which the sheet
    // turns off while a resume is taking its draft off the phone.
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.32),
    builder: (_) => ParkedSheet(kind: kind, beforeResume: beforeResume),
  );
}

/// "just now", "5 min ago", "2 h ago", "3 d ago".
String formatParkedAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

class ParkedSheet extends ConsumerStatefulWidget {
  const ParkedSheet({super.key, required this.kind, this.beforeResume});

  final ParkedKind kind;
  final Future<bool> Function(ParkedDraft draft)? beforeResume;

  @override
  ConsumerState<ParkedSheet> createState() => _ParkedSheetState();
}

class _ParkedSheetState extends ConsumerState<ParkedSheet> {
  /// The draft being resumed or discarded; everything else waits for it.
  String? _busyId;

  bool get _isCart => widget.kind == ParkedKind.counterCart;

  Future<void> _resume(ParkedDraft draft) async {
    if (_busyId != null) return;
    setState(() => _busyId = draft.id);
    try {
      final resolved = resolveDraft(
        draft.payload,
        menu: ref.read(menuProvider),
        ticketTypes: ref.read(ticketTypesProvider),
      );
      if (resolved.needsAttention) {
        final agreed = await _showNeedsAttention(resolved);
        if (!agreed || !mounted) return;
      }
      final hook = widget.beforeResume;
      if (hook != null) {
        final bool go;
        try {
          go = await hook(draft);
        } catch (error) {
          logE(_tag, 'resume stopped by its host', error.runtimeType);
          if (mounted) {
            // A parked-drafts error (the cap, say, when the host parked the
            // cart in progress) already says what to do.
            DynamicToast.error(
              context,
              error is ParkedDraftsException
                  ? error.message
                  : "Couldn't resume ${draft.label}. Try again.",
            );
          }
          return;
        }
        if (!go || !mounted) return;
      }
      // Off the phone first, then handed back. A write that fails resumes
      // nothing: the draft stays parked and the cashier is told, so it can
      // never be resumed twice. (The sheet holds open while this runs.)
      final parked = ref.read(parkedDraftsProvider.notifier);
      final ParkedDraft? taken;
      try {
        taken = await parked.resume(draft.id);
      } on ParkedDraftsException catch (error) {
        if (mounted) DynamicToast.error(context, error.message);
        return;
      }
      if (taken == null) {
        if (mounted) {
          DynamicToast.error(context, '${draft.label} is no longer parked.');
        }
        return;
      }
      if (!mounted) {
        // Torn down mid-write (a forced sign-out, say): put the cart back
        // rather than lose it. It comes back under a new label.
        logE(_tag, 'the sheet closed while resuming; parking the draft again');
        unawaited(parked.park(taken.payload).then((_) {}, onError: (_) {}));
        return;
      }
      Navigator.of(context).pop(ParkedResume(draft: draft, resolved: resolved));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<bool> _showNeedsAttention(ResolvedDraft resolved) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: const Text('Needs attention', style: AppTypography.title),
        content: SingleChildScrollView(
          child: NeedsAttentionSummary(resolved: resolved),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Back'),
          ),
          if (!resolved.isEmpty)
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Resume with changes'),
            ),
        ],
      ),
    );
    return agreed ?? false;
  }

  Future<void> _discard(ParkedDraft draft) async {
    if (_busyId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: dialog.palette.surface,
        title: Text('Discard ${draft.label}?', style: AppTypography.title),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = draft.id);
    try {
      await ref.read(parkedDraftsProvider.notifier).discard(draft.id);
    } catch (error) {
      logE(_tag, 'discard failed', error.runtimeType);
      if (mounted) {
        DynamicToast.error(
          context,
          error is ParkedDraftsException
              ? error.message
              : "Couldn't discard ${draft.label}. Try again.",
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drafts = ref.watch(parkedByKindProvider(widget.kind));
    final ready = _isCart
        ? ref.watch(menuProvider.select((menu) => menu.isNotEmpty))
        : ref.watch(ticketTypesProvider.select((types) => types.isNotEmpty));
    final now = DateTime.now();

    final busy = _busyId != null;
    return PopScope(
      // Back and a tap outside wait while a draft is being resumed or
      // discarded: the resume must reach the host once it left the phone.
      canPop: !busy,
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        shouldCloseOnMinExtent: !busy,
        builder: (_, scroll) => AppSurface(
          borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              const SizedBox(height: 8),
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.bookmark_outline,
                        color: AppColors.terra, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isCart ? 'Parked carts' : 'Parked ticket sales',
                        style: AppTypography.sheetTitle,
                      ),
                    ),
                    Text('${drafts.length} parked',
                        style: AppTypography.caption),
                  ],
                ),
              ),
              Divider(height: 1, color: context.palette.ink10),
              if (!ready && drafts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    _isCart
                        ? 'The menu has not loaded yet — reconnect to the desk '
                            'to resume.'
                        : 'The ticket types have not loaded yet — reconnect to '
                            'the desk to resume.',
                    style:
                        AppTypography.caption.copyWith(color: AppColors.warn),
                  ),
                ),
              Expanded(
                child: drafts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bookmark_border,
                                color: context.palette.ink30, size: 48),
                            const SizedBox(height: 12),
                            const Text('Nothing is parked',
                                style: AppTypography.title),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: drafts.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final draft = drafts[i];
                          return _ParkedCard(
                            draft: draft,
                            age: now.difference(draft.createdAt),
                            onResume: ready && !busy
                                ? () => unawaited(_resume(draft))
                                : null,
                            onDiscard:
                                busy ? null : () => unawaited(_discard(draft)),
                          );
                        },
                      ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    16, 8, 16, 16 + context.sheetBottomInset),
                child: LiquidSecondaryButton(
                  label: 'Close',
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParkedCard extends StatelessWidget {
  const _ParkedCard({
    required this.draft,
    required this.age,
    required this.onResume,
    required this.onDiscard,
  });

  final ParkedDraft draft;
  final Duration age;
  final VoidCallback? onResume;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final total = draft.payload.total;
    final payload = draft.payload;
    final guest = payload is TicketIssueDraft ? payload.guestName : null;

    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: context.palette.terraSoft,
                  borderRadius: const BorderRadius.all(AppRadii.xs),
                ),
                child: Text(
                  draft.label,
                  style: AppTypography.caption.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.terraDeep,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  payload.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyMd,
                ),
              ),
              if (total != null) ...[
                const SizedBox(width: 10),
                Text(formatRupeesCompact(total), style: AppTypography.title),
              ],
            ],
          ),
          if (guest != null) ...[
            const SizedBox(height: 4),
            Text(guest, style: AppTypography.caption),
          ],
          const SizedBox(height: 4),
          Text('parked ${formatParkedAge(age)}', style: AppTypography.caption),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: LiquidSecondaryButton(
                  key: ValueKey<String>('parked-discard-${draft.id}'),
                  label: 'Discard',
                  onPressed: onDiscard,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: LiquidPrimaryButton(
                  key: ValueKey<String>('parked-resume-${draft.id}'),
                  label: 'Resume',
                  onPressed: onResume,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What a resume could not bring back, and what costs differently now: the
/// body of the "Needs attention" dialog. Reusable wherever a [ResolvedDraft]
/// should be explained.
class NeedsAttentionSummary extends StatelessWidget {
  const NeedsAttentionSummary({super.key, required this.resolved});

  final ResolvedDraft resolved;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (resolved.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Nothing here can be resumed.',
              style: AppTypography.bodyMd.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        if (resolved.dropped.isNotEmpty)
          _Section(
            title: 'No longer available',
            icon: Icons.remove_circle_outline,
            color: AppColors.danger,
            lines: <String>[for (final d in resolved.dropped) d.message],
          ),
        if (resolved.repriced.isNotEmpty)
          _Section(
            title: 'Price changed',
            icon: Icons.price_change_outlined,
            color: AppColors.warn,
            lines: <String>[for (final r in resolved.repriced) r.message],
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.color,
    required this.lines,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Text(title,
                  style: AppTypography.caption
                      .copyWith(fontWeight: FontWeight.w700, color: color)),
            ],
          ),
          const SizedBox(height: 6),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 22),
              child: Text(line, style: AppTypography.body),
            ),
        ],
      ),
    );
  }
}
