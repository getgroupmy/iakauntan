import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/chat/chat_receipts.dart';

/// A row shaped the way `chat_my_conversations` actually returns one.
///
/// This fixture used to say `'id'`. The RPC has never returned a column
/// called `id` — it returns `conversation_id`, which is what
/// `chat_screen.dart` reads twice on its way down the same list — so
/// every assertion below passed against a shape the app never sees, and
/// `newlyDelivered` returned an empty list on every real device from the
/// day it was written. Nothing failed. The grey delivered tick simply
/// never appeared, and a green test said the code that draws it worked.
///
/// The key here is the fix. A fixture that lies about the column names
/// tests the test.
Map<String, dynamic> conversation(
  String id, {
  Object? unread,
  String lastMessageAt = '2026-09-30T10:00:00Z',
}) => {
  'conversation_id': id,
  'unread': unread,
  'last_message_at': lastMessageAt,
};

List<String> ids(List<({String id, String mark})> reports) =>
    [for (final r in reports) r.id];

void main() {
  group('which conversation a row is about', () {
    test('the column the RPC actually returns', () {
      expect(conversationIdOf(conversation('c1')), 'c1');
    });

    test('`id` still answers, for a row projected some other way', () {
      expect(conversationIdOf({'id': 'c9'}), 'c9');
    });

    test('and a row that names neither is nobody', () {
      expect(conversationIdOf(const {}), isNull);
      expect(conversationIdOf(const {'conversation_id': ''}), isNull);
    });
  });

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
        ids(
          newlyDelivered([
            conversation('c1', unread: 2),
            conversation('c2', unread: 0),
            conversation('c3', unread: 1),
          ], {}),
        ),
        ['c1', 'c3'],
      );
    });

    test('and never the same arrival twice', () {
      // Marking does not change `unread` -- the messages are
      // delivered, not read -- so a list that fired on every rebuild
      // would fire for ever.
      final row = conversation('c1', unread: 2);
      final told = {deliveryMark(row)};
      expect(newlyDelivered([row], told), isEmpty);
    });

    test('but a LATER message in the same conversation is told', () {
      // The other half of the same problem. Remembering the
      // conversation alone reports the first batch and then goes quiet
      // for the rest of the day: message two sits on one tick until the
      // app is restarted.
      final first = conversation('c1', unread: 2);
      final told = {deliveryMark(first)};
      final later = conversation(
        'c1',
        unread: 3,
        lastMessageAt: '2026-09-30T10:04:00Z',
      );
      expect(ids(newlyDelivered([later], told)), ['c1']);
    });

    test('a conversation with no id is not reported on', () {
      final orphan = conversation('c1', unread: 2)..remove('conversation_id');
      expect(newlyDelivered([orphan], {}), isEmpty);
    });

    test('nothing at all reports nothing', () {
      expect(newlyDelivered(const [], {}), isEmpty);
    });

    test('and something new alongside something told is still told', () {
      final told = {deliveryMark(conversation('c1', unread: 2))};
      expect(
        ids(
          newlyDelivered([
            conversation('c1', unread: 2),
            conversation('c2', unread: 5),
          ], told),
        ),
        ['c2'],
      );
    });
  });
}
