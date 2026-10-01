import 'package:flutter_test/flutter_test.dart';
import 'package:restro/data/providers.dart';
import 'package:restro/data/room_card_view.dart';
import 'package:restro/data/table_open_intent.dart';
import 'package:restro/models/room_arrival_hold.dart';
import 'package:restro/services/sync_service.dart';

const today = '2026-10-01';

final hold = RoomArrivalHold(
  guestName: 'Ravi Sharma',
  arrivesAt: DateTime.utc(2026, 10, 1, 8, 30),
  firstNight: '2026-10-01',
  lastNight: '2026-10-02',
);

RestaurantRoom room(RoomState state,
        {RoomArrivalHold? h, String? guest, String? orderId, int bills = 0}) =>
    RestaurantRoom(
      id: '102',
      serverId: 'r2',
      capacity: 2,
      state: state,
      guestName: guest,
      activeOrderId: orderId,
      activeBillCount: bills,
      arrivalHold: h,
    );

void main() {
  test('mapRoomStatus reads every desk status; anything else is free', () {
    expect(mapRoomStatus('occupied'), RoomState.occupied);
    expect(mapRoomStatus(' Dirty '), RoomState.dirty);
    expect(mapRoomStatus('cleaning'), RoomState.cleaning);
    expect(mapRoomStatus('clean'), RoomState.inspect);
    expect(mapRoomStatus('BLOCKED'), RoomState.blocked);
    expect(mapRoomStatus('free'), RoomState.free);
    expect(mapRoomStatus('something-new'), RoomState.free);
  });

  group('roomCardView', () {
    test('a vacant held room shows the guest and when they arrive', () {
      final v = roomCardView(room(RoomState.free, h: hold), today);
      expect(v.state, RoomCardState.held);
      expect(v.tag, 'HELD');
      expect(v.guest, 'Ravi Sharma');
      expect(v.note, 'arrives 2:00 pm');
      expect(v.lateNote, isFalse);
    });

    test('a late guest reads "was due"', () {
      final v = roomCardView(room(RoomState.free, h: hold), '2026-10-02');
      expect(v.note, 'was due 1 Oct, 2:00 pm');
      expect(v.lateNote, isTrue);
    });

    test('an occupied room names the next guest under the current one', () {
      final v = roomCardView(
          room(RoomState.occupied, h: hold, guest: 'Amit', bills: 1), today);
      expect(v.state, RoomCardState.occupied);
      expect(v.tag, 'BILL PENDING');
      expect(v.guest, 'Amit');
      expect(v.note, 'Next: Ravi Sharma');
    });

    test('a room not ready yet keeps its status and says who it is held for',
        () {
      for (final (state, tag) in [
        (RoomState.dirty, 'DIRTY'),
        (RoomState.cleaning, 'CLEANING'),
        (RoomState.inspect, 'TO INSPECT'),
        (RoomState.blocked, 'BLOCKED'),
      ]) {
        final v = roomCardView(room(state, h: hold), today);
        expect(v.tag, tag);
        expect(v.note, 'Held: Ravi Sharma');
        expect(v.unavailable, isTrue);
      }
    });

    test('a hold outside its nights is ignored', () {
      expect(roomCardView(room(RoomState.free, h: hold), '2026-10-03').state,
          RoomCardState.free);
      expect(roomCardView(room(RoomState.free, h: hold), '2026-09-30').state,
          RoomCardState.free);
    });
  });

  group('resolveRoomOpenIntent', () {
    final noonIst = DateTime.utc(2026, 10, 1, 6, 30);

    test('a free room starts an order; one with an order or a guest opens it',
        () {
      expect(resolveRoomOpenIntent(room(RoomState.free), now: noonIst).action,
          TableOpenAction.createDraft);
      expect(
          resolveRoomOpenIntent(room(RoomState.free, orderId: 'o1'),
                  now: noonIst)
              .action,
          TableOpenAction.openOrder);
      expect(
          resolveRoomOpenIntent(room(RoomState.occupied, h: hold), now: noonIst)
              .action,
          TableOpenAction.openOrder);
    });

    test('a held room is refused with who it is held for', () {
      final intent =
          resolveRoomOpenIntent(room(RoomState.free, h: hold), now: noonIst);
      expect(intent.action, TableOpenAction.blocked);
      expect(intent.message,
          'Held for Ravi Sharma — desk checks the guest in first');
    });

    test('a room not ready is refused; its status wins over a hold', () {
      expect(
          resolveRoomOpenIntent(room(RoomState.dirty, h: hold), now: noonIst)
              .message,
          'Room needs cleaning');
      expect(
          resolveRoomOpenIntent(room(RoomState.cleaning), now: noonIst).message,
          'Room is being cleaned');
      expect(
          resolveRoomOpenIntent(room(RoomState.inspect), now: noonIst).message,
          'Room is awaiting inspection');
      expect(
          resolveRoomOpenIntent(room(RoomState.blocked), now: noonIst).message,
          'Room is blocked');
    });

    test('the hold lets go at IST midnight after its last night', () {
      final r = room(RoomState.free, h: hold);
      expect(
          resolveRoomOpenIntent(r, now: DateTime.utc(2026, 10, 2, 18, 29))
              .action,
          TableOpenAction.blocked);
      expect(
          resolveRoomOpenIntent(r, now: DateTime.utc(2026, 10, 2, 18, 30))
              .action,
          TableOpenAction.createDraft);
    });
  });
}
