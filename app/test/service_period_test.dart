import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/line_draft.dart';

/// What a service period reads as on the line it belongs to.
///
/// 0309 defers a line that carries a period: the amount is credited to
/// deferred revenue and released month by month across the period. The
/// label is how anybody without SQL sees that happening, so what it
/// claims has to be true.
///
/// The month count is the part worth asserting. "12 months" is what
/// somebody checks against the contract they signed, and a count that
/// is a day out is worse than no count at all — it reads as agreement
/// when the invoice and the contract disagree. So a month count is
/// claimed only where the period really is that many whole months, and
/// everything else falls back to days.
void main() {
  group('servicePeriodLabel', () {
    test('no period is earned on the invoice date', () {
      expect(servicePeriodLabel(null, null), 'Earned on the invoice date');
      expect(
        servicePeriodLabel(DateTime(2026, 1, 1), null),
        'Earned on the invoice date',
      );
      expect(
        servicePeriodLabel(null, DateTime(2026, 12, 31)),
        'Earned on the invoice date',
      );
    });

    test('a calendar year is twelve months', () {
      expect(
        servicePeriodLabel(DateTime(2026, 1, 1), DateTime(2026, 12, 31)),
        contains('12 months'),
      );
    });

    test('a year from mid-month is twelve months', () {
      expect(
        servicePeriodLabel(DateTime(2026, 3, 15), DateTime(2027, 3, 14)),
        contains('12 months'),
      );
    });

    test('one month is singular', () {
      expect(
        servicePeriodLabel(DateTime(2026, 2, 1), DateTime(2026, 2, 28)),
        contains('1 month'),
      );
      expect(
        servicePeriodLabel(DateTime(2026, 2, 1), DateTime(2026, 2, 28)),
        isNot(contains('1 months')),
      );
    });

    test('a leap February is still one month', () {
      expect(
        servicePeriodLabel(DateTime(2028, 2, 1), DateTime(2028, 2, 29)),
        contains('1 month'),
      );
    });

    // The whole point of the exclusive-boundary test. A year plus one
    // day is not a year, and calling it one would have the invoice
    // agree with a contract it does not match.
    test('a year and a day is counted in days', () {
      expect(
        servicePeriodLabel(DateTime(2026, 1, 1), DateTime(2027, 1, 1)),
        contains('366 days'),
      );
    });

    test('a month and a day is counted in days', () {
      expect(
        servicePeriodLabel(DateTime(2026, 2, 1), DateTime(2026, 3, 1)),
        contains('29 days'),
      );
    });

    // A period starting on a month-end, which is where month
    // arithmetic goes wrong if anybody rewrites the count. Note this
    // does not kill a mutant that drops the clamp in `_addMonths` —
    // nothing does, and `line_draft.dart` records why.
    test('month-end to a short month plus a day is counted in days', () {
      expect(
        servicePeriodLabel(DateTime(2026, 1, 31), DateTime(2026, 3, 2)),
        contains('31 days'),
      );
    });

    test('a single day is one day', () {
      expect(
        servicePeriodLabel(DateTime(2026, 6, 1), DateTime(2026, 6, 1)),
        contains('1 day'),
      );
      expect(
        servicePeriodLabel(DateTime(2026, 6, 1), DateTime(2026, 6, 1)),
        isNot(contains('1 days')),
      );
    });

    test('a short period is counted in days, inclusive of both ends', () {
      expect(
        servicePeriodLabel(DateTime(2026, 6, 1), DateTime(2026, 6, 10)),
        contains('10 days'),
      );
    });

    test('the dates themselves are shown', () {
      final label =
          servicePeriodLabel(DateTime(2026, 1, 1), DateTime(2026, 12, 31));
      expect(label, contains('01/01/2026'));
      expect(label, contains('31/12/2026'));
    });
  });

  /// The pair is the unit. `sales_document_lines` has a check
  /// constraint refusing one date without the other, and the purchase
  /// table has neither column — so a half-set period must never reach
  /// the wire, and a bill must never carry the keys at all.
  group('LineDraft.toJson', () {
    test('omits the period entirely when it is not set', () {
      final json = LineDraft(description: 'Consulting').toJson();
      expect(json.containsKey('service_start'), isFalse);
      expect(json.containsKey('service_end'), isFalse);
    });

    test('sends both dates as plain days when the period is set', () {
      final json = LineDraft(
        description: 'Annual support',
        serviceStart: DateTime(2026, 1, 1),
        serviceEnd: DateTime(2026, 12, 31),
      ).toJson();
      expect(json['service_start'], '2026-01-01');
      expect(json['service_end'], '2026-12-31');
    });

    test('omits a half-set period rather than sending one date', () {
      final json = LineDraft(
        description: 'Annual support',
        serviceStart: DateTime(2026, 1, 1),
      ).toJson();
      expect(json.containsKey('service_start'), isFalse);
      expect(json.containsKey('service_end'), isFalse);
    });
  });
}
