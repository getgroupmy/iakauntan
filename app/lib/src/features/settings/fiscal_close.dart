/// Closing a financial year, and the two rules about the order.
///
/// `0648` brings every revenue and expense account to nil at the year
/// end and puts the result in `3300 Current Year Earnings`. Four parts
/// of the schema had been built for that close and none of them had
/// ever been used: the `year_end_close` member of `app.journal_source`,
/// the `closed_at`/`closed_by` columns on `fiscal_years`, the seeded
/// `3300` account, and `report_cash_flow`'s exclusion of exactly that
/// journal source.
///
/// The database enforces both rules below and says so in a sentence.
/// These exist so the BUTTON says so first — the same argument
/// `voidBlockedBecause` and `transferBlockedBecause` make, and the one
/// the document editor already makes about Post: being told after
/// pressing is a worse way to learn than being told on the control.
library;

import '../../data/models.dart';

/// Why this year cannot be closed yet, or null when it can.
///
/// One rule, and it is about ORDER. An earlier year still open holds
/// its own result in the profit and loss accounts, so closing this one
/// would sweep two years of trading into one year's result — and the
/// entry would balance, so nothing downstream would report it.
String? closeBlockedBecause(FiscalYear year, List<FiscalYear> all) {
  if (year.status != 'open') return null;
  final earlier = all
      .where((y) => y.status == 'open' && y.startDate.isBefore(year.startDate))
      .map((y) => y.name)
      .toList();
  if (earlier.isEmpty) return null;
  return 'Close ${earlier.join(', ')} first';
}

/// And why it cannot be reopened, or null when it can.
///
/// The same rule read backwards: a later year was closed on the
/// strength of this one being shut, so its result was worked out from a
/// profit and loss that this reopening puts figures back into.
String? reopenBlockedBecause(FiscalYear year, List<FiscalYear> all) {
  if (year.status != 'closed') return null;
  final later = all
      .where((y) => y.status == 'closed' && y.startDate.isAfter(year.startDate))
      .map((y) => y.name)
      .toList();
  if (later.isEmpty) return null;
  return 'Reopen ${later.join(', ')} first';
}

/// What the confirmation says before a year is shut.
///
/// Deliberately names where the money goes. "Close the year" means
/// nothing to somebody who has not done one; "every revenue and expense
/// account is brought to nil and the result moves into equity" is the
/// thing they are agreeing to, and it is reversible, which is the other
/// thing worth knowing before pressing.
const closeYearMessage =
    'Every revenue and expense account is brought to nil at the year end '
    'and the result moves into 3300 Current Year Earnings. The periods '
    'have to be open for the journal to post, so close the year before '
    'locking them. You can reopen it, which reverses the journal rather '
    'than deleting it.';
