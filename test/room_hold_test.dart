import 'package:flutter_test/flutter_test.dart';
import 'package:restro/models/room_arrival_hold.dart';
import 'package:restro/models/server_models.dart';

void main() {
  group('RoomArrivalHold', () {
    Map<String, dynamic> wire([Map<String, dynamic> over = const {}]) => {
          'reservation_id': 'b1',
          'guest_name': 'Ravi Sharma',
          'guest_phone': '9800000001',
          'party_size': 2,
          'arrives_at': '2026-10-01 08:30:00',
          'departs_at': '2026-10-03 05:30:00',
          'first_night': '2026-10-01',
          'last_night': '2026-10-02',
          'deposit_held': 1000,
          'more_tonight': 0,
          ...over,
        };

    test('holds every booked night, inclusive, and nothing outside', () {
      final hold = RoomArrivalHold.tryParse(wire())!;
      expect(hold.holdsNight('2026-09-30'), isFalse);
      expect(hold.holdsNight('2026-10-01'), isTrue);
      expect(hold.holdsNight('2026-10-02'), isTrue);
      expect(hold.holdsNight('2026-10-03'), isFalse);
    });

    test('says when the guest arrives, or when they were due', () {
      final hold = RoomArrivalHold.tryParse(wire())!;
      expect(hold.whenLabel('2026-10-01'), 'arrives 2:00 pm');
      expect(hold.whenLabel('2026-10-02'), 'was due 1 Oct, 2:00 pm');
    });

    test('a bad hold is null; a missing name or time keeps the hold', () {
      expect(RoomArrivalHold.tryParse('x'), isNull);
      expect(RoomArrivalHold.tryParse(<Object>[]), isNull);
      expect(RoomArrivalHold.tryParse(<String, dynamic>{}), isNull);
      expect(RoomArrivalHold.tryParse(wire({'last_night': 'soon'})), isNull);
      final noName = RoomArrivalHold.tryParse(wire({'guest_name': ''}))!;
      expect(noName.guestName, 'Guest');
      final noTime = RoomArrivalHold.tryParse(wire({'arrives_at': 'later'}))!;
      expect(noTime.arrivesAt, isNull);
      expect(noTime.whenLabel('2026-10-01'), isNull);
    });

    test('keeps only what a waiter is shown, and survives a cache round trip',
        () {
      final hold = RoomArrivalHold.tryParse(wire())!;
      final json = hold.toJson();
      expect(json.keys.toSet(),
          {'guest_name', 'arrives_at', 'first_night', 'last_night'});
      final back = RoomArrivalHold.tryParse(json)!;
      expect(back.guestName, 'Ravi Sharma');
      expect(back.arrivesAt, hold.arrivesAt);
      expect(back.lastNight, '2026-10-02');
    });

    test('a room with a malformed hold still parses, without the hold', () {
      for (final bad in <Object>['x', <Object>[], <String, dynamic>{}]) {
        final room = ServerRoom.fromMap({
          'id': 'r1',
          'name': '101',
          'status': 'free',
          'arrival_hold': bad,
        });
        expect(room.id, 'r1');
        expect(room.arrivalHold, isNull);
      }
      final room = ServerRoom.fromMap({
        'id': 'r1',
        'name': '101',
        'status': 'free',
        'arrival_hold': wire()
      });
      expect(room.arrivalHold?.guestName, 'Ravi Sharma');
    });
  });
}
