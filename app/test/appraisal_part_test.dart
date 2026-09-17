import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/appraisal_part.dart';

/// Which buttons the appraisal screen draws.
///
/// The rule these mirror lives in `0379` and is enforced by a trigger on
/// `appraisals`. These assertions are about the screen agreeing with it:
/// an action offered here that the database refuses is how somebody
/// learns to distrust the software.
void main() {
  final today = DateTime(2026, 7, 10);

  group('the part the database named', () {
    // Which part somebody holds is decided by `app.appraisal_part_of`
    // and asked for through `my_appraisal_parts`. It is deliberately
    // not worked out again here: two implementations of one permission
    // rule disagree eventually, and the wrong one is the one a person
    // reads. `supabase/tests/appraisals.sql` asserts the rule itself.
    test('is read as it comes', () {
      expect(partFromName('subject'), AppraisalPart.subject);
      expect(partFromName('reviewer'), AppraisalPart.reviewer);
      expect(partFromName('hr'), AppraisalPart.hr);
    });

    test('and anything else offers nothing', () {
      // Null is what a row not in the answer looks like. Guessing at a
      // part here would mean drawing a button the database refuses.
      expect(partFromName(null), AppraisalPart.none);
      expect(partFromName(''), AppraisalPart.none);
      expect(partFromName('manager'), AppraisalPart.none);
    });
  });

  group('what it is waiting for', () {
    AppraisalAction act(
      AppraisalPart part, {
      bool self = false,
      bool manager = false,
      bool completed = false,
      DateTime? due,
    }) =>
        appraisalAction(
          part: part,
          selfSubmitted: self,
          managerSubmitted: manager,
          completed: completed,
          selfDue: due,
          today: today,
        );

    test('mine, until I have written it', () {
      expect(act(AppraisalPart.subject), AppraisalAction.writeSelf);
      expect(act(AppraisalPart.subject, self: true), AppraisalAction.waiting);
    });

    test('the manager waits on the employee', () {
      expect(
        act(AppraisalPart.reviewer, due: DateTime(2026, 7, 20)),
        AppraisalAction.waiting,
      );
      expect(
        act(AppraisalPart.reviewer, self: true, due: DateTime(2026, 7, 20)),
        AppraisalAction.writeManager,
      );
    });

    test('until the day the employee\'s was due', () {
      // A review nobody wrote cannot stop the one somebody did.
      expect(
        act(AppraisalPart.reviewer, due: DateTime(2026, 7, 9)),
        AppraisalAction.writeManager,
      );
    });

    test('and the day itself is not late yet', () {
      expect(
        act(AppraisalPart.reviewer, due: DateTime(2026, 7, 10)),
        AppraisalAction.waiting,
      );
    });

    test('a cycle with no deadline waits indefinitely', () {
      // Which is the honest answer: nothing has been promised, so the
      // manager has nothing to point at.
      expect(act(AppraisalPart.reviewer), AppraisalAction.waiting);
    });

    test('HR settles it once the manager has written theirs', () {
      expect(act(AppraisalPart.hr), AppraisalAction.waiting);
      expect(act(AppraisalPart.hr, manager: true), AppraisalAction.finalise);
    });

    test('and a completed appraisal asks nothing of anybody', () {
      expect(
        act(AppraisalPart.hr, manager: true, completed: true),
        AppraisalAction.waiting,
      );
      expect(
        act(AppraisalPart.subject, completed: true),
        AppraisalAction.waiting,
      );
    });
  });

  group('the cycle\'s own scale', () {
    test('a 4 is a rating out of 5 and out of 10', () {
      expect(isRatingInScale(4, 5), isTrue);
      expect(isRatingInScale(4, 10), isTrue);
    });

    test('a 7 is one of them and not the other', () {
      expect(isRatingInScale(7, 5), isFalse);
      expect(isRatingInScale(7, 10), isTrue);
    });

    test('the top of the scale is a rating', () {
      expect(isRatingInScale(5, 5), isTrue);
    });

    test('nought is not, and neither is nothing', () {
      // Nought is what a numeric field holds when somebody tabbed past
      // it, which is not the same as a judgement that somebody made.
      expect(isRatingInScale(0, 5), isFalse);
      expect(isRatingInScale(null, 5), isFalse);
    });
  });

  group('goals that weigh the whole job', () {
    test('a hundred between them', () {
      expect(goalsWeighWholeJob([60, 40]), isTrue);
    });

    test('short, and over', () {
      expect(goalsWeighWholeJob([60, 30]), isFalse);
      expect(goalsWeighWholeJob([60, 50]), isFalse);
    });

    test('no goals is not a shortfall', () {
      // Some cycles are an overall rating and a conversation.
      expect(goalsWeighWholeJob([]), isTrue);
    });

    test('thirds add up', () {
      expect(goalsWeighWholeJob([33.33, 33.33, 33.34]), isTrue);
    });
  });
}
