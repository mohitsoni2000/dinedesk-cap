import 'dart:async';
import 'dart:io';

import '../models/kot_print_config.dart';
import 'escpos_builder.dart';
import 'log.dart';

const String _tag = '[LanPrinter]';

/// How one print job to one destination ended.
class LanPrintResult {
  final bool ok;

  /// A short human reason when [ok] is false ("timed out", "connection refused").
  final String? error;

  const LanPrintResult.success()
      : ok = true,
        error = null;
  const LanPrintResult.failure(String this.error) : ok = false;

  @override
  String toString() => ok ? 'LanPrintResult(ok)' : 'LanPrintResult($error)';
}

/// The seam [OfflineKotPrinter] prints through, so routing can be tested with a
/// fake and no sockets.
abstract class LanPrinter {
  /// Prints [doc] on [dest], [KotPrintDestination.copies] times. Never throws:
  /// a printer that is off, unreachable or slow is a [LanPrintResult.failure].
  Future<LanPrintResult> printDoc(KotPrintDestination dest, EscposDoc doc);
}

typedef LanSocketConnector = Future<Socket> Function(
  String host,
  int port, {
  Duration? timeout,
});

/// Raw TCP (port 9100-style) to a thermal printer, the way the desk's
/// `sendNetworkPrint` does it: connect, write the ESC/POS bytes, flush, close.
///
/// On Android the process is bound to the Wi-Fi network by the native layer
/// (see WifiBinding), so a 192.168.x.x printer is reachable even when the
/// router has no internet and the OS would otherwise route over mobile data.
class LanPrinterService implements LanPrinter {
  LanPrinterService({
    this.connectTimeout = const Duration(seconds: 3),
    this.writeTimeout = const Duration(seconds: 7),
    LanSocketConnector? connector,
  }) : _connect = connector ?? _defaultConnect;

  /// A reachable LAN printer accepts in milliseconds; 3s is long enough for a
  /// busy one and short enough that a powered-off printer doesn't hold up the
  /// "send KOT" spinner.
  final Duration connectTimeout;

  /// Budget for the write + flush + close once connected (matches the desk's
  /// 7s socket timeout).
  final Duration writeTimeout;
  final LanSocketConnector _connect;

  static Future<Socket> _defaultConnect(String host, int port,
          {Duration? timeout}) =>
      Socket.connect(host, port, timeout: timeout);

  /// The tail of each destination's job chain. One printer takes one job at a
  /// time (two slips interleaved on one TCP stream each would cut the other
  /// off); different printers run in parallel.
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  @override
  Future<LanPrintResult> printDoc(KotPrintDestination dest, EscposDoc doc) {
    final bytes = escposBytes(doc, copies: dest.copies);
    return sendBytes(dest.host, dest.port, bytes);
  }

  /// Sends [bytes] to `host:port`, queued behind any job already running for
  /// that destination.
  Future<LanPrintResult> sendBytes(String host, int port, List<int> bytes) {
    final key = '$host:$port';
    final previous = _chains[key] ?? Future<void>.value();
    final result = previous.then((_) => _sendOnce(host, port, bytes));
    late final Future<void> tail;
    tail = result.then<void>((_) {}).whenComplete(() {
      if (identical(_chains[key], tail)) _chains.remove(key);
    });
    _chains[key] = tail;
    return result;
  }

  Future<LanPrintResult> _sendOnce(
      String host, int port, List<int> bytes) async {
    Socket? socket;
    try {
      final connected = await _connect(host, port, timeout: connectTimeout)
          .timeout(connectTimeout);
      socket = connected;
      connected.add(bytes);
      await (() async {
        await connected.flush();
        await connected.close();
      })()
          .timeout(writeTimeout);
      return const LanPrintResult.success();
    } on TimeoutException {
      logD(_tag, '$host:$port timed out');
      return LanPrintResult.failure('$host:$port timed out');
    } on SocketException catch (e) {
      logD(_tag, '$host:$port failed: ${e.message}');
      return LanPrintResult.failure(
          '$host:$port ${_short(e.message, e.osError?.message)}');
    } catch (e) {
      logD(_tag, '$host:$port failed: $e');
      return LanPrintResult.failure('$host:$port failed');
    } finally {
      socket?.destroy();
    }
  }

  static String _short(String message, String? os) {
    final text = (os ?? message).trim();
    return text.isEmpty ? 'unreachable' : text.toLowerCase();
  }
}
