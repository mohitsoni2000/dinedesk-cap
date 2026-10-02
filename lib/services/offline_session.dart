import 'dart:convert';

/// The operator session as it was the last time the desk confirmed it, kept in
/// secure storage so a phone that cold-starts with the desk unreachable can
/// carry on taking orders (cold-start offline).
///
/// It deliberately holds NO credential: no PIN and no PIN hash. What lets the
/// phone resume is a time window (`pinGraceMinutes`, the desk's own operator
/// PIN grace) measured from [lastSeenAt], the last moment the desk was
/// demonstrably talking to this phone. Past that window the PIN is needed.
class OfflineSession {
  final String operatorId;
  final String name;
  final String role;
  final String shift;
  final String? employeeId;

  /// The desk this session belongs to (the pairing's `deskInstanceId`).
  final String? deskInstanceId;

  /// Last time the desk answered this phone while the session was verified.
  final DateTime lastSeenAt;

  /// The desk's effective operator PIN grace, in minutes (0 = PIN on every
  /// reconnect, so never resumable offline).
  final int pinGraceMinutes;

  const OfflineSession({
    required this.operatorId,
    required this.name,
    required this.role,
    required this.shift,
    this.employeeId,
    this.deskInstanceId,
    required this.lastSeenAt,
    required this.pinGraceMinutes,
  });

  OfflineSession copyWith({DateTime? lastSeenAt, int? pinGraceMinutes}) =>
      OfflineSession(
        operatorId: operatorId,
        name: name,
        role: role,
        shift: shift,
        employeeId: employeeId,
        deskInstanceId: deskInstanceId,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        pinGraceMinutes: pinGraceMinutes ?? this.pinGraceMinutes,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'operator_id': operatorId,
        'name': name,
        'role': role,
        'shift': shift,
        if (employeeId != null) 'employee_id': employeeId,
        if (deskInstanceId != null) 'desk_instance_id': deskInstanceId,
        'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
        'pin_grace_minutes': pinGraceMinutes,
      };

  String encode() => jsonEncode(toJson());

  /// Null for anything unreadable: a corrupt or half-written entry must mean
  /// "no offline session", never a crash at boot.
  static OfflineSession? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final id = decoded['operator_id']?.toString() ?? '';
      final seen = DateTime.tryParse(decoded['last_seen_at']?.toString() ?? '');
      if (id.isEmpty || seen == null) return null;
      final grace = decoded['pin_grace_minutes'];
      return OfflineSession(
        operatorId: id,
        name: decoded['name']?.toString() ?? 'Operator',
        role: decoded['role']?.toString() ?? 'Waiter',
        shift: decoded['shift']?.toString() ?? 'Day',
        employeeId: decoded['employee_id']?.toString(),
        deskInstanceId: decoded['desk_instance_id']?.toString(),
        lastSeenAt: seen.toUtc(),
        pinGraceMinutes: grace is int ? grace : int.tryParse('$grace') ?? 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How long a phone may stay offline-resumable no matter what the desk's grace
/// says. A day is the longest a shift plausibly runs unattended.
const Duration kOfflineResumeCap = Duration(hours: 24);

/// May the app resume this session without asking the desk (and so without a
/// PIN)? Pure, so the policy can be tested on its own. ALL must hold:
///
/// - a session exists, and, when [pairingDeskInstanceId] is given, it belongs
///   to that desk (a phone re-paired to another desk must not inherit it);
/// - `pinGraceMinutes > 0` (a desk that never told us its grace, or has it at 0,
///   fails closed);
/// - `now - lastSeenAt <= min(pinGraceMinutes, cap)`. A `lastSeenAt` in the
///   future (the clock was set back) is not trusted: it fails closed too.
///
/// The biometric gate is the caller's: it is an interactive step, not data.
bool canResumeOffline(
  OfflineSession? session,
  DateTime now, {
  Duration cap = kOfflineResumeCap,
  String? pairingDeskInstanceId,
}) {
  if (session == null) return false;
  if (pairingDeskInstanceId != null &&
      session.deskInstanceId != pairingDeskInstanceId) {
    return false;
  }
  if (session.pinGraceMinutes <= 0) return false;
  final grace = Duration(minutes: session.pinGraceMinutes);
  final window = grace < cap ? grace : cap;
  final away = now.difference(session.lastSeenAt);
  if (away.isNegative) return false;
  return away <= window;
}
