import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/timesheets/time_entry_sheet.dart';

void main() {
  group('how long', () {
    test('decimal hours, the way most people write it', () {
      expect(minutesOf('1.5'), 90);
      expect(minutesOf('0.25'), 15);
      expect(minutesOf('2'), 120);
      expect(minutesOf('8'), 480);
    });

    test('hours and minutes, the way the rest write it', () {
      expect(minutesOf('1:30'), 90);
      expect(minutesOf('0:45'), 45);
      expect(minutesOf('2:00'), 120);
      expect(minutesOf('0:05'), 5);
    });

    test('the two forms agree', () {
      expect(minutesOf('1.5'), minutesOf('1:30'));
      expect(minutesOf('0.25'), minutesOf('0:15'));
    });

    test('a trailing h is allowed, because people type it', () {
      expect(minutesOf('1.5h'), 90);
      expect(minutesOf('1:30h'), 90);
      expect(minutesOf(' 2 h '), 120);
    });

    test('nothing is not a duration', () {
      expect(minutesOf(''), isNull);
      expect(minutesOf('   '), isNull);
      expect(minutesOf('h'), isNull);
      expect(minutesOf('a while'), isNull);
    });

    test('zero and below are refused, as the check constraint refuses them', () {
      // minutes integer not null check (minutes > 0)
      expect(minutesOf('0'), isNull);
      expect(minutesOf('0:00'), isNull);
      expect(minutesOf('-1'), isNull);
      expect(minutesOf('-1:30'), isNull);
    });

    test('sixty minutes past the hour is a typo, not two hours', () {
      // 1:60 could mean 2:00 or could be a slip. Guessing which is
      // worse than asking.
      expect(minutesOf('1:60'), isNull);
      expect(minutesOf('1:99'), isNull);
    });

    test('more than two parts is not a duration', () {
      expect(minutesOf('1:30:00'), isNull);
    });

    test('rounds to a whole minute', () {
      // 0.26 hours is 15.6 minutes.
      expect(minutesOf('0.26'), 16);
      expect(minutesOf('0.01'), 1);
    });

    test('a duration that rounds to nothing is nothing', () {
      // 0.001 hours is 0.06 of a minute, and an entry of zero minutes
      // would be refused by the column.
      expect(minutesOf('0.001'), isNull);
    });
  });

  test('a recorded duration reads back in hours', () {
    expect(hoursLabel(90), '1.50h');
    expect(hoursLabel(15), '0.25h');
    expect(hoursLabel(480), '8.00h');
  });

  group('what the hour is against', () {
    test('one selection cannot name both a project and a matter', () {
      final v = anchorValue('project', 'p1');
      expect(anchorProjectId(v), 'p1');
      expect(anchorMatterId(v), isNull);

      final m = anchorValue('matter', 'm1');
      expect(anchorMatterId(m), 'm1');
      expect(anchorProjectId(m), isNull);
    });

    test('nothing selected is neither', () {
      expect(anchorProjectId(null), isNull);
      expect(anchorMatterId(null), isNull);
    });

    test('an existing row lands on its own entry of the list', () {
      expect(anchorOf(projectId: 'p1'), anchorValue('project', 'p1'));
      expect(anchorOf(matterId: 'm1'), anchorValue('matter', 'm1'));
      expect(anchorOf(), isNull);
    });

    test('an id that itself contains a colon still resolves', () {
      // Ids are uuids today, but the parse should not depend on that.
      expect(anchorProjectId('project:a:b'), 'a:b');
    });
  });

  group('chargeable to somebody', () {
    test('billable time needs a project or a matter', () {
      // "Billable time has to be against a matter or a project — there
      // is otherwise nobody to invoice for it."
      expect(chargeableToSomething(isBillable: true), isFalse);
      expect(
        chargeableToSomething(isBillable: true, projectId: 'p1'),
        isTrue,
      );
      expect(
        chargeableToSomething(isBillable: true, matterId: 'm1'),
        isTrue,
      );
    });

    test('unbillable time is allowed to float free', () {
      // Training, admin, writing the migration: the only way a
      // timesheet says anything about utilisation.
      expect(chargeableToSomething(isBillable: false), isTrue);
    });
  });

  group('whether it can still be changed', () {
    test('not once it has been billed', () {
      expect(timeEntryIsEditable(true), isFalse);
    });

    test('yes while it is only recorded', () {
      expect(timeEntryIsEditable(false), isTrue);
    });
  });

  group('what gets written', () {
    Map<String, dynamic> values({
      String? projectId,
      String? matterId,
      bool isBillable = true,
      String? activityCode,
      String? userId,
      String description = 'Drafting the shareholders agreement',
    }) =>
        timeEntryValues(
          entryDate: DateTime(2026, 3, 17),
          description: description,
          minutes: 90,
          isBillable: isBillable,
          projectId: projectId,
          matterId: matterId,
          activityCode: activityCode,
          userId: userId,
        );

    test('the date goes as a date', () {
      expect(values(projectId: 'p1')['entry_date'], '2026-03-17');
    });

    test('the description is trimmed', () {
      expect(
        values(projectId: 'p1', description: '  Court attendance  ')[
            'description'],
        'Court attendance',
      );
    });

    test('no rate is sent at all', () {
      // apply_billing_rate fills it from the card before calc_amount
      // multiplies by it. A zero would be read as "not given" and
      // filled; a number would override the card.
      expect(values(projectId: 'p1').containsKey('hourly_rate'), isFalse);
      expect(values(projectId: 'p1').containsKey('amount'), isFalse);
    });

    test('both anchor keys are always present', () {
      // On an edit that moves an hour from a project to a matter,
      // omitting the old key would leave its old value in place and the
      // row would name two anchors, which time_entries_one_anchor
      // refuses.
      final v = values(matterId: 'm1');
      expect(v.containsKey('project_id'), isTrue);
      expect(v['project_id'], isNull);
      expect(v['matter_id'], 'm1');

      final w = values(projectId: 'p1');
      expect(w.containsKey('matter_id'), isTrue);
      expect(w['matter_id'], isNull);
      expect(w['project_id'], 'p1');
    });

    test('an hour against nothing sends both as null', () {
      final v = values(isBillable: false);
      expect(v['project_id'], isNull);
      expect(v['matter_id'], isNull);
      expect(v['is_billable'], isFalse);
    });

    test('an uncategorised activity is null, not an empty string', () {
      expect(values(projectId: 'p1')['activity_code'], isNull);
      expect(values(projectId: 'p1', activityCode: '  ')['activity_code'],
          isNull);
      expect(
        values(projectId: 'p1', activityCode: 'drafting')['activity_code'],
        'drafting',
      );
    });

    test('whose time is only sent when it was chosen', () {
      // Left out, the repository stamps the signed-in user.
      expect(values(projectId: 'p1').containsKey('user_id'), isFalse);
      expect(values(projectId: 'p1', userId: 'u1')['user_id'], 'u1');
    });
  });
}
