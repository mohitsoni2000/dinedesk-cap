import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/providers.dart';
import '../motion/motion.dart';
import '../services/discovery_service.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';
import '../theme/tokens.dart';
import 'app_surface.dart';
import 'sheet_handle.dart';

enum _DiscoverStage { searching, none, multiple, manual, form }

const _lastEmployeeIdKey = 'crew_last_employee_id';
const _lastDeskHostKey = 'crew_last_desk_host';
const _lastDeskPortKey = 'crew_last_desk_port';

class DiscoverPairingSheet {
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => const _DiscoverPairingSheetBody(),
    );
  }
}

class _DiscoverPairingSheetBody extends ConsumerStatefulWidget {
  const _DiscoverPairingSheetBody();

  @override
  ConsumerState<_DiscoverPairingSheetBody> createState() =>
      _DiscoverPairingSheetBodyState();
}

class _DiscoverPairingSheetBodyState
    extends ConsumerState<_DiscoverPairingSheetBody> {
  _DiscoverStage _stage = _DiscoverStage.searching;
  List<DiscoveredDesk> _found = const [];
  DiscoveredDesk? _selected;

  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '8080');
  final _employeeIdCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  bool _submitting = false;
  String? _error;
  DiscoveredDesk? _lastKnownDesk;

  @override
  void initState() {
    super.initState();
    _search();
    _loadLastEmployeeId();
    _loadLastKnownDesk();
  }

  Future<void> _loadLastEmployeeId() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_lastEmployeeIdKey);
    if (saved == null || !mounted) return;
    _employeeIdCtrl.text = saved;
  }

  Future<void> _loadLastKnownDesk() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString(_lastDeskHostKey);
    final port = prefs.getInt(_lastDeskPortKey);
    if (host == null || port == null || !mounted) return;
    setState(() => _lastKnownDesk = DiscoveredDesk(ip: host, port: port));
    _hostCtrl.text = host;
    _portCtrl.text = port.toString();
  }

  Future<void> _saveLastKnownDesk(DiscoveredDesk desk) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastDeskHostKey, desk.ip);
    await prefs.setInt(_lastDeskPortKey, desk.port);
  }

  void _useLastKnownDesk() {
    final desk = _lastKnownDesk;
    if (desk == null) return;
    setState(() {
      _selected = desk;
      _stage = _DiscoverStage.form;
    });
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _employeeIdCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    setState(() => _stage = _DiscoverStage.searching);
    final found = await scanForDesks();
    if (!mounted) return;
    if (found.isEmpty) {
      setState(() => _stage = _DiscoverStage.none);
    } else if (found.length == 1) {
      setState(() {
        _selected = found.first;
        _stage = _DiscoverStage.form;
      });
    } else {
      setState(() {
        _found = found;
        _stage = _DiscoverStage.multiple;
      });
    }
  }

  void _pick(DiscoveredDesk desk) {
    setState(() {
      _selected = desk;
      _stage = _DiscoverStage.form;
    });
  }

  void _useManualEntry() {
    setState(() => _stage = _DiscoverStage.manual);
  }

  void _confirmManualEntry() {
    final host = _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null) {
      setState(() => _error = 'Enter the Desk\'s host and port');
      return;
    }
    setState(() {
      _selected = DiscoveredDesk(ip: host, port: port);
      _stage = _DiscoverStage.form;
      _error = null;
    });
  }

  Future<void> _submitPin() async {
    final desk = _selected;
    final employeeId = _employeeIdCtrl.text.trim();
    final pin = _pinCtrl.text.trim();
    if (desk == null || employeeId.isEmpty || pin.isEmpty) {
      setState(() => _error = 'Enter your employee ID and PIN');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    final result =
        await SocketService.pairScanless(desk.ip, desk.port, employeeId, pin);
    if (!mounted) return;

    switch (result) {
      case RecoverySuccess(token: final token, deviceSecret: final secret):
        ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        await (await SharedPreferences.getInstance())
            .setString(_lastEmployeeIdKey, employeeId);
        await _saveLastKnownDesk(desk);
        final pairing = PairingInfo(
          host: desk.ip,
          port: desk.port,
          token: token,
          deviceSecret: secret,
          deskInstanceId: desk.id,
        );
        await SessionService().savePairing(pairing);
        if (!mounted) return;
        ref
            .read(connectionBootstrapProvider.notifier)
            .connectWithFreshPairing(pairing);
        Navigator.of(context).pop();
        context.go('/connecting');
      case RecoveryFailed(code: final code, message: final message):
        setState(() {
          _submitting = false;
          _error = code == 'PAIRING_DISABLED'
              ? 'Ask your admin to enable PIN pairing on the Desk'
              : message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: context.sheetBottomInset),
      child: AppSurface(
        tint: AppColors.night,
        border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
        shadow: AppShadows.elevatedFor(context),
        borderRadius: const BorderRadius.vertical(top: AppRadii.xl),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(child: SheetHandle()),
            const SizedBox(height: 16),
            switch (_stage) {
              _DiscoverStage.searching => const _SearchingBody(),
              _DiscoverStage.none => _NoneFoundBody(
                  onManualEntry: _useManualEntry,
                  onRetry: _search,
                  lastKnownDesk: _lastKnownDesk,
                  onUseLastKnown: _useLastKnownDesk,
                ),
              _DiscoverStage.multiple =>
                _PickerBody(found: _found, onPick: _pick),
              _DiscoverStage.manual => _ManualEntryBody(
                  hostCtrl: _hostCtrl,
                  portCtrl: _portCtrl,
                  error: _error,
                  onConfirm: _confirmManualEntry,
                ),
              _DiscoverStage.form => _PinFormBody(
                  desk: _selected!,
                  employeeIdCtrl: _employeeIdCtrl,
                  pinCtrl: _pinCtrl,
                  error: _error,
                  submitting: _submitting,
                  onSubmit: _submitPin,
                ),
            },
          ],
        ),
      ),
    );
  }
}

