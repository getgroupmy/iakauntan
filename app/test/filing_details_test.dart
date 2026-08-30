import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/financials/filing_details.dart';

void main() {
  group('what a lodged filing will not take', () {
    test('is exactly what the trigger names', () {
      // app.fs_refuse_lodged_edit compares these seven and no others.
      expect(kLodgedLockedFields, {
        'fy_start',
        'fy_end',
        'framework',
        'audit_status',
        'opinion',
        'audit_report_date',
        'auditor_name',
      });
    });

    test('a draft takes everything', () {
      for (final f in kLodgedLockedFields) {
        expect(filingFieldIsEditable('draft', f), isTrue, reason: f);
      }
      expect(filingFieldIsEditable('draft', 'notes'), isTrue);
    });

    test('a frozen filing takes everything too', () {
      // Freezing is about the figures. The trigger on fs_filings only
      // ever asks whether the row was lodged.
      expect(filingFieldIsEditable('frozen', 'opinion'), isTrue);
      expect(filingFieldIsEditable('frozen', 'auditor_name'), isTrue);
    });

    test('a lodged one closes what the accounts say', () {
      expect(filingFieldIsEditable('lodged', 'opinion'), isFalse);
      expect(filingFieldIsEditable('lodged', 'framework'), isFalse);
      expect(filingFieldIsEditable('lodged', 'fy_end'), isFalse);
    });

    test('and leaves open what the trigger does not name', () {
      // The firm number, the signatory, the headcount, the going
      // concern flag and the notes are not in the comparison, so the
      // form follows the trigger rather than the sentence beside it.
      for (final f in [
        'auditor_firm_no',
        'auditor_signatory',
        'employee_count',
        'going_concern_emphasis',
        'notes',
        'directors_approval_date',
        'circulated_on',
      ]) {
        expect(filingFieldIsEditable('lodged', f), isTrue, reason: f);
      }
    });
  });

  group('the headcount', () {
    test('is a whole number of people', () {
      expect(headcountOf('7'), 7);
      expect(headcountOf(' 12 '), 12);
    });

    test('may be nobody', () {
      // A dormant company has no employees, and zero is the answer,
      // not a refusal.
      expect(headcountOf('0'), 0);
    });

    test('blank stays blank, which is a real answer', () {
      // fs_audit_exemption says "cannot tell" rather than guessing.
      expect(headcountOf(''), isNull);
      expect(headcountOf('   '), isNull);
    });

    test('a negative is not a headcount', () {
      // The column checks it, and this is a number somebody signs a
      // declaration over.
      expect(headcountOf('-1'), isNull);
    });

    test('nor is a fraction of a person', () {
      expect(headcountOf('7.5'), isNull);
      expect(headcountOf('about ten'), isNull);
    });
  });

  group('the financial year', () {
    test('has to end after it begins', () {
      // fs_filings_period is fy_end > fy_start, strictly.
      expect(
        filingPeriodRuns(DateTime(2025, 1, 1), DateTime(2025, 12, 31)),
        isTrue,
      );
      expect(
        filingPeriodRuns(DateTime(2025, 12, 31), DateTime(2025, 1, 1)),
        isFalse,
      );
    });

    test('a single day is not a period', () {
      final d = DateTime(2025, 6, 30);
      expect(filingPeriodRuns(d, d), isFalse);
    });

    test('an unanswered date is not a period either', () {
      expect(filingPeriodRuns(null, DateTime(2025, 1, 1)), isFalse);
      expect(filingPeriodRuns(DateTime(2025, 1, 1), null), isFalse);
    });
  });

  group('what gets written', () {
    Map<String, dynamic> patch({
      String status = 'draft',
      String? opinion,
      String? auditorName,
      DateTime? reportDate,
      int? employeeCount,
      String? notes,
      bool goingConcern = false,
    }) =>
        filingValues(
          status: status,
          fyStart: DateTime(2025, 1, 1),
          fyEnd: DateTime(2025, 12, 31),
          framework: 'mpers',
          auditStatus: 'audited',
          goingConcernEmphasis: goingConcern,
          opinion: opinion,
          auditorName: auditorName,
          auditReportDate: reportDate,
          employeeCount: employeeCount,
          notes: notes,
        );

    test('dates go as dates', () {
      final p = patch(reportDate: DateTime(2026, 3, 14));
      expect(p['fy_start'], '2025-01-01');
      expect(p['fy_end'], '2025-12-31');
      expect(p['audit_report_date'], '2026-03-14');
    });

    test('a date nobody has given goes as null, not as missing', () {
      // Dropping the key would leave a stale value standing, and these
      // are facts a director signs a declaration over.
      final p = patch();
      expect(p.containsKey('audit_report_date'), isTrue);
      expect(p['audit_report_date'], isNull);
      expect(p.containsKey('opinion'), isTrue);
      expect(p['opinion'], isNull);
      expect(p.containsKey('employee_count'), isTrue);
      expect(p['employee_count'], isNull);
    });

    test('text is trimmed, and blank becomes null', () {
      expect(patch(auditorName: '  Chan & Co  ')['auditor_name'], 'Chan & Co');
      expect(patch(auditorName: '   ')['auditor_name'], isNull);
      expect(patch(notes: '')['notes'], isNull);
    });

    test('the going concern flag is a boolean, never null', () {
      // The column is not null.
      expect(patch()['going_concern_emphasis'], isFalse);
      expect(patch(goingConcern: true)['going_concern_emphasis'], isTrue);
    });

    test('a zero headcount survives', () {
      expect(patch(employeeCount: 0)['employee_count'], 0);
    });

    test('a lodged filing is sent only what it will take', () {
      final p = patch(status: 'lodged', opinion: 'qualified', notes: 'x');
      // Sending a locked field would raise 42501 over a value the user
      // very likely did not change.
      for (final f in kLodgedLockedFields) {
        expect(p.containsKey(f), isFalse, reason: f);
      }
      expect(p['notes'], 'x');
      expect(p.containsKey('employee_count'), isTrue);
    });

    test('a draft is sent the lot', () {
      final p = patch(opinion: 'unmodified');
      for (final f in kLodgedLockedFields) {
        expect(p.containsKey(f), isTrue, reason: f);
      }
      expect(p['opinion'], 'unmodified');
    });
  });

  group('the choices offered', () {
    test('are the enums', () {
      expect(kFrameworks, ['mpers', 'mfrs']);
      expect(kAuditStatuses, ['audited', 'audit_exempt', 'unaudited']);
      expect(kOpinions, ['unmodified', 'qualified', 'adverse', 'disclaimer']);
    });

    test('unaudited and audit exempt are both offered, being different', () {
      // A company qualifying under PD 3/2018 files unaudited accounts
      // on that ground; one that simply has not had them audited is
      // something else, and MBRS asks which.
      expect(kAuditStatuses, contains('unaudited'));
      expect(kAuditStatuses, contains('audit_exempt'));
    });
  });
}
