import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/hr/requisition_editor.dart';

void main() {
  group('what a requisition row has to say', () {
    test('a number and a title', () {
      expect(
        requisitionBlockedBecause(
            requisitionNo: '', title: 'Driver', headcount: 1),
        contains('number'),
      );
      expect(
        requisitionBlockedBecause(
            requisitionNo: 'REQ-1', title: '  ', headcount: 1),
        contains('title'),
      );
    });

    test('and at least one person to hire', () {
      expect(
        requisitionBlockedBecause(
            requisitionNo: 'REQ-1', title: 'Driver', headcount: 0),
        contains('at least one person'),
      );
      expect(
        requisitionBlockedBecause(
            requisitionNo: 'REQ-1', title: 'Driver', headcount: 1),
        isNull,
      );
    });

    test('a salary band that runs upwards', () {
      expect(
        requisitionBlockedBecause(
          requisitionNo: 'REQ-1',
          title: 'Driver',
          headcount: 1,
          salaryMin: 4000,
          salaryMax: 2000,
        ),
        contains('runs upwards'),
      );
      // Equal is a band, not an error: a fixed rate is a band of one.
      expect(
        requisitionBlockedBecause(
          requisitionNo: 'REQ-1',
          title: 'Driver',
          headcount: 1,
          salaryMin: 4000,
          salaryMax: 4000,
        ),
        isNull,
      );
    });

    test('and a start date after the vacancy opened', () {
      expect(
        requisitionBlockedBecause(
          requisitionNo: 'REQ-1',
          title: 'Driver',
          headcount: 1,
          openedDate: DateTime(2026, 6, 1),
          targetStart: DateTime(2026, 5, 1),
        ),
        contains('before the vacancy opened'),
      );
      // A draft has no opened date yet, so a target start is unbounded.
      expect(
        requisitionBlockedBecause(
          requisitionNo: 'REQ-1',
          title: 'Driver',
          headcount: 1,
          targetStart: DateTime(2020, 1, 1),
        ),
        isNull,
      );
    });
  });

  group('whether it can be opened', () {
    test('a draft with a manager can', () {
      expect(
        openBlockedBecause({'status': 'draft', 'hiring_manager_id': 'e1'}),
        isNull,
      );
    });

    test('one on hold can too — it was open before', () {
      expect(
        openBlockedBecause({'status': 'on_hold', 'hiring_manager_id': 'e1'}),
        isNull,
      );
    });

    test('one with nobody owning it cannot, and says why', () {
      final why =
          openBlockedBecause({'status': 'draft', 'hiring_manager_id': null});
      expect(why, contains('hiring manager'));
      expect(why, contains('queue nobody is reading'));
    });

    test('and a cancelled or filled one is not reopened', () {
      expect(
        openBlockedBecause(
            {'status': 'cancelled', 'hiring_manager_id': 'e1'}),
        contains('draft or a vacancy on hold'),
      );
      expect(
        openBlockedBecause({'status': 'filled', 'hiring_manager_id': 'e1'}),
        contains('draft or a vacancy on hold'),
      );
    });
  });

  group('the row it sends', () {
    test('carries the three columns nothing ever wrote', () {
      final v = requisitionValues(
        requisitionNo: ' REQ-1 ',
        title: ' Driver ',
        headcount: 2,
        hiringManagerId: 'e1',
        requirements: ' Clean licence ',
        targetStart: DateTime(2026, 9, 30),
      );
      expect(v['requisition_no'], 'REQ-1');
      expect(v['hiring_manager_id'], 'e1');
      expect(v['requirements'], 'Clean licence');
      expect(v['target_start_date'], '2026-09-30');
    });

    test('and leaves the status and its dates to the functions', () {
      final v = requisitionValues(
          requisitionNo: 'REQ-1', title: 'Driver', headcount: 1);
      // A date typed beside a status is a date that can disagree with
      // it, so the editor never sends either.
      expect(v.containsKey('status'), isFalse);
      expect(v.containsKey('opened_date'), isFalse);
      expect(v.containsKey('closed_date'), isFalse);
    });

    test('blank text becomes null rather than an empty string', () {
      final v = requisitionValues(
        requisitionNo: 'REQ-1',
        title: 'Driver',
        headcount: 1,
        location: '   ',
        requirements: '',
      );
      expect(v['location'], isNull);
      expect(v['requirements'], isNull);
    });
  });
}
