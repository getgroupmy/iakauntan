/// The other statement: what happened, not what is unpaid.
///
/// `0624` built `report_statement_of_account` and nothing in the app
/// ever called it. The OCA audit's B5 says why it matters: the
/// open-item statement in `statement_pdf.dart` lists every document
/// with a balance left on it, which answers the credit controller's
/// question. The customer's question is different —
///
///   "What do I owe you, and how did it get to that?"
///
/// — and a brought-forward statement is the answer: an opening balance,
/// every document and every receipt that moved it in date order, a
/// running balance down the page, and a closing balance.
///
/// The two are not substitutes and this file does not replace the other
/// one. A customer reconciling against their own ledger needs THIS one;
/// somebody chasing what is overdue needs the other.
///
/// Customer side only, because the function is: it reads
/// `sales_documents` and `receipts`. A supplier statement of this shape
/// would need the purchase halves and is not pretended at here.
library;

import '../../core/format.dart';

/// One line of the statement, as `report_statement_of_account` returns
/// it.
///
/// [lineNo] 0 is the opening balance and carries no movement — the
/// function emits it as its own row so the running balance has
/// something to run from. Everything above 0 is a document or a
/// receipt.
class StatementLine {
  const StatementLine({
    required this.lineNo,
    required this.entryDate,
    required this.kind,
    required this.docNo,
    required this.dueDate,
    required this.currency,
    required this.debit,
    required this.credit,
    required this.baseDebit,
    required this.baseCredit,
    required this.balance,
  });

  final int lineNo;
  final DateTime? entryDate;

  /// `opening`, or a sales document type, or `receipt`.
  final String kind;
  final String? docNo;
  final DateTime? dueDate;
  final String? currency;

  /// What the document was worth in ITS OWN currency, which is what the
  /// customer was billed and what they will look for.
  final double debit;
  final double credit;

  /// And in the company's currency, which is what the running balance
  /// is kept in. Adding a USD invoice to a ringgit balance is the
  /// arithmetic these two fields exist to keep apart.
  final double baseDebit;
  final double baseCredit;
  final double balance;

  bool get isOpening => lineNo == 0;

  factory StatementLine.fromJson(Map<String, dynamic> j) => StatementLine(
    lineNo: (j['line_no'] as num?)?.toInt() ?? 0,
    entryDate: Fmt.parseDate(j['entry_date']),
    kind: j['kind']?.toString() ?? '',
    docNo: j['doc_no']?.toString(),
    dueDate: Fmt.parseDate(j['due_date']),
    currency: j['currency']?.toString().trim(),
    debit: Fmt.toDouble(j['debit']),
    credit: Fmt.toDouble(j['credit']),
    baseDebit: Fmt.toDouble(j['base_debit']),
    baseCredit: Fmt.toDouble(j['base_credit']),
    balance: Fmt.toDouble(j['balance']),
  );
}

/// What was owed before the period began.
double statementOpening(List<StatementLine> lines) {
  for (final l in lines) {
    if (l.isOpening) return l.balance;
  }
  return 0;
}

/// And what is owed at the end of it.
///
/// The LAST line's running balance, not a sum computed here. The
/// function already carries the answer down the page and a second
/// arithmetic would be a second thing to disagree — which is the whole
/// failure `statement_of_account.sql` was written to prevent between
/// this report and the ageing one.
double statementClosing(List<StatementLine> lines) =>
    lines.isEmpty ? 0 : lines.last.balance;

/// Everything that moved it, without the opening line.
List<StatementLine> statementMovements(List<StatementLine> lines) =>
    [for (final l in lines) if (!l.isOpening) l];

/// Whether the running balance agrees with the movements under it.
///
/// The one property a brought-forward statement has to have, and the
/// one a customer checks by hand: opening, plus everything that
/// happened, is closing. A statement where those disagree is a demand
/// for a number nothing on the page explains, and the customer's next
/// move is a telephone call rather than a payment.
///
/// Rounded to the cent before comparing, because the figures arrive
/// rounded and a floating-point sum of them will not land exactly.
bool statementAddsUp(List<StatementLine> lines) {
  if (lines.isEmpty) return true;
  var running = statementOpening(lines);
  for (final l in statementMovements(lines)) {
    running += l.baseDebit - l.baseCredit;
  }
  return (running - statementClosing(lines)).abs() < 0.005;
}

/// What to call each line on the page.
///
/// A customer does not know what a `debit_note` is, and `refund_note`
/// reads as something they are owed rather than something that reduces
/// what they owe. The words are the ones on the documents they were
/// sent.
String statementKindLabel(String kind) => switch (kind) {
  'opening' => 'Balance brought forward',
  'invoice' => 'Invoice',
  'credit_note' => 'Credit note',
  'debit_note' => 'Debit note',
  'refund_note' => 'Refund',
  'receipt' => 'Payment received',
  _ => kind.replaceAll('_', ' '),
};

/// The period a statement covers, said the way a person would.
String statementPeriodLabel(DateTime from, DateTime to) =>
    '${Fmt.date(from)} to ${Fmt.date(to)}';

/// The period to offer before anybody chooses one.
///
/// The current month, which is what `report_statement_of_account`
/// itself defaults to when given no dates. Said here as well rather
/// than left to the function, because the PDF prints the period on its
/// face and a document whose heading disagrees with its contents is
/// worse than one with no heading.
({DateTime from, DateTime to}) statementDefaultPeriod(DateTime today) => (
  from: DateTime(today.year, today.month, 1),
  to: DateTime(today.year, today.month, today.day),
);
