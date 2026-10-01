import 'providers.dart';

enum RoomCardState {
  mine,
  occupied,
  free,
  held,
  dirty,
  cleaning,
  inspect,
  blocked
}

/// What a Rooms tile shows — shared by the tile and the tap so they can never
/// disagree. "Held" is worked out against today's IST date, never stored.
class RoomCardView {
  final RoomCardState state;
  final String tag;
  final String? guest;
  final String? note;
  final bool lateNote;

  const RoomCardView({
    required this.state,
    required this.tag,
    this.guest,
    this.note,
    this.lateNote = false,
  });

  bool get unavailable => _notReady.values.any((v) => v.$1 == state);
}

const Map<RoomState, (RoomCardState, String)> _notReady = {
  RoomState.dirty: (RoomCardState.dirty, 'DIRTY'),
  RoomState.cleaning: (RoomCardState.cleaning, 'CLEANING'),
  RoomState.inspect: (RoomCardState.inspect, 'TO INSPECT'),
  RoomState.blocked: (RoomCardState.blocked, 'BLOCKED'),
};

RoomCardView roomCardView(RestaurantRoom room, String istToday) {
  final hold = room.activeHold(istToday);
  switch (room.state) {
    case RoomState.free:
      if (hold != null) {
        return RoomCardView(
          state: RoomCardState.held,
          tag: 'HELD',
          guest: hold.guestName,
          note: hold.whenLabel(istToday),
          lateNote: hold.isLate(istToday),
        );
      }
      return RoomCardView(
          state: RoomCardState.free, tag: 'FREE', guest: room.guestName);
    case RoomState.mine:
    case RoomState.occupied:
      final mine = room.state == RoomState.mine;
      return RoomCardView(
        state: mine ? RoomCardState.mine : RoomCardState.occupied,
        tag: room.activeBillCount > 0
            ? 'BILL PENDING'
            : (mine ? 'MINE' : 'OCCUPIED'),
        guest: room.guestName,
        note: hold == null ? null : 'Next: ${hold.guestName}',
      );
    case RoomState.dirty:
    case RoomState.cleaning:
    case RoomState.inspect:
    case RoomState.blocked:
      final (state, tag) = _notReady[room.state]!;
      return RoomCardView(
        state: state,
        tag: tag,
        note: hold == null ? null : 'Held: ${hold.guestName}',
      );
  }
}
