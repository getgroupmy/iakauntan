import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/banking/book_balance.dart';

/// Rebuilding a bank balance, and saying whether it moved.
///
/// The arithmetic itself is asserted in
/// `supabase/tests/bank_balance_resync.sql` and belongs there — it is
/// the database's. What is asserted here is the sentence the screen
/// shows afterwards, because a repair that silently corrects a figure
/// teaches nobody that the figure was wrong, and a balance that was
/// wrong is evidence that something posted against the bank's GL
/// account without going through the running total.
void main() {
  group('whether the number moved', () {
    test('the same money is not a move, however it arrived', () {
      // `current_balance` is numeric(18, 2) and comes back through a
      // JSON double, so `==` compares a rounding artefact rather than
      // money. 1200.00 and 1200.0000000000002 are the same balance.
      expect(balanceMoved(1200.00, 1200.00), isFalse);
      expect(balanceMoved(1200.00, 1200.0000000000002), isFalse);
      expect(balanceMoved(0, 0), isFalse);
    });

    test('and a sen is a move, because a sen is out', () {
      expect(balanceMoved(1200.00, 1200.01), isTrue);
      expect(balanceMoved(1200.01, 1200.00), isTrue);
    });

    test('in either direction, and across zero', () {
      expect(balanceMoved(-50.00, 50.00), isTrue);
      expect(balanceMoved(0, -0.01), isTrue);
    });
  });

  group('what it says afterwards', () {
    test('nothing moved, said plainly and without a figure to chase', () {
      final said = resyncOutcome(before: 7000, after: 7000);

      expect(said, contains('already matched the ledger'));
      expect(said, isNot(contains('→')));
    });

    test('a balance that was too high names both figures and the gap', () {
      final said = resyncOutcome(before: 7050, after: 7000);

      expect(said, contains('RM 7,050.00'));
      expect(said, contains('RM 7,000.00'));
      expect(said, contains('down by RM 50.00'));
    });

    test('and one that was too low reads the other way', () {
      final said = resyncOutcome(before: 6950, after: 7000);

      expect(said, contains('up by RM 50.00'));
      expect(said, isNot(contains('down')));
    });

    test('the gap is never signed twice', () {
      // "down by RM -50.00" is the shape this guards against: the
      // direction is in the word, so the figure is an absolute.
      expect(resyncOutcome(before: 7050, after: 7000), isNot(contains('-')));
    });

    test('and it says a rebuild is worth looking into, not just done', () {
      final said = resyncOutcome(before: 7050, after: 7000);

      expect(said, contains('without going through the running total'));
    });
  });

  group('what the button promises', () {
    test('it says which way the reading goes', () {
      // Somebody who thinks this might rewrite the ledger will not press
      // it, and they would be right not to.
      expect(kResyncBlurb, contains('from posted ledger entries'));
      expect(kResyncBlurb, contains('ledger is not changed'));
    });
  });
}
