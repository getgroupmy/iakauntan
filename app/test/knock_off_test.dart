import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/knock_off.dart';

/// Setting what a customer has in hand against what they owe. `0630`.
///
/// The screen's whole value is the spread: a clerk ticks four invoices
/// and two credits and presses one button rather than typing eight
/// amounts. That arithmetic is what is asserted here, and three
/// properties of it are the ones that matter:
///
///   * **oldest first.** Money applied to the oldest debt is what an
///     ageing report, a statement and a customer all assume. Applying
///     it newest-first would quietly keep an invoice in the ninety-day
///     bucket while a recent one was cleared.
///   * **neither side is over-applied.** The database refuses both, and
///     doing it here means the screen can show the answer before
///     anybody presses anything.
///   * **a deposit is shown and not spent.** Applying one posts a
///     journal. Left off the screen a clerk would knock off what they
///     could see and believe the account was clear.
void main() {
  OpenItem owed(String no, double amount, String due, {double? total}) =>
      OpenItem.fromMap({
        'side': 'owes',
        'kind': 'invoice',
        'item_id': 'inv-$no',
        'doc_no': no,
        'remaining': amount,
        'total': total ?? amount,
        'currency': 'MYR',
        'allocatable': true,
        'item_date': due,
        'due_date': due,
      });

  OpenItem credit(
    String no,
    double amount, {
    String kind = 'credit_note',
    bool allocatable = true,
  }) => OpenItem.fromMap({
    'side': 'credit',
    'kind': kind,
    'item_id': 'cr-$no',
    'doc_no': no,
    'remaining': amount,
    'total': amount,
    'currency': 'MYR',
    'allocatable': allocatable,
    'item_date': '2026-03-01',
  });

  group('spreading credits over invoices', () {
    test('a credit smaller than the invoice goes entirely onto it', () {
      final lines = spreadCredits(
        invoices: [owed('A', 1000, '2026-01-31')],
        credits: [credit('C1', 300)],
      );
      expect(lines.length, 1);
      expect(lines.single.amount, 300);
      expect(lines.single.invoiceId, 'inv-A');
      expect(lines.single.kind, 'credit_note');
    });

    test('a credit larger than the invoice spills onto the next', () {
      final lines = spreadCredits(
        invoices: [owed('A', 400, '2026-01-31'), owed('B', 900, '2026-02-28')],
        credits: [credit('C1', 1000)],
      );
      expect(lines.map((l) => l.amount), [400, 600]);
      expect(lines.map((l) => l.invoiceId), ['inv-A', 'inv-B']);
    });

    test('and stops when it is spent, leaving the rest outstanding', () {
      final lines = spreadCredits(
        invoices: [owed('A', 400, '2026-01-31'), owed('B', 900, '2026-02-28')],
        credits: [credit('C1', 500)],
      );
      expect(lines.map((l) => l.amount), [400, 100]);
      expect(lines.fold<double>(0, (s, l) => s + l.amount), 500);
    });

    // The property the ageing report and the customer both assume.
    test('the oldest invoice is settled first, whatever order they came in', () {
      final lines = spreadCredits(
        invoices: [
          owed('NEW', 500, '2026-03-31'),
          owed('OLD', 500, '2026-01-31'),
          owed('MID', 500, '2026-02-28'),
        ],
        credits: [credit('C1', 700)],
      );
      expect(lines.first.invoiceId, 'inv-OLD');
      expect(lines.first.amount, 500);
      expect(lines.last.invoiceId, 'inv-MID');
      expect(lines.last.amount, 200);
      // And the newest is untouched.
      expect(lines.any((l) => l.invoiceId == 'inv-NEW'), isFalse);
    });

    test('two credits are both spent before anything is left over', () {
      final lines = spreadCredits(
        invoices: [owed('A', 1000, '2026-01-31')],
        credits: [credit('C1', 300), credit('C2', 400, kind: 'receipt')],
      );
      expect(lines.length, 2);
      expect(lines.fold<double>(0, (s, l) => s + l.amount), 700);
      // The kind travels with each line, because the server dispatches
      // on it — a receipt and a credit note go through different
      // allocators.
      expect(lines.map((l) => l.kind), ['credit_note', 'receipt']);
    });

    // A line worth nothing is a line the server refuses — "An
    // allocation is of something" — so one reaching it would fail the
    // whole batch over a row nobody ticked. It takes a second credit
    // AND an invoice the first one covered exactly for the case to
    // arise at all, which is why it was not covered until the mutation
    // sweep asked.
    test('an invoice the last credit covered exactly gets no empty line', () {
      final lines = spreadCredits(
        invoices: [owed('A', 300, '2026-01-31'), owed('B', 500, '2026-02-28')],
        credits: [credit('C1', 300), credit('C2', 200)],
      );
      expect(lines.length, 2);
      expect(lines.every((l) => l.amount > 0), isTrue);
      expect(lines.map((l) => l.invoiceId), ['inv-A', 'inv-B']);
      expect(lines.map((l) => l.amount), [300, 200]);
    });

    test('nothing is over-applied on either side', () {
      final lines = spreadCredits(
        invoices: [owed('A', 100, '2026-01-31')],
        credits: [credit('C1', 500), credit('C2', 500)],
      );
      expect(lines.fold<double>(0, (s, l) => s + l.amount), 100);
      expect(lines.length, 1);
    });

    test('a credit that cannot be applied here is skipped', () {
      final lines = spreadCredits(
        invoices: [owed('A', 1000, '2026-01-31')],
        credits: [
          credit('D1', 700, kind: 'deposit', allocatable: false),
          credit('C1', 200),
        ],
      );
      expect(lines.length, 1);
      expect(lines.single.sourceId, 'cr-C1');
    });

    test('sen do not go missing down the chain', () {
      final lines = spreadCredits(
        invoices: [
          owed('A', 33.33, '2026-01-31'),
          owed('B', 33.33, '2026-02-28'),
          owed('C', 33.34, '2026-03-31'),
        ],
        credits: [credit('C1', 100)],
      );
      expect(lines.fold<double>(0, (s, l) => s + l.amount), closeTo(100, 0.001));
    });

    test('nothing ticked spreads nothing', () {
      expect(spreadCredits(invoices: const [], credits: const []), isEmpty);
      expect(
        spreadCredits(invoices: [owed('A', 100, '2026-01-31')], credits: const []),
        isEmpty,
      );
    });
  });

  group('what the screen says before anybody presses anything', () {
    test('the summary names the money and both counts', () {
      final lines = spreadCredits(
        invoices: [owed('A', 400, '2026-01-31'), owed('B', 900, '2026-02-28')],
        credits: [credit('C1', 500), credit('C2', 200, kind: 'receipt')],
      );
      final s = knockOffSummary(lines, currency: 'MYR');
      expect(s, contains('700.00'));
      expect(s, contains('2 credits'));
      expect(s, contains('2 invoices'));
    });

    test('and says so plainly when nothing is ticked', () {
      expect(
        knockOffSummary(const [], currency: 'MYR'),
        contains('Tick something'),
      );
    });

    test('one of each reads as one, not as 1 invoices', () {
      final lines = spreadCredits(
        invoices: [owed('A', 400, '2026-01-31')],
        credits: [credit('C1', 100)],
      );
      final s = knockOffSummary(lines, currency: 'MYR');
      expect(s, contains('1 credit '));
      expect(s, contains('1 invoice.'));
    });

    test('the remainder is what is left, not what was applied', () {
      final invoices = [owed('A', 400, '2026-01-31')];
      final lines = spreadCredits(invoices: invoices, credits: [credit('C1', 100)]);
      expect(
        knockOffRemainder(invoices: invoices, lines: lines, currency: 'MYR'),
        contains('300.00'),
      );
    });

    test('and says nothing is left when nothing is', () {
      final invoices = [owed('A', 400, '2026-01-31')];
      final lines = spreadCredits(invoices: invoices, credits: [credit('C1', 400)]);
      expect(
        knockOffRemainder(invoices: invoices, lines: lines, currency: 'MYR'),
        contains('Nothing left outstanding'),
      );
    });
  });

  group('what it refuses, in the order the screen reads', () {
    test('the left column first', () {
      expect(
        knockOffProblem(invoices: const [], credits: [credit('C1', 100)], lines: const []),
        contains('at least one invoice'),
      );
    });

    test('then the right', () {
      expect(
        knockOffProblem(
          invoices: [owed('A', 100, '2026-01-31')],
          credits: const [],
          lines: const [],
        ),
        contains('credit note or receipt'),
      );
    });

    test('a column of things that cannot be applied says which and why', () {
      final credits = [credit('D1', 700, kind: 'deposit', allocatable: false)];
      expect(
        knockOffProblem(
          invoices: [owed('A', 100, '2026-01-31')],
          credits: credits,
          lines: const [],
        ),
        contains('deposit is applied from the deposit itself'),
      );
    });

    test('and both sides ticked with value on them is no problem at all', () {
      final invoices = [owed('A', 100, '2026-01-31')];
      final credits = [credit('C1', 50)];
      expect(
        knockOffProblem(
          invoices: invoices,
          credits: credits,
          lines: spreadCredits(invoices: invoices, credits: credits),
        ),
        isNull,
      );
    });
  });

  group('the rows themselves', () {
    test('a locked row says what to do instead, not "not allocatable"', () {
      final d = credit('D1', 700, kind: 'deposit', allocatable: false);
      expect(openItemLocked(d), contains('posts a journal'));
      expect(openItemLocked(d), isNot(contains('allocatable')));
      expect(openItemLocked(credit('C1', 100)), isNull);
    });

    test('every kind has a name a person can read', () {
      for (final k in const [
        'invoice',
        'debit_note',
        'credit_note',
        'receipt',
        'deposit',
      ]) {
        expect(openItemKind(k), isNot(contains('_')));
      }
      // "On account" rather than "Receipt": what is in hand is the
      // unapplied part, not the receipt.
      expect(openItemKind('receipt'), 'On account');
    });

    test('partly settled is only said when it is true', () {
      expect(owed('A', 400, '2026-01-31', total: 1000).partly, isTrue);
      expect(owed('A', 400, '2026-01-31').partly, isFalse);
    });
  });
}
