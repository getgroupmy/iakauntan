import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/legal/matter_closing.dart';

/// The form in front of `close_matter`.
///
/// The interesting line here is the one between a refusal and a warning,
/// and it is drawn by whose money it is. The client's stops the close
/// outright; the firm's own is reported so somebody can decide.
void main() {
  group('what stops a file closing', () {
    test('money still held for the client', () {
      final why = closeBlockedBecause(status: 'open', clientFunds: 5000);
      expect(why, isNotNull);
      expect(why, contains('Pay it out'));
    });

    test('and an overdrawn matter, for a different reason', () {
      // Not a smaller version of the same problem. A negative balance is
      // one client's money funding another's file, which is the breach
      // the client account exists to prevent.
      final why = closeBlockedBecause(status: 'open', clientFunds: -250);
      expect(why, contains('another client'));
      expect(why, isNot(contains('Pay it out')));
    });

    test('and a file that is already closed', () {
      expect(
        closeBlockedBecause(status: 'closed', clientFunds: 0),
        contains('already closed'),
      );
    });

    test('but nothing else does', () {
      expect(closeBlockedBecause(status: 'open', clientFunds: 0), isNull);
      expect(closeBlockedBecause(status: 'on_hold', clientFunds: 0), isNull);
    });

    test('and a balance of half a sen is rounding, not money', () {
      // The column is numeric(18, 2); this guards the double the app
      // reads it back into, so that a file is not held open for ever by
      // a figure that does not exist.
      expect(closeBlockedBecause(status: 'open', clientFunds: 0.004), isNull);
      expect(
        closeBlockedBecause(status: 'open', clientFunds: 0.01),
        isNotNull,
        reason: 'one sen is money',
      );
    });
  });

  group('what is said rather than refused', () {
    test('unbilled time', () {
      expect(
        unbilledWarning(unbilledTime: 2400, unbilledDisbursements: 0),
        allOf(contains('unbilled time'), contains('does not bill them')),
      );
    });

    test('unbilled disbursements', () {
      expect(
        unbilledWarning(unbilledTime: 0, unbilledDisbursements: 108),
        contains('unbilled disbursements'),
      );
    });

    test('both, in one sentence', () {
      expect(
        unbilledWarning(unbilledTime: 2400, unbilledDisbursements: 108),
        contains('unbilled time and disbursements'),
      );
    });

    test('and nothing at all when there is nothing to say', () {
      expect(
        unbilledWarning(unbilledTime: 0, unbilledDisbursements: 0),
        isNull,
      );
    });

    test('which is a warning and never a refusal', () {
      // Stated as an assertion because the temptation to promote it is
      // real: the two are decided by different questions, and closing a
      // file with work in progress is a commercial decision the firm is
      // entitled to make.
      expect(
        closeBlockedBecause(status: 'open', clientFunds: 0),
        isNull,
        reason: 'unbilled work is not the client\'s money',
      );
    });
  });

  group('putting a file back into service', () {
    test('a closed or archived one can be', () {
      expect(canReopen('closed'), isTrue);
      expect(canReopen('archived'), isTrue);
    });

    test('and an open one has nothing to reopen', () {
      expect(canReopen('open'), isFalse);
      expect(canReopen('on_hold'), isFalse);
    });
  });
}
