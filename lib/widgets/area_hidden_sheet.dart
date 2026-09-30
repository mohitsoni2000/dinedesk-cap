import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../services/menu_area.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'dynamic_toast.dart';
import 'liquid_chrome.dart';
import 'sheet_handle.dart';

/// "Hidden here": what is turned off for this table/room's area. Items staff
/// hid can be shown again from here; ones hidden in the menu setup are locked
/// (an admin lifts them on the desk).
class AreaHiddenSheet extends ConsumerStatefulWidget {
  final MenuAreaContext initial;
  final Map<String, dynamic> where;

  /// Called after something was shown again, so the menu can refresh.
  final VoidCallback onChanged;

  const AreaHiddenSheet({
    super.key,
    required this.initial,
    required this.where,
    required this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required MenuAreaContext area,
    required Map<String, dynamic> where,
    required VoidCallback onChanged,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.32),
      builder: (_) =>
          AreaHiddenSheet(initial: area, where: where, onChanged: onChanged),
    );
  }

  @override
  ConsumerState<AreaHiddenSheet> createState() => _AreaHiddenSheetState();
}

class _AreaHiddenSheetState extends ConsumerState<AreaHiddenSheet> {
  late MenuAreaContext _area = widget.initial;
  String? _busyId;

  Future<void> _showAgain(MenuAreaHiddenEntry e) async {
    if (_busyId != null || !e.isQuick) return;
    setState(() => _busyId = e.id);
    final socket = ref.read(socketServiceProvider);
    final error = await setMenuAreaBlocked(
      socket,
      widget.where,
      targetType: e.targetType,
      targetId: e.targetId,
      blocked: false,
    );
    if (!mounted) return;
    if (error != null) {
      setState(() => _busyId = null);
      DynamicToast.show(context, message: error, kind: ToastKind.error);
      return;
    }
    final fresh = await fetchMenuAreaContext(socket, widget.where);
    if (!mounted) return;
    setState(() {
      // No answer: it was shown again, so just drop that row locally.
      _area = fresh ??
          MenuAreaContext(
            enabled: _area.enabled,
            areaLabel: _area.areaLabel,
            canToggle: _area.canToggle,
            hiddenItemIds: _area.hiddenItemIds,
            entries: _area.entries.where((x) => x.id != e.id).toList(),
          );
      _busyId = null;
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _area.entries;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      expand: false,
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
                  Icon(Icons.visibility_off_outlined,
                      color: context.palette.ink70, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Hidden for ${_area.areaLabel ?? 'this area'}',
                      style: AppTypography.sheetTitle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: context.palette.hairline),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Nothing is hidden here. Long-press an item on the menu to hide it.',
                          textAlign: TextAlign.center,
                          style: AppTypography.caption,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: context.palette.ink10),
                      itemBuilder: (_, i) {
                        final e = entries[i];
                        return ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 52),
                          child: Row(
                            children: [
                              Icon(
                                e.isCategory
                                    ? Icons.folder_outlined
                                    : Icons.visibility_off_outlined,
                                size: 18,
                                color: context.palette.ink50,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(e.targetName,
                                        style: AppTypography.bodyMd,
                                        overflow: TextOverflow.ellipsis),
                                    Text(
                                      e.isCategory
                                          ? 'Whole category'
                                          : (e.categoryName ?? ''),
                                      style: AppTypography.caption,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              if (e.isQuick)
                                TextButton.icon(
                                  onPressed: _busyId == null
                                      ? () => _showAgain(e)
                                      : null,
                                  icon: _busyId == e.id
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2),
                                        )
                                      : const Icon(Icons.visibility, size: 18),
                                  label: const Text('Show again'),
                                )
                              else
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.lock_outline,
                                        size: 14, color: context.palette.ink50),
                                    const SizedBox(width: 4),
                                    const Text('Menu setup',
                                        style: AppTypography.caption),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding:
                  EdgeInsets.fromLTRB(16, 8, 16, 16 + context.sheetBottomInset),
              child: LiquidSecondaryButton(
                label: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
