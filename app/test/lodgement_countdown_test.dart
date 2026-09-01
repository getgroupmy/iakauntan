import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/financials/filings_screen.dart';

/// The line the filings list puts under each set of accounts.
///
/// `public.report_fs_deadlines` has existed since `0391` and nothing
/// called it. It answers the question a practice with forty companies
/// actually has — which of them is about to miss a s.258 date — and the
/// list showed the framework, the audit status and the MBRS reference,
/// and no date at all. The countdown was reachable only by opening one
/// filing at a time.
///
/// The arithmetic is not asserted here. `fs_deadlines` does it and
/// `supabase/tests/fs_statutory_order.sql` asserts it against
/// hand-worked dates, including 30 Jun 2026 -> 30 Dec 2026. What is
/// asserted here is the wording: that a filing already late is not
/// described as having days left, that a negative number never reaches
/// a screen, and that a filing with nothing to count down to says
/// nothing rather than saying it emptily.
void main() {
  test('a filing with no row has no line', () {
    expect(lodgementLine(null), isNull);
  });

  test('nor one whose row has no date to count to', () {
    expect(lodgementLine({'days_left': 12, 'is_late': false}), isNull);
  });

  test('the ordinary case counts the days', () {
    final line = lodgementLine({
      'lodge_by': '2026-12-30',
      'days_left': 120,
      'is_late': false,
    });
    expect(line, isNotNull);
    expect(line!.late, isFalse);
    expect(line.text, contains('120 days'));
    expect(line.text, startsWith('Lodge by'));
  });

  test('one day is a day, not one days', () {
    final line = lodgementLine({
      'lodge_by': '2026-12-30',
      'days_left': 1,
      'is_late': false,
    });
    expect(line!.text, endsWith('1 day'));
  });

  test('the day itself is named rather than counted as zero', () {
    final line = lodgementLine({
      'lodge_by': '2026-12-30',
      'days_left': 0,
      'is_late': false,
    });
    expect(line!.text, endsWith('today'));
    expect(line.late, isFalse);
  });

  /// The one that matters. `days_left` is `(lodge_by - today)::integer`
  /// and goes negative once the date has passed, so a template that
  /// only ever appends "$left days" prints "Lodge by 30 Dec 2026 -- -12
  /// days", which reads as a bug in the app rather than as a company in
  /// breach of s.258.
  test('a late filing is past tense, and never shows a negative count', () {
    final line = lodgementLine({
      'lodge_by': '2026-12-30',
      'days_left': -12,
      'is_late': true,
    });
    expect(line!.late, isTrue);
    expect(line.text, startsWith('Lodgement was due'));
    expect(line.text, isNot(contains('-12')));
    expect(line.text, isNot(contains('day')));
  });

  /// `is_late` is the function's own answer and is trusted over the
  /// sign of `days_left`: they are computed from the same date in the
  /// same statement, and a screen that second-guessed one with the
  /// other would disagree with the report it is displaying.
  test('lateness follows the flag the report set', () {
    final line = lodgementLine({
      'lodge_by': '2026-12-30',
      'days_left': 5,
      'is_late': true,
    });
    expect(line!.late, isTrue);
    expect(line.text, startsWith('Lodgement was due'));
  });
}
