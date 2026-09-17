import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/legal/matter_transfer.dart';

/// Moving a client's money between their own matters.
///
/// Both decisions here are about money and both are silent when wrong.
/// A transfer to another client's matter balances perfectly and is a
/// breach of the rule a client account exists to enforce; a transfer of
/// more than is held leaves a client ledger in debit.
void main() {
  Matter m(String id, String no, String client) =>
      Matter(id: id, matterNo: no, name: no, clientId: client, status: 'open');

  final sale = m('1', 'M-1', 'aminah');
  final lease = m('2', 'M-2', 'aminah');
  final closed = m('3', 'M-3', 'aminah');
  final theirs = m('4', 'M-4', 'rajan');

  group('where the money may go', () {
    test("only the same client's other matters", () {
      final to = transferDestinations([sale, lease, closed, theirs], sale);
      expect(to.map((x) => x.id), ['2', '3']);
    });

    test('never back to itself', () {
      // A self-transfer is two rows that cancel, an audit trail entry
      // for nothing, and a document number spent.
      expect(
        transferDestinations([sale], sale),
        isEmpty,
      );
    });

    test('and never somebody else, however many matters they have', () {
      final to = transferDestinations([theirs, m('5', 'M-5', 'rajan')], sale);
      expect(to, isEmpty);
    });
  });

  group('whether it may be made', () {
    test('nothing to move to is the first thing missing', () {
      expect(
        transferBlockedBecause(held: 5000, amount: 100, to: null),
        'Choose the matter it moves to.',
      );
    });

    test('nor is nothing an amount', () {
      for (final a in const [0.0, -1.0]) {
        expect(
          transferBlockedBecause(held: 5000, amount: a, to: lease),
          'Enter an amount to move.',
          reason: '$a',
        );
      }
    });

    test('more than the matter holds is refused, and says how much', () {
      final why = transferBlockedBecause(held: 3000, amount: 3000.01, to: lease);
      // The figure, not "insufficient funds". Somebody is looking at two
      // numbers and needs to know which one is the problem.
      expect(why, contains('3000.00'));
    });

    test('exactly what it holds is allowed', () {
      // The boundary, and the ordinary case: a finished matter's whole
      // balance following the client to the next one.
      expect(transferBlockedBecause(held: 3000, amount: 3000, to: lease), isNull);
    });

    test('and anything under it', () {
      expect(transferBlockedBecause(held: 3000, amount: 1, to: lease), isNull);
    });
  });

  group('what the sheet says about it', () {
    test('before a destination is chosen, what the action is for', () {
      expect(transferBlurb(sale, null), contains('M-1'));
    });

    test('and after, that the bank has not been told', () {
      // A solicitor reading "transfer" reasonably wonders whether money
      // has left the client account. It has not, and saying so is the
      // difference between this and a Rule 7 withdrawal.
      final blurb = transferBlurb(sale, lease);
      expect(blurb, contains('Nothing leaves the client account'));
      expect(blurb, contains('M-1'));
      expect(blurb, contains('M-2'));
    });
  });
}
