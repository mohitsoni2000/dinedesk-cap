import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/currency.dart';
import '../data/ist_time.dart';
import '../data/providers.dart';
import '../models/entry_ticket.dart';
import '../services/entry_ticket_service.dart';
import '../services/offline_guard.dart';
import '../theme/tokens.dart';
import '../widgets/app_card.dart';
import '../widgets/dynamic_toast.dart';
import '../widgets/gate/gate_offline_strip.dart';
import '../widgets/gate/ticket_qr_sheet.dart';

/// Which of today's tickets the list shows.
enum RecentFilter {
  all('All'),
  notEntered('Not entered'),
  entered('Entered'),
  cancelled('Cancelled');

  const RecentFilter(this.label);
  final String label;

  bool matches(TicketSummary t) => switch (this) {
        RecentFilter.all => true,
        RecentFilter.notEntered => t.status == TicketStatus.issued,
        RecentFilter.entered => t.status == TicketStatus.checkedIn,
        RecentFilter.cancelled => t.status == TicketStatus.cancelled,
      };
}

/// Today's tickets from the desk (`ticket:recent`), newest first: the gate's
/// counters, filter chips, a search (number, guest, phone's last digits),
/// and each ticket's QR on screen. Phones only ever arrive as their last
/// four digits.
class TicketRecentScreen extends ConsumerStatefulWidget {
  const TicketRecentScreen({super.key});

  @override
  ConsumerState<TicketRecentScreen> createState() => _TicketRecentScreenState();
}

