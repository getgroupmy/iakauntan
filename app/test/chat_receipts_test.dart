import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/chat/chat_receipts.dart';

Map<String, dynamic> conversation(String id, {Object? unread}) =>
    {'id': id, 'unread': unread};

void main() {
  group('whether this device now holds messages it did not', () {
    test('it does when something is unread', () {
      expect(hasArrivedHere(conversation('c1', unread: 3)), isTrue);
    });

    test('and it does not when nothing is', () {
      expect(hasArrivedHere(conversation('c1', unread: 0)), isFalse);
      expect(hasArrivedHere(conversation('c1')), isFalse);
    });

    test('a count that came back as a string still counts', () {
      // PostgREST returns numerics as strings often enough that
      // reading this as an int would silently report nothing.
      expect(hasArrivedHere(conversation('c1', unread: '2')), isTrue);
    });
  });

  group('what to report delivery on', () {
    test('the conversations with something waiting', () {
      expect(
        newlyDelivered([
          conversation('c1', unread: 2),
          conversation('c2', unread: 0),
          conversation('c3', unread: 1),
        ], {}),
        ['c1', 'c3'],
      );
    });

    test('and never one already reported', () {
      // Marking does not change `unread` -- the messages are
      // delivered, not read -- so a list that fired on every rebuild
      // would fire for ever.
      expect(
        newlyDelivered([conversation('c1', unread: 2)], {'c1'}),
        isEmpty,
      );
    });

    test('a conversation with no id is not reported on', () {
      expect(newlyDelivered([conversation('', unread: 2)..remove('id')], {}),
          isEmpty);
    });

    test('nothing at all reports nothing', () {
      expect(newlyDelivered(const [], {}), isEmpty);
    });

    test('and something new alongside something told is still told', () {
      expect(
        newlyDelivered([
          conversation('c1', unread: 2),
          conversation('c2', unread: 5),
        ], {'c1'}),
        ['c2'],
      );
    });
  });
}
