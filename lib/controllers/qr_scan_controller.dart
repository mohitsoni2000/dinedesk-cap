import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/providers.dart';
import '../motion/feedback_kind.dart';
import '../motion/feedback_service.dart';
import '../services/pairing_uri.dart';
import '../services/session_service.dart';
import '../services/socket_service.dart';

enum ScanError { invalid, expired, unreachable, offNetwork }

enum ScanStage { idle, checking, verified }

class QrScanState {
  final bool torchOn;
  final bool processing;
  final ScanError? error;
  final ScanStage stage;
  final int shakeTrigger;
  final bool cameraFailed;

  const QrScanState({
    this.torchOn = false,
    this.processing = false,
    this.error,
    this.stage = ScanStage.idle,
    this.shakeTrigger = 0,
    this.cameraFailed = false,
  });

  String? get errorLabel => switch (error) {
        ScanError.invalid => 'Not a valid Restro pairing QR',
        ScanError.expired => 'QR expired — ask the admin for a fresh one',
        ScanError.unreachable => "Can't reach the server — same Wi-Fi?",
        ScanError.offNetwork =>
          'That QR points off the restaurant network — check with your admin',
        null => null,
      };

  QrScanState copyWith({
    bool? torchOn,
    bool? processing,
    Object? error = _absent,
    ScanStage? stage,
    int? shakeTrigger,
    bool? cameraFailed,
  }) {
    return QrScanState(
      torchOn: torchOn ?? this.torchOn,
      processing: processing ?? this.processing,
      error: error == _absent ? this.error : error as ScanError?,
      stage: stage ?? this.stage,
      shakeTrigger: shakeTrigger ?? this.shakeTrigger,
      cameraFailed: cameraFailed ?? this.cameraFailed,
    );
  }

  static const _absent = Object();
}

class QrScanNotifier extends StateNotifier<QrScanState> {
  QrScanNotifier(this._ref) : super(const QrScanState());

  final Ref _ref;
  Timer? _errorTimer;

  void setCameraFailed() {
    if (!state.cameraFailed) {
      state = state.copyWith(cameraFailed: true);
    }
  }

  void retryCamera() {
    if (state.cameraFailed) {
      state = state.copyWith(cameraFailed: false, error: null);
    }
  }

  void toggleTorch(MobileScannerController scannerController) {
    scannerController.toggleTorch();
    state = state.copyWith(torchOn: !state.torchOn);
  }

  void processBarcode(
    BarcodeCapture capture, {
    required void Function() onSuccessNavigate,
  }) async {
    if (state.processing) return;
    final raw =
        capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null) return;

    final parsed = parsePairingUri(raw);
    final PairingInfo pairing;
    switch (parsed) {
      case PairingUriOk(pairing: final ok):
        pairing = ok;
      case PairingUriOffNetwork():
        _showError(ScanError.offNetwork);
        return;
      case PairingUriInvalid():
        _showError(ScanError.invalid);
        return;
    }

    state = state.copyWith(
      processing: true,
      error: null,
      stage: ScanStage.checking,
    );

    final result =
        await SocketService.probe(pairing.host, pairing.port, pairing.token);

    if (!mounted) return;

    switch (result) {
      case ProbeResult.ok:
        state = state.copyWith(stage: ScanStage.verified);
        _ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
        await SessionService().savePairing(pairing);
        if (!mounted) return;
        _ref
            .read(connectionBootstrapProvider.notifier)
            .connectWithFreshPairing(pairing);
        onSuccessNavigate();
      case ProbeResult.authRejected:
        _showError(ScanError.expired);
      case ProbeResult.unreachable:
        _showError(ScanError.unreachable);
    }
  }

  void demoScan({required void Function() onSuccessNavigate}) {
    if (state.processing) return;
    state = state.copyWith(processing: true, error: null);

    _ref.read(feedbackServiceProvider).fire(const FeedbackSuccess());
    _ref.read(restaurantProvider.notifier).state = const RestaurantInfo(
      name: 'Command.Crew Demo Kitchen',
      address: 'MG Road, Bengaluru',
      adminDeviceLabel: 'Demo Admin Desktop',
      adminIp: '',
    );

    const pairing =
        PairingInfo(host: 'localhost', port: 8080, token: 'demo-token');
    SessionService().savePairing(pairing).then((_) {
      if (!mounted) return;
      _ref
          .read(connectionBootstrapProvider.notifier)
          .connectWithFreshPairing(pairing);
      onSuccessNavigate();
    });
  }

  void _showError(ScanError err) {
    _ref.read(feedbackServiceProvider).fire(const FeedbackError());
    _errorTimer?.cancel();
    state = state.copyWith(
      error: err,
      stage: ScanStage.idle,
      shakeTrigger: state.shakeTrigger + 1,
    );

    _errorTimer = Timer(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      state = state.copyWith(
        error: null,
        processing: false,
      );
    });
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    super.dispose();
  }
}

final qrScanProvider =
    StateNotifierProvider.autoDispose<QrScanNotifier, QrScanState>(
  (ref) => QrScanNotifier(ref),
);
