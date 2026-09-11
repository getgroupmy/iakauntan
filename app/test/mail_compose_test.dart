import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/mail/compose.dart';

/// The compose box, without the box.
///
/// `0328`'s inbox could not answer anybody, which was the right shape
/// for `sales@` and the wrong one the moment `0559` made an address
/// somebody's own: the customer writes to `aisyah@`, Aisyah replies
/// from Gmail, and half the conversation is no longer the company's.
void main() {
  group('who it is going to', () {
    test('an empty box is not a rejection', () {
      // "That is not an email address" about a box nobody has typed in
      // reads as the form arguing with them.
      expect(checkRecipient('  '), 'Who is this going to?');
    });

    test('a name without a domain is caught before anything is queued', () {
      expect(checkRecipient('customer'), isNotNull);
      expect(checkRecipient('customer@'), isNotNull);
      expect(checkRecipient('customer@example'), isNotNull);
      expect(checkRecipient('a b@example.com'), isNotNull);
    });

    test('and an address is let through', () {
      expect(checkRecipient('customer@example.com'), isNull);
      expect(checkRecipient('  customer@example.com  '), isNull);
      expect(checkRecipient('siti.rahman+po@sub.example.com.my'), isNull);
    });
  });

  group('the subject of a reply', () {
    test('says Re: once', () {
      expect(replySubject('About your invoice'), 'Re: About your invoice');
    });

    test('and not five times', () {
      // What a thread looks like after everybody has answered everybody
      // if the prefix is added blindly.
      expect(replySubject('Re: About your invoice'), 'Re: About your invoice');
      expect(replySubject('RE: About your invoice'), 'RE: About your invoice');
      expect(replySubject('re : About your invoice'),
          're : About your invoice');
    });

    test('and says something when the original said nothing', () {
      expect(replySubject(null), 'Re: (no subject)');
      expect(replySubject('   '), 'Re: (no subject)');
    });
  });

  group('the original, underneath', () {
    test('is quoted the way mail has always quoted it', () {
      final out = quotedReply(
        from: 'customer@example.com',
        body: 'Which month is this?\nThe second line.',
        at: DateTime(2026, 3, 7),
      );
      expect(out, contains('> Which month is this?'));
      expect(out, contains('> The second line.'));
      expect(out, contains('customer@example.com wrote on 07/03/2026:'));
    });

    test('and the cursor lands above it', () {
      // A reply box whose first character sits against the quoted text
      // is one people delete their way out of before typing.
      expect(quotedReply(from: 'a@b.com', body: 'x'), startsWith('\n\n'));
    });

    test('an empty line stays a line', () {
      final out = quotedReply(from: 'a@b.com', body: 'one\n\ntwo');
      expect(out, contains('\n>\n'));
    });

    test('and nothing to quote is still an answerable message', () {
      expect(quotedReply(from: 'a@b.com'), contains('a@b.com wrote:'));
    });
  });

  group('the address a mailbox stands for', () {
    test('ends in the domain the database named', () {
      // Not a literal. `0328` made the domain a setting so a deployment
      // under another name would not need a migration edited, and a
      // constant in the app is the same mistake one layer up.
      expect(
        mailboxAddress(const {'local_part': 'aisyah'}, 'example.com'),
        'aisyah@example.com',
      );
    });

    test('and the picker says which of them colleagues can read', () {
      // The difference somebody is actually choosing between.
      expect(mailboxKind(const {'is_personal': true}), 'Yours');
      expect(
        mailboxKind(const {'is_personal': false}),
        'Shared with the company',
      );
    });
  });

  group('a line in the list', () {
    test('knows which way it went', () {
      expect(isOutgoing(const {'direction': 'out'}), isTrue);
      expect(isOutgoing(const {'direction': 'in'}), isFalse);
    });

    test('and says where a sent one got to', () {
      expect(
        deliveryNote(const {'direction': 'out', 'status': 'queued'}),
        'Sending',
      );
      expect(
        deliveryNote(const {'direction': 'out', 'status': 'failed'}),
        'Could not be sent',
      );
    });

    test('and says nothing at all about one that arrived', () {
      // "Received" against something sitting in the inbox is a label
      // for a fact the reader can already see.
      expect(
        deliveryNote(const {'direction': 'in', 'status': 'received'}),
        isNull,
      );
    });
  });
}
