import '../data/ist_time.dart';
import 'wire.dart';

final RegExp _ymd = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// The confirmed booking holding a room tonight, as the desk sends it on the
/// room row (`arrival_hold`). Only what a waiter is shown is kept: the
/// guest's phone, advance and party size are never read.
class RoomArrivalHold {
  final String guestName;
  final DateTime? arrivesAt;
  final String firstNight;
  final String lastNight;

  const RoomArrivalHold({
    required this.guestName,
    required this.arrivesAt,
    required this.firstNight,
    required this.lastNight,
  });

  /// Null for anything that is not a usable hold — a bad hold never costs
  /// the room its row.
  static RoomArrivalHold? tryParse(Object? raw) {
    final m = asMap(raw);
    final first = optionalString(m, 'first_night');
    final last = optionalString(m, 'last_night');
    if (first == null || last == null) return null;
    if (!_ymd.hasMatch(first) || !_ymd.hasMatch(last)) return null;
    return RoomArrivalHold(
      guestName: stringOr(m, 'guest_name', 'Guest'),
      arrivesAt: parseDbTimestamp(optionalString(m, 'arrives_at')),
      firstNight: first,
      lastNight: last,
    );
  }

  Map<String, dynamic> toJson() => {
        'guest_name': guestName,
        'arrives_at': arrivesAt?.toUtc().toIso8601String(),
        'first_night': firstNight,
        'last_night': lastNight,
      };

  bool holdsNight(String istDay) =>
      firstNight.compareTo(istDay) <= 0 && istDay.compareTo(lastNight) <= 0;

  bool isLate(String istToday) => firstNight.compareTo(istToday) < 0;

  String? whenLabel(String istToday) {
    final at = arrivesAt;
    if (at == null) return null;
    return isLate(istToday)
        ? 'was due ${formatIstDayTime(at)}'
        : 'arrives ${formatIstTime(at)}';
  }
}
