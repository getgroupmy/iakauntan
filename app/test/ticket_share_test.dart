import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/ticketing/shared_ticket_page.dart';
import 'package:iakauntan/src/features/ticketing/ticket_share_dialog.dart';

Map<String, dynamic> link({
  Object? revoked,
  String? expires,
  int opens = 0,
  int replies = 0,
}) => <String, dynamic>{
      'revoked_at': revoked,
      'expires_at': expires ?? '2099-01-01',
      'open_count': opens,
      'reply_count': replies,
    };

void main() {
  group('whether a ticket can be shared', () {
    test('one raised by a contact can', () {
      expect(
        shareBlockedBecause({'requester_contact_id': 'c1', 'status': 'open'}),
        isNull,
      );
    });

    test('one raised by staff cannot, because they have a login', () {
      expect(
        shareBlockedBecause({'requester_contact_id': null, 'status': 'open'}),
        contains('member of staff'),
      );
    });

    test('and a cancelled one is not shared', () {
      expect(
        shareBlockedBecause(
            {'requester_contact_id': 'c1', 'status': 'cancelled'}),
        contains('cancelled'),
      );
    });
  });

  group('what a link says about itself', () {
    test('a revoked one says so before anything else', () {
      expect(describeTicketLink(link(revoked: '2026-01-01', opens: 4)),
          'Revoked');
    });

    test('an expired one says when', () {
      expect(describeTicketLink(link(expires: '2020-03-01')),
          contains('Expired'));
    });

    test('an unopened one is the answer to "did they get it?"', () {
      expect(describeTicketLink(link()), contains('Not opened yet'));
    });

    test('and an opened one counts the opens and the replies', () {
      expect(describeTicketLink(link(opens: 1)), contains('opened once'));
      expect(describeTicketLink(link(opens: 3)), contains('opened 3 times'));
      expect(describeTicketLink(link(opens: 3, replies: 1)),
          contains('1 reply'));
      expect(describeTicketLink(link(opens: 3, replies: 2)),
          contains('2 replies'));
    });

    test('a reply count of nought is not mentioned', () {
      expect(describeTicketLink(link(opens: 2)), isNot(contains('repl')));
    });
  });

  group('what the person holding the link is told', () {
    test('expired and revoked each say what to do next', () {
      expect(sharedTicketSentence('expired'), contains('Ask us'));
      expect(sharedTicketSentence('revoked'), contains('more recent'));
    });

    test('a withdrawn request says so', () {
      expect(sharedTicketSentence('withdrawn'), contains('withdrawn'));
    });

    test('and an unknown token gives nothing away about which are real',
        () {
      final unknown = sharedTicketSentence('invalid');
      expect(unknown, contains('could not find'));
      // The same sentence for anything unrecognised: distinguishing them
      // tells somebody guessing tokens when they have found a real one.
      expect(sharedTicketSentence('anything else'), unknown);
    });
  });

  group('which side of the conversation a comment is on', () {
    test('the requester\'s own message', () {
      expect(commentIsMine({'mine': true}), isTrue);
    });

    test('and the company\'s', () {
      expect(commentIsMine({'mine': false}), isFalse);
      // Absent is the company's too, rather than an error: the page
      // must render whatever the server sends.
      expect(commentIsMine(<String, dynamic>{}), isFalse);
    });
  });
}
