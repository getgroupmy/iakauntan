import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/fiscal_close.dart';

/// The two rules about the order of a year-end close.
///
/// `0648` enforces both in the database and says why in a sentence.
/// These are the same two answers on the BUTTON, so somebody learns
/// before pressing rather than after — the argument `voidBlockedBecause`
/// and `transferBlockedBecause` already make.
///
/// Both rules are about order and neither can be answered from one year
/// alone, which is the whole reason these take the list. A version that
/// looked only at the year in hand would offer Close on every one of
/// them and let the database refuse — and the refusal is a snackbar, on
/// a screen where the next thing somebody does is press the button
/// again.
void main() {
  FiscalYear year(String name, int startYear, {String status = 'open'}) =>
      FiscalYear(
        id: 'fy-$startYear',
        name: name,
        startDate: DateTime(startYear, 1, 1),
        endDate: DateTime(startYear, 12, 31),
        status: status,
      );

  group('closing', () {
    test('the earliest open year may be closed', () {
      final y25 = year('FY2025', 2025);
      final y26 = year('FY2026', 2026);
      expect(closeBlockedBecause(y25, [y25, y26]), isNull);
    });

    test('but not one with an earlier year still open', () {
      // The failure this prevents: an earlier year still open holds its
      // own result in the profit and loss accounts, so closing a later
      // one sweeps two years of trading into one year's result -- and
      // the entry balances, so nothing downstream reports it.
      final y25 = year('FY2025', 2025);
      final y26 = year('FY2026', 2026);
      final why = closeBlockedBecause(y26, [y25, y26]);
      expect(why, isNotNull);
      expect(why, contains('FY2025'));
    });

    test('and an earlier year already closed is no obstacle', () {
      final y25 = year('FY2025', 2025, status: 'closed');
      final y26 = year('FY2026', 2026);
      expect(closeBlockedBecause(y26, [y25, y26]), isNull);
    });

    test('a year that is already closed is not offered a close', () {
      final y25 = year('FY2025', 2025, status: 'closed');
      expect(closeBlockedBecause(y25, [y25]), isNull);
    });

    test('and says so even where the order would otherwise refuse', () {
      // The assertion a mutation sweep asked for. The test above holds
      // a closed year with nothing earlier, so removing the status
      // check entirely still returned null and survived. The pair that
      // separates them is a CLOSED year with an EARLIER OPEN one: this
      // function answers about closing, and a year that is already
      // closed is not being closed, whatever the order says.
      //
      // Equivalent at today's only call site -- the button asks
      // `reopenBlockedBecause` for a closed year -- and not equivalent
      // in the function, which is where the rule lives.
      final y24 = year('FY2024', 2024);
      final y25 = year('FY2025', 2025, status: 'closed');
      expect(closeBlockedBecause(y25, [y24, y25]), isNull);
    });

    test('and every earlier open year is named, not just the first', () {
      // "Close FY2024 first" on a company three years behind sends
      // somebody back four times to find out how far back it goes.
      final y24 = year('FY2024', 2024);
      final y25 = year('FY2025', 2025);
      final y26 = year('FY2026', 2026);
      final why = closeBlockedBecause(y26, [y24, y25, y26]);
      expect(why, contains('FY2024'));
      expect(why, contains('FY2025'));
    });
  });

  group('reopening', () {
    test('the latest closed year may be reopened', () {
      final y25 = year('FY2025', 2025, status: 'closed');
      final y26 = year('FY2026', 2026);
      expect(reopenBlockedBecause(y25, [y25, y26]), isNull);
    });

    test('but not one with a later year still closed', () {
      // The same rule read backwards: the later year's result was
      // worked out from a profit and loss that this reopening puts
      // figures back into.
      final y25 = year('FY2025', 2025, status: 'closed');
      final y26 = year('FY2026', 2026, status: 'closed');
      final why = reopenBlockedBecause(y25, [y25, y26]);
      expect(why, isNotNull);
      expect(why, contains('FY2026'));
    });

    test('and an open year is not offered a reopen', () {
      final y25 = year('FY2025', 2025);
      expect(reopenBlockedBecause(y25, [y25]), isNull);
    });
  });

  test('the confirmation says where the money goes and that it undoes', () {
    // "Close the year" means nothing to somebody who has not done one.
    // What they are agreeing to is the sweep into equity, and the thing
    // worth knowing before pressing is that it is reversible.
    expect(closeYearMessage, contains('3300'));
    expect(closeYearMessage, contains('reopen'));
    // And the order of operations, which is the one that bites: the
    // journal posts into the year's own periods, so they have to be
    // open when it does.
    expect(closeYearMessage, contains('lock'));
  });
}
