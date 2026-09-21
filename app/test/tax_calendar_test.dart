import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';

/// The Dart side of the LHDN filing calendar.
///
/// Every date in it is computed in SQL and asserted in
/// `supabase/tests/tax_filing_calendar.sql` — that is where a year end
/// moving by a day fails. What is asserted here is what the SCREEN
/// decides about a date it has been handed:
///
///   * **Late is not "nearly due".** An obligation already missed is
///     the one somebody most needs to see, and it is a different thing
///     from one falling due next week. `isImminent` must not claim an
///     overdue filing, or the late ones disappear into the warnings.
///   * **A working nobody has opened is not a working.** The link into
///     the computation appears only where there is one, and a CP204
///     row leads to the estimate rather than the computation — the
///     right screen for the wrong half of the year is still the wrong
///     screen.
///   * **`days_left` goes negative** and the countdown has to read it
///     that way round, or a filing three days late reads as three days
///     of grace.
void main() {
  TaxFiling filing({
    String type = 'form_c',
    int daysLeft = 90,
    bool overdue = false,
    String? computation,
    String? estimate,
    DateTime? efiling,
  }) => TaxFiling(
    filingType: type,
    name: 'Return of a company',
    formLabel: 'C',
    statuteRef: 'ITA 1967 s.77A(1)',
    periodFrom: DateTime(2025, 7, 1),
    periodTo: DateTime(2026, 6, 30),
    yearOfAssessment: 2026,
    dueDate: DateTime(2027, 1, 31),
    efilingDueDate: efiling,
    daysLeft: daysLeft,
    isOverdue: overdue,
    description: null,
    fiscalYearId: 'fy1',
    computationId: computation,
    estimateId: estimate,
  );

  group('how close it is', () {
    test('a month out is close enough to interrupt somebody', () {
      expect(filing(daysLeft: 30).isImminent, isTrue);
      expect(filing(daysLeft: 1).isImminent, isTrue);
      expect(filing(daysLeft: 0).isImminent, isTrue);
    });

    test('a month and a day is not', () {
      expect(filing(daysLeft: 31).isImminent, isFalse);
      expect(filing(daysLeft: 200).isImminent, isFalse);
    });

    test('and something already late is not "imminent" either', () {
      // The distinction the whole warning rests on. An overdue filing
      // has a negative `daysLeft`, which is trivially under thirty —
      // so without the overdue guard every late filing would be
      // coloured as a warning and lost among them.
      expect(filing(daysLeft: -12, overdue: true).isImminent, isFalse);
      expect(filing(daysLeft: -400, overdue: true).isImminent, isFalse);
    });
  });

  group('whether the work has been started', () {
    test('a computation counts', () {
      expect(filing(computation: 'c1').hasWorking, isTrue);
    });

    test('an estimate counts', () {
      expect(filing(type: 'cp204', estimate: 'e1').hasWorking, isTrue);
    });

    test('and nothing at all does not', () {
      // A deadline with nothing behind it is a deadline nobody has
      // started, and the screen says nothing rather than offering a
      // link into a document that does not exist.
      expect(filing().hasWorking, isFalse);
    });
  });

  group('reading the server back', () {
    test('every field lands in its own place', () {
      // Different values in every position, so a transposition between
      // two of them cannot pass.
      final f = TaxFiling.fromMap(const {
        'filing_type': 'form_c',
        'filing_name': 'Return of a company',
        'form_label': 'C',
        'statute_ref': 'ITA 1967 s.77A(1)',
        'fiscal_year_id': 'fy-1',
        'period_from': '2025-07-01',
        'period_to': '2026-06-30',
        'year_of_assessment': 2026,
        'due_date': '2027-01-31',
        'efiling_due_date': '2027-02-28',
        'days_left': 132,
        'is_overdue': false,
        'description': 'Seven months from the day following the close.',
        'computation_id': 'comp-1',
        'estimate_id': 'est-1',
      });

      expect(f.filingType, 'form_c');
      expect(f.name, 'Return of a company');
      expect(f.formLabel, 'C');
      expect(f.statuteRef, 'ITA 1967 s.77A(1)');
      expect(f.fiscalYearId, 'fy-1');
      expect(f.periodFrom, DateTime(2025, 7, 1));
      expect(f.periodTo, DateTime(2026, 6, 30));
      expect(f.yearOfAssessment, 2026);
      expect(f.dueDate, DateTime(2027, 1, 31));
      expect(f.efilingDueDate, DateTime(2027, 2, 28));
      expect(f.daysLeft, 132);
      expect(f.isOverdue, isFalse);
      expect(f.computationId, 'comp-1');
      expect(f.estimateId, 'est-1');
      expect(f.hasWorking, isTrue);
      expect(f.isImminent, isFalse);
    });

    test('a form with no e-filing concession has none', () {
      // Null is not "the same day". The Filing Programme grants extra
      // time for some forms and not others, and a screen that printed
      // the statutory date twice would look like a concession there is
      // no evidence for.
      final f = TaxFiling.fromMap(const {
        'filing_type': 'form_ea',
        'filing_name': 'Statement of remuneration',
        'form_label': 'EA',
        'due_date': '2027-02-28',
        'days_left': 160,
        'is_overdue': false,
        'year_of_assessment': 2026,
      });
      expect(f.efilingDueDate, isNull);
      expect(f.computationId, isNull);
      expect(f.hasWorking, isFalse);
    });

    test('an overdue filing comes back with days past, not days left', () {
      final f = TaxFiling.fromMap(const {
        'filing_type': 'form_c',
        'filing_name': 'Return of a company',
        'form_label': 'C',
        'due_date': '2024-07-31',
        'days_left': -418,
        'is_overdue': true,
        'year_of_assessment': 2023,
      });
      expect(f.daysLeft, -418);
      expect(f.isOverdue, isTrue);
      expect(f.isImminent, isFalse);
    });

    test('a period Form E covers is a calendar year, as the server said', () {
      // The screen does not decide this — `0668` does, because a Form E
      // covers 1 January to 31 December whatever the company's own year
      // end is. What is asserted here is that the model carries the
      // server's answer rather than substituting the fiscal year.
      final f = TaxFiling.fromMap(const {
        'filing_type': 'form_e',
        'filing_name': 'Employer’s return of remuneration',
        'form_label': 'E',
        'period_from': '2026-01-01',
        'period_to': '2026-12-31',
        'due_date': '2027-03-31',
        'days_left': 191,
        'is_overdue': false,
        'year_of_assessment': 2026,
      });
      expect(f.periodFrom, DateTime(2026, 1, 1));
      expect(f.periodTo, DateTime(2026, 12, 31));
    });

    test('a row with nothing in it does not throw', () {
      final f = TaxFiling.fromMap(const {});
      expect(f.filingType, '');
      expect(f.daysLeft, 0);
      expect(f.isOverdue, isFalse);
      expect(f.dueDate, isNull);
      expect(f.hasWorking, isFalse);
      // Zero days left with no date is "due today", which is wrong in
      // the noisy direction rather than the silent one — and cannot
      // arise, because the server never returns a row without a date.
      expect(f.isImminent, isTrue);
    });
  });
}
