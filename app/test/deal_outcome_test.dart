import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/crm/deal_outcome.dart';

/// The form in front of `close_opportunity`.
///
/// One rule carries this file: a lost deal has to say why, and a won one
/// does not. Everything else follows from it.
void main() {
  group('which outcomes must say why', () {
    test('lost and abandoned', () {
      expect(outcomeNeedsReason('lost'), isTrue);
      expect(outcomeNeedsReason('abandoned'), isTrue);
    });

    test('and won does not', () {
      // Deliberately asymmetric. No decision is waiting on why somebody
      // said yes, and demanding one makes winning the slower path.
      expect(outcomeNeedsReason('won'), isFalse);
    });
  });

  group('what the form will not send', () {
    test('a loss with nothing said', () {
      final why = outcomeBlockedBecause(
        outcome: 'lost',
        reason: '',
        status: 'open',
      );
      expect(why, contains('only question it is for'));
    });

    test('nor one with only whitespace', () {
      expect(
        outcomeBlockedBecause(outcome: 'lost', reason: '   ', status: 'open'),
        isNotNull,
      );
    });

    test('a win with nothing said is fine', () {
      expect(
        outcomeBlockedBecause(outcome: 'won', reason: '', status: 'open'),
        isNull,
      );
    });

    test('a deal that is already closed', () {
      expect(
        outcomeBlockedBecause(
          outcome: 'lost',
          reason: 'Price',
          status: 'won',
        ),
        contains('already closed as Won'),
      );
    });

    test('and an outcome that is not one', () {
      expect(
        outcomeBlockedBecause(
          outcome: 'maybe',
          reason: 'Who knows',
          status: 'open',
        ),
        isNotNull,
      );
    });

    test('but an ordinary loss goes through', () {
      expect(
        outcomeBlockedBecause(
          outcome: 'lost',
          reason: 'Price',
          status: 'open',
        ),
        isNull,
      );
    });
  });

  group('the three outcomes', () {
    test('include abandoned, which no stage could produce', () {
      // `opportunities.status` has allowed it since 0008 and
      // `pipeline_stages.stage_type` never did, so nothing could set it.
      expect(dealOutcomes.keys.toSet(), {'won', 'lost', 'abandoned'});
    });

    test('and each offers reasons of its own', () {
      // A shared list would put "Went with a competitor" on an abandoned
      // deal, which is a different thing that happened.
      expect(reasonsFor('lost'), contains('Went with a competitor'));
      expect(reasonsFor('abandoned'), contains('Went quiet'));
      expect(reasonsFor('won'), contains('Relationship'));
      expect(reasonsFor('abandoned'), isNot(contains('Went with a competitor')));
    });

    test('with no empty list, which would leave a blank sheet', () {
      for (final k in dealOutcomes.keys) {
        expect(reasonsFor(k), isNotEmpty, reason: k);
      }
    });

    test('and an unknown one falls back to the lost list, not to nothing', () {
      // Recorded rather than endorsed: a blank chip row reads as a form
      // that has not loaded.
      expect(reasonsFor('something_new'), lostReasons);
    });
  });

  test('the button names the outcome', () {
    expect(closeButtonLabel('lost'), 'Close as lost');
    expect(closeButtonLabel('abandoned'), 'Close as abandoned');
  });
}