class _TicketRecentScreenState extends ConsumerState<TicketRecentScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  RecentFilter _filter = RecentFilter.all;
  RecentTickets? _recent;
  String? _error;
  bool _loading = false;
  int _seq = 0;
  String? _opening;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (isDeskOffline(ref)) {
      setState(() => _error = null);
      return;
    }
    final seq = ++_seq;
    setState(() => _loading = true);
    final outcome = await ref
        .read(entryTicketServiceProvider)
        .recent(query: _search.text);
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      switch (outcome) {
        case RecentTicketsLoaded(:final recent):
          _recent = recent;
          _error = null;
        case RecentTicketsFailed(:final message):
          _error = message;
      }
    });
  }

  void _onSearch(String _) {
    _debounce?.cancel();
    _debounce =
        Timer(const Duration(milliseconds: 350), () => unawaited(_load()));
  }

  /// The ticket's QR and slip, from the desk (the list rows carry neither).
  Future<void> _showQr(TicketSummary row) async {
    if (_opening != null) return;
    if (!requireDesk(context, ref)) return;
    setState(() => _opening = row.id);
    final outcome = await ref
        .read(entryTicketServiceProvider)
        .lookup(row.ticketNumber, purpose: TicketLookupPurpose.peek);
    if (!mounted) return;
    setState(() => _opening = null);
    switch (outcome) {
      case TicketFound(:final result):
        final ticket = result.ticket;
        if (ticket == null || ticket.id != row.id) {
          DynamicToast.error(context, "Couldn't find this ticket on the desk");
          return;
        }
        await showTicketQrSheet(
          context,
          ticketId: ticket.id,
          qrData: ticket.slip?.qrData ?? ticket.qrCode,
          ticketNumber: ticket.ticketNumber,
          typeName: ticket.typeName,
          slip: ticket.slip,
        );
      case TicketLookupFailed(:final message):
        DynamicToast.error(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(connectionProvider.select((c) => c.online), (_, online) {
      if (online && _recent == null) unawaited(_load());
    });
    final palette = context.palette;
    final offline = isDeskOffline(ref);
    final recent = _recent;
    final rows = recent == null
        ? const <TicketSummary>[]
        : recent.tickets.where(_filter.matches).toList();

    return ColoredBox(
      color: palette.paper,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    icon: Icon(Icons.arrow_back, color: palette.ink70),
                    onPressed: () => context.canPop()
                        ? context.pop()
                        : context.go('/gate'),
                  ),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: Text("Today's tickets",
                        style: AppTypography.sheetTitle),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    icon: Icon(Icons.refresh, color: palette.ink70),
                    onPressed: _loading ? null : _load,
                  ),
                ]),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    children: [
                      if (offline) ...[
                        const GateOfflineStrip(
                            message: "Desk unreachable – today's tickets "
                                'need the desk'),
                        const SizedBox(height: 12),
                      ],
                      if (recent != null) ...[
                        _StatsRow(stats: recent.stats),
                        const SizedBox(height: 12),
                      ],
                      Container(
                        decoration: BoxDecoration(
                          color: palette.surface,
                          borderRadius: const BorderRadius.all(AppRadii.sm),
                          border:
                              Border.all(color: palette.hairline, width: 1.5),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          controller: _search,
                          onChanged: _onSearch,
                          maxLength: 40,
                          textInputAction: TextInputAction.search,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            icon: Icon(Icons.search, size: 20),
                            hintText: 'Ticket no., guest or phone',
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final f in RecentFilter.values)
                            ChoiceChip(
                              label: Text(f.label),
                              selected: _filter == f,
                              onSelected: (_) => setState(() => _filter = f),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: AppTypography.bodyMd
                                  .copyWith(color: AppColors.danger)),
                        )
                      else if (recent == null && _loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (rows.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 32),
                          child: Text(
                            recent == null
                                ? 'Nothing loaded yet'
                                : 'No tickets here',
                            textAlign: TextAlign.center,
                            style: palette.caption,
                          ),
                        )
                      else
                        for (final row in rows) ...[
                          _RecentRow(
                            row: row,
                            opening: _opening == row.id,
                            onShowQr: row.status == TicketStatus.cancelled
                                ? null
                                : () => _showQr(row),
                          ),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats});

  final GateStats stats;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, int value) => Expanded(
          child: Column(children: [
            Text('$value',
                style: AppTypography.headline.copyWith(
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures()
                    ])),
            Text(label,
                textAlign: TextAlign.center, style: context.palette.caption),
          ]),
        );
    return AppCard(
      child: Row(children: [
        cell('Tickets', stats.issued),
        cell('Pax sold', stats.paxIssued),
        cell('Checked in', stats.checkedIn),
        cell('Pax inside', stats.paxInside),
      ]),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.row,
    required this.opening,
    required this.onShowQr,
  });

  final TicketSummary row;
  final bool opening;
  final VoidCallback? onShowQr;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (label, color) = switch (row.status) {
      TicketStatus.issued => ('Not entered', AppColors.info),
      TicketStatus.checkedIn => ('Entered', AppColors.success),
      TicketStatus.cancelled => ('Cancelled', AppColors.danger),
      TicketStatus.unknown => ('—', palette.ink50),
    };
    final issued = row.issuedAt;
    final entered = row.checkedInAt;
    final guest = <String>[
      if (row.guestName != null) row.guestName!,
      if (row.guestPhoneLast4 != null) '•••• ${row.guestPhoneLast4}',
    ].join(' · ');
    return AppCard(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(
                    row.ticketNumber,
                    style: AppTypography.bodyMd.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: const BorderRadius.all(AppRadii.pill),
                    ),
                    child: Text(label,
                        style: AppTypography.caption.copyWith(
                            color: color, fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    row.typeName,
                    '${row.pax} pax',
                    if (row.coverBalance.isPositive)
                      'Cover ${formatRupeesCompact(row.coverBalance)} left',
                  ].join(' · '),
                  style: palette.caption,
                ),
                if (guest.isNotEmpty)
                  Text(guest,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: palette.caption),
                Text(
                  [
                    if (issued != null) 'Sold ${formatIstClock12(issued)}',
                    if (entered != null) 'in ${formatIstClock12(entered)}',
                  ].join(' · '),
                  style: palette.caption,
                ),
              ],
            ),
          ),
          if (onShowQr != null)
            IconButton(
              tooltip: 'Show QR',
              onPressed: opening ? null : onShowQr,
              icon: opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.qr_code_2),
            ),
        ],
      ),
    );
  }
}
