import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../motion/motion.dart';
import 'liquid_chrome.dart';

class SendKotButton extends ConsumerStatefulWidget {
  const SendKotButton({
    required this.controller,
    required this.onFire,
    super.key,
  });

  final SendKotButtonController controller;
  final Future<void> Function() onFire;

  @override
  ConsumerState<SendKotButton> createState() => _SendKotButtonState();
}

class _SendKotButtonState extends ConsumerState<SendKotButton> {
  RiveButtonPhase _phase = const RiveButtonIdle();

  @override
  void initState() {
    super.initState();
    widget.controller._attach(this);
  }

  @override
  void dispose() {
    widget.controller._detach();
    super.dispose();
  }

  void _setPhase(RiveButtonPhase phase) {
    setState(() {
      _phase = phase;
    });
  }

  Future<void> _onTap() async {
    if (_phase is! RiveButtonIdle && _phase is! RiveButtonError) return;
    _setPhase(const RiveButtonLoading());
    try {
      await widget.onFire();
    } catch (_) {
      _setPhase(const RiveButtonError());
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (_phase) {
      RiveButtonIdle() => 'Send KOT',
      RiveButtonLoading() => 'Sending...',
      RiveButtonSuccess() => 'Sent',
      RiveButtonError() => 'Retry KOT',
    };
    return LiquidPrimaryButton(
      label: label,
      leadingIcon: switch (_phase) {
        RiveButtonSuccess() => Icons.check,
        RiveButtonError() => Icons.refresh,
        _ => Icons.local_fire_department_outlined,
      },
      onPressed: _phase is RiveButtonLoading || _phase is RiveButtonSuccess
          ? null
          : _onTap,
      fullWidth: true,
    );
  }
}

class SendKotButtonController {
  _SendKotButtonState? _state;
  Timer? _resetTimer;

  void _attach(_SendKotButtonState s) => _state = s;

  void _detach() {
    _resetTimer?.cancel();
    _resetTimer = null;
    _state = null;
  }

  void confirmSuccess() {
    _resetTimer?.cancel();
    _state?._setPhase(const RiveButtonSuccess());
    // Hold the "Sent" state long enough to register in a busy restaurant —
    // a 2.5s flash was read as "did it send?" and invited double-taps.
    _resetTimer = Timer(const Duration(milliseconds: 4500), () {
      _state?._setPhase(const RiveButtonIdle());
      _resetTimer = null;
    });
  }

  void confirmError() {
    _resetTimer?.cancel();
    _state?._setPhase(const RiveButtonError());
  }

  void reset() {
    _resetTimer?.cancel();
    _state?._setPhase(const RiveButtonIdle());
  }
}
