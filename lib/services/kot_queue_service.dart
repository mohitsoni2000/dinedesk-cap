import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'socket_service.dart';

/// Offline-first KOT pipeline.
///
/// WiFi blips are a fact of restaurant life — instead of failing the round,
/// `kot:send` payloads that can't reach the desk are persisted locally and
/// flushed automatically the moment the socket is verified again (login,
/// reconnect-resync, or the next send). Every payload carries a
/// `client_kot_id` so the desk can de-duplicate retries server-side.
final kotQueueProvider = Provider<KotQueueService>((ref) => KotQueueService());

class KotQueueService {
  static const _prefsKey = 'pending_kots_v1';
  static const _tag = '[KotQueue]';
  bool _flushing = false;

  String _newClientId() =>
      'ck_${DateTime.now().millisecondsSinceEpoch}_${identityHashCode(this)}';

  Future<List<Map<String, dynamic>>> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const <String>[];
    return raw
        .map((e) {
          try {
            return Map<String, dynamic>.from(jsonDecode(e) as Map);
          } catch (_) {
            return <String, dynamic>{};
          }
        })
        .where((m) => m.isNotEmpty)
        .toList();
  }

  Future<void> _write(List<Map<String, dynamic>> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _prefsKey, items.map(jsonEncode).toList(growable: false));
  }

  Future<int> pendingCount() async => (await _read()).length;

  Future<void> _enqueue(Map<String, dynamic> payload) async {
    final items = await _read();
    items.add(<String, dynamic>{
      'payload': payload,
      'queued_at': DateTime.now().toIso8601String(),
    });
    await _write(items);
    debugPrint('$_tag queued KOT (${items.length} pending)');
  }

  /// Send a KOT now if the desk is reachable, otherwise queue it.
  /// Returns the server ack, or `{'kind': 'queued'}` when stored offline.
  Future<Map<String, dynamic>> sendKot(
    SocketService socket,
    Map<String, dynamic> payload,
  ) async {
    payload = <String, dynamic>{...payload, 'client_kot_id': _newClientId()};

    if (socket.state != SocketState.verified) {
      await _enqueue(payload);
      return <String, dynamic>{'kind': 'queued'};
    }

    // Older queued rounds must reach the kitchen before this one.
    await flush(socket);

    try {
      return await socket
          .emitAck('kot:send', payload)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      await _enqueue(payload);
      return <String, dynamic>{'kind': 'queued', 'timeout': true};
    } catch (e) {
      debugPrint('$_tag send error, queuing: $e');
      await _enqueue(payload);
      return <String, dynamic>{'kind': 'queued'};
    }
  }

  /// Fire every pending KOT, oldest first. Stops on the first failure so
  /// order is preserved; the next verified moment retries the rest.
  Future<void> flush(SocketService socket) async {
    if (_flushing || socket.state != SocketState.verified) return;
    var items = await _read();
    if (items.isEmpty) return;
    _flushing = true;
    debugPrint('$_tag flushing ${items.length} pending KOT(s)…');
    try {
      while (items.isNotEmpty) {
        final payload =
            Map<String, dynamic>.from(items.first['payload'] as Map);
        Map<String, dynamic> res;
        try {
          res = await socket
              .emitAck('kot:send', payload)
              .timeout(const Duration(seconds: 8));
        } catch (_) {
          break; // still unreachable — keep the rest for next time
        }
        final msg = res['message']?.toString().toLowerCase() ?? '';
        final accepted = res['kind'] != 'error' ||
            msg.contains('duplicate') ||
            msg.contains('already');
        if (!accepted) {
          debugPrint('$_tag desk rejected queued KOT: $msg — dropping');
        }
        items.removeAt(0);
        await _write(items);
      }
    } finally {
      _flushing = false;
      debugPrint('$_tag flush done (${items.length} left)');
    }
  }
}
