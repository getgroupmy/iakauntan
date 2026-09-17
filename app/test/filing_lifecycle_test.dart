import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/secretarial/filing_lifecycle.dart';

void main() {
  group('whether anybody has taken the deadline up', () {
    test('not until a filing row exists', () {
      // corp_upcoming_filings computes every deadline the Act imposes
      // and leaves filing_id null until corp_open_filing creates one.
      expect(filingIsOpen(null), isFalse);
      expect(filingIsOpen('f1'), isTrue);
    });
  });

  group('whether it is finished with', () {
    test('lodged is', () {
      expect(filingIsSettled('lodged'), isTrue);
    });

    test('approved is — SSM accepting it only follows lodgement', () {
      expect(filingIsSettled('approved'), isTrue);
    });

    test('not applicable is: somebody decided the Act does not reach it', () {
      expect(filingIsSettled('not_applicable'), isTrue);
    });

    test('everything else is still live', () {
      for (final s in [
        'not_due',
        'due',
        'in_preparation',
        'awaiting_signature',
        'rejected',
      ]) {
        expect(filingIsSettled(s), isFalse, reason: s);
      }
    });

    test('a rejected filing is live again, not finished', () {
      // SSM sending it back is the start of more work, not the end of
      // it, and a row that read as settled would drop off the list.
      expect(filingIsSettled('rejected'), isFalse);
      expect(filingNextStep('f1', 'rejected'), 'lodge');
    });
  });

  group('what the row offers next', () {
    test('a deadline nobody has started', () {
      expect(filingNextStep(null, 'due'), 'open');
      expect(filingNextStep(null, 'not_due'), 'open');
    });

    test('one somebody is working on', () {
      expect(filingNextStep('f1', 'in_preparation'), 'lodge');
      expect(filingNextStep('f1', 'awaiting_signature'), 'lodge');
    });

    test('one that is over', () {
      expect(filingNextStep('f1', 'lodged'), 'done');
      expect(filingNextStep('f1', 'approved'), 'done');
    });

    test('settled wins over unopened, which should not happen but might', () {
      // A filing marked not applicable before anybody opened a row for
      // it has nothing to start.
      expect(filingNextStep(null, 'not_applicable'), 'done');
    });
  });

  group('the SSM reference', () {
    test('is what was typed, trimmed', () {
      expect(ssmReferenceOf('  AR-2026-0001  '), 'AR-2026-0001');
    });

    test('is null when nothing usable was typed', () {
      // Better than a blank string that reads like a reference nobody
      // can find. The acknowledgement often comes back later.
      expect(ssmReferenceOf(''), isNull);
      expect(ssmReferenceOf('   '), isNull);
    });
  });

  group('whether the lodgement could have happened', () {
    final today = DateTime(2026, 8, 31);

    test('today can', () {
      expect(lodgementHasHappened(DateTime(2026, 8, 31), today), isTrue);
    });

    test('any day before can', () {
      expect(lodgementHasHappened(DateTime(2026, 3, 14), today), isTrue);
    });

    test('tomorrow cannot', () {
      expect(lodgementHasHappened(DateTime(2026, 9, 1), today), isFalse);
    });

    test('the time of day does not decide it', () {
      // A picker hands back midnight; "now" is the afternoon. Compared
      // whole, today is today.
      expect(
        lodgementHasHappened(
          DateTime(2026, 8, 31),
          DateTime(2026, 8, 31, 16, 40),
        ),
        isTrue,
      );
    });

    test('nor does it when the date is the later of the two', () {
      // The field opens at DateTime.now(), which carries a time. An
      // instant-to-instant comparison would call this evening "not yet
      // happened" while the same date at midnight passed — the same
      // day answering two ways.
      expect(
        lodgementHasHappened(
          DateTime(2026, 8, 31, 23, 0),
          DateTime(2026, 8, 31, 16, 40),
        ),
        isTrue,
      );
    });
  });
}
