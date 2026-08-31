import '../../data/models.dart';

/// The control account a customer's or supplier's balance sits in.
///
/// `contacts.receivable_account_id` and `payable_account_id` have been
/// columns since 0003 and `0013` reads both in four places — the
/// invoice, the bill, the receipt and the payment all fall back to
/// `1210` and `2110` only when the contact names nothing. Neither has
/// ever appeared on a screen, so every company's receivables sat in one
/// account whether or not its accounts needed them apart.
///
/// They usually do. A balance owed by a related party is disclosed
/// separately under MPERS and MFRS, and the ordinary way to get that out
/// of a ledger is a control account of its own.

/// Which accounts a receivable or payable may be pointed at.
///
/// The subtype, not the type. A receivable pointed at any asset account
/// would post a customer's balance into the bank or the stock, and the
/// aged listing reads the control account to reconcile against — so the
/// two would stop agreeing and neither would say why.
///
/// Groups are excluded because nothing posts to a group: it is a heading
/// with children, and a journal line against one is a balance that
/// appears in no leaf.
List<Account> controlAccountChoices(
  Iterable<Account> accounts, {
  required bool receivable,
}) => [
  for (final a in accounts)
    if (!a.isGroup &&
        a.isActive &&
        a.accountSubtype ==
            (receivable ? 'accounts_receivable' : 'accounts_payable'))
      a,
];

/// What the field says when nothing is chosen.
///
/// Named rather than left blank. "None" would read as "this customer has
/// no receivable", which is the opposite of what an empty column means:
/// the company's ordinary control account, which is where almost every
/// customer belongs.
const kDefaultControlAccount = 'The company’s usual one';