class _SearchingBody extends StatelessWidget {
  const _SearchingBody();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 12),
            Text('Searching this Wi-Fi for the Desk…',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _NoneFoundBody extends StatelessWidget {
  final VoidCallback onManualEntry;
  final VoidCallback onRetry;
  final DiscoveredDesk? lastKnownDesk;
  final VoidCallback onUseLastKnown;
  const _NoneFoundBody({
    required this.onManualEntry,
    required this.onRetry,
    required this.lastKnownDesk,
    required this.onUseLastKnown,
  });
  @override
  Widget build(BuildContext context) {
    final desk = lastKnownDesk;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('No Desk found on this Wi-Fi',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('Make sure this phone is on the same Wi-Fi as the Desk.',
            style: AppTypography.caption
                .copyWith(color: Colors.white.withValues(alpha: 0.55))),
        if (desk != null) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: _SheetButton(
              label: 'Use last known Desk — ${desk.ip}:${desk.port}',
              emphasis: true,
              onTap: onUseLastKnown,
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SheetButton(label: 'Try again', onTap: onRetry),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SheetButton(
                  label: 'Enter host manually',
                  emphasis: desk == null,
                  onTap: onManualEntry),
            ),
          ],
        ),
      ],
    );
  }
}

class _PickerBody extends StatelessWidget {
  final List<DiscoveredDesk> found;
  final void Function(DiscoveredDesk) onPick;
  const _PickerBody({required this.found, required this.onPick});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('More than one Desk found',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
            'Pick the right one — this only matters on shared Wi-Fi (e.g. a food court).',
            style: AppTypography.caption
                .copyWith(color: Colors.white.withValues(alpha: 0.55))),
        const SizedBox(height: 12),
        for (final desk in found)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SheetButton(
              label: '${desk.ip}:${desk.port}',
              onTap: () => onPick(desk),
            ),
          ),
      ],
    );
  }
}

class _ManualEntryBody extends StatelessWidget {
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final String? error;
  final VoidCallback onConfirm;
  const _ManualEntryBody({
    required this.hostCtrl,
    required this.portCtrl,
    required this.error,
    required this.onConfirm,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Enter the Desk\'s address',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        _SheetField(controller: hostCtrl, label: 'HOST', hint: '192.168.1.24'),
        const SizedBox(height: 12),
        _SheetField(
          controller: portCtrl,
          label: 'PORT',
          hint: '8080',
          keyboardType: TextInputType.number,
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: AppColors.danger)),
        ],
        const SizedBox(height: 16),
        _SheetButton(label: 'Continue', emphasis: true, onTap: onConfirm),
      ],
    );
  }
}

class _PinFormBody extends StatelessWidget {
  final DiscoveredDesk desk;
  final TextEditingController employeeIdCtrl;
  final TextEditingController pinCtrl;
  final String? error;
  final bool submitting;
  final VoidCallback onSubmit;
  const _PinFormBody({
    required this.desk,
    required this.employeeIdCtrl,
    required this.pinCtrl,
    required this.error,
    required this.submitting,
    required this.onSubmit,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Connecting to ${desk.ip}:${desk.port}',
            style: AppTypography.caption
                .copyWith(color: Colors.white.withValues(alpha: 0.55))),
        const SizedBox(height: 8),
        const Text('Employee ID + PIN',
            style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        _SheetField(
            controller: employeeIdCtrl, label: 'EMPLOYEE ID', hint: 'EMP001'),
        const SizedBox(height: 12),
        _SheetField(
          controller: pinCtrl,
          label: 'PIN',
          hint: '••••',
          keyboardType: TextInputType.number,
          obscureText: true,
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: AppColors.danger)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: _SheetButton(
            label: submitting ? '' : 'Pair this device',
            emphasis: true,
            busy: submitting,
            onTap: submitting ? null : onSubmit,
          ),
        ),
      ],
    );
  }
}

class _SheetField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final bool obscureText;
  const _SheetField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
    this.obscureText = false,
  });
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.micro
                .copyWith(color: Colors.white.withValues(alpha: 0.45))),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: const BorderRadius.all(AppRadii.sm),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: TextField(
            controller: controller,
            keyboardType: keyboardType,
            obscureText: obscureText,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: hint,
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetButton extends StatelessWidget {
  final String label;
  final bool emphasis;
  final bool busy;
  final VoidCallback? onTap;
  const _SheetButton({
    required this.label,
    this.emphasis = false,
    this.busy = false,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: AppTouchTargets.minimum),
        padding: const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: emphasis ? AppColors.terra : Colors.white.withValues(alpha: 0.12),
          borderRadius: const BorderRadius.all(AppRadii.md),
          boxShadow: emphasis ? AppShadows.terraGlow : null,
        ),
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontFamily: AppTypography.inter,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}
