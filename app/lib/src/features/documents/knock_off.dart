import '../../core/format.dart';

/// Setting what a customer has in hand against what they owe.
///
/// `0630`. The arithmetic and the sentences live here rather than in the
/// screen, for the reason the rest of this directory keeps its own: a
/// month-end screen that allocates six credits across nine invoices is
/// doing arithmetic somebody has to be able to check, and arithmetic
/// inside a `build` method is arithmetic nobody can assert.

/// One row of `open_items` — either something owed or something in hand.
class OpenItem {
  const OpenItem({
    required this.side,
    required this.kind,
    required this.id,
    required this.docNo,
    required this.remaining,
    required this.total,
    required this.currency,
    required this.allocatable,
    this.date,
    this.dueDate,
  });

  factory OpenItem.fromMap(Map<String, dynamic> m) => OpenItem(
    side: m['side']?.toString() ?? '',
    kind: m['kind']?.toString() ?? '',
    id: m['item_id']?.toString() ?? '',
    docNo: m['doc_no']?.toString() ?? '',
    remaining: Fmt.toDouble(m['remaining']),
    total: Fmt.toDouble(m['total']),
    currency: m['currency']?.toString() ?? 'MYR',
    allocatable: m['allocatable'] != false,
    date: Fmt.parseDate(m['item_date']),
    dueDate: Fmt.parseDate(m['due_date']),
  );

  final String side;
  final String kind;
  final String id;
  final String docNo;
  final double remaining;
  final double total;
  final String currency;
  final bool allocatable;
  final DateTime? date;
  final DateTime? dueDate;

  bool get owed => side == 'owes';

  /// Part of it has already been settled, which is the only case in
  /// which showing the original as well as what is left helps.
  bool get partly => (total - remaining).abs() >= 0.005;
}

/// What to call each kind on screen.
String openItemKind(String kind) => switch (kind) {
  'invoice' => 'Invoice',
  'debit_note' => 'Debit note',
  'credit_note' => 'Credit note',
  'receipt' => 'On account',
  'deposit' => 'Deposit',
  _ => kind,
};

/// Why a row cannot be ticked, or null when it can.
///
/// Said in the words of what to do instead. "Not allocatable" is true
/// and is not an instruction, and somebody looking at money their
/// customer has paid needs to be told where to go and spend it.
String? openItemLocked(OpenItem item) {
  if (item.allocatable) return null;
  return switch (item.kind) {
    'deposit' =>
      'Applying a deposit posts a journal, so it is done from the '
          'deposit itself.',
    _ => 'This one is applied from its own screen.',
  };
}

/// One line of a knock-off: this much of this credit against this
/// invoice.
class KnockOffLine {
  const KnockOffLine({
    required this.kind,
    required this.sourceId,
    required this.invoiceId,
    required this.amount,
  });

  final String kind;
  final String sourceId;
  final String invoiceId;
  final double amount;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'source_id': sourceId,
    'invoice_id': invoiceId,
    'amount': amount,
  };
}

/// Spreads the ticked credits over the ticked invoices, oldest first.
///
/// The whole of the convenience, and the reason a knock-off screen is
/// worth having at all: a clerk ticks four invoices and two credits and
/// presses one button, rather than typing eight amounts.
///
/// Oldest invoice first, deliberately. Money applied to the oldest debt
/// is what an ageing report, a statement and a customer all assume, and
/// applying it to the newest would quietly keep an invoice in the
/// ninety-day bucket while a recent one was cleared.
///
/// It never over-applies either side: each credit stops when it is
/// spent and each invoice stops when it is covered, which is what the
/// database would refuse anyway. Doing it here means the screen can show
/// the answer before anybody presses anything.
List<KnockOffLine> spreadCredits({
  required List<OpenItem> invoices,
  required List<OpenItem> credits,
}) {
  final lines = <KnockOffLine>[];
  final owing = {
    for (final i in invoices) i.id: _round(i.remaining),
  };

  final ordered = [...invoices]..sort((a, b) {
    final ad = a.dueDate ?? a.date;
    final bd = b.dueDate ?? b.date;
    if (ad == null || bd == null) return a.docNo.compareTo(b.docNo);
    final byDate = ad.compareTo(bd);
    // Ties broken by number so the answer does not change between two
    // presses of the same button.
    return byDate != 0 ? byDate : a.docNo.compareTo(b.docNo);
  });

  for (final credit in credits) {
    if (!credit.allocatable) continue;
    var left = _round(credit.remaining);
    for (final invoice in ordered) {
      final due = owing[invoice.id] ?? 0;
      // One guard, not three. This was written with `left <= 0` and
      // `due <= 0` as well, and the mutation sweep showed that removing
      // any ONE of the three changed nothing observable — each covered
      // for the others, so none of them was tested and the code read as
      // if all three were load-bearing. What actually has to hold is
      // that no line is worth nothing: the server refuses one ("An
      // allocation is of something") and it would fail the whole batch
      // over a row nobody ticked.
      final take = _round(left < due ? left : due);
      if (take <= 0) continue;
      lines.add(KnockOffLine(
        kind: credit.kind,
        sourceId: credit.id,
        invoiceId: invoice.id,
        amount: take,
      ));
      owing[invoice.id] = _round(due - take);
      left = _round(left - take);
    }
  }
  return lines;
}

double _round(double v) => (v * 100).round() / 100;

/// What the button is about to do, in one sentence.
///
/// The TOTAL and both counts, because "apply" on its own does not say
/// how much of somebody's money is about to move.
String knockOffSummary(List<KnockOffLine> lines, {required String currency}) {
  if (lines.isEmpty) {
    return 'Tick something owed and something in hand.';
  }
  final total = lines.fold<double>(0, (sum, l) => sum + l.amount);
  final invoices = {for (final l in lines) l.invoiceId}.length;
  final sources = {for (final l in lines) l.sourceId}.length;
  return '${Fmt.money(total, currency: currency)} from '
      '${_count(sources, 'credit', 'credits')} against '
      '${_count(invoices, 'invoice', 'invoices')}.';
}

/// What will still be outstanding afterwards, so nobody has to work it
/// out from two columns.
String knockOffRemainder({
  required List<OpenItem> invoices,
  required List<KnockOffLine> lines,
  required String currency,
}) {
  final owed = invoices.fold<double>(0, (sum, i) => sum + i.remaining);
  final applied = lines.fold<double>(0, (sum, l) => sum + l.amount);
  final left = _round(owed - applied);
  if (left <= 0) {
    return 'Nothing left outstanding on what is ticked.';
  }
  return '${Fmt.money(left, currency: currency)} still outstanding on what '
      'is ticked.';
}

String _count(int n, String one, String many) =>
    n == 1 ? '1 $one' : '$n $many';

/// Why the batch cannot be sent, or null.
///
/// Reported in the order the screen reads: what is owed is the left
/// column and what is in hand is the right, so somebody is never told
/// about the column they have not looked at yet.
String? knockOffProblem({
  required List<OpenItem> invoices,
  required List<OpenItem> credits,
  required List<KnockOffLine> lines,
}) {
  if (invoices.isEmpty) return 'Tick at least one invoice to settle.';
  if (credits.isEmpty) {
    return 'Tick at least one credit note or receipt to settle it with.';
  }
  if (credits.every((c) => !c.allocatable)) {
    return 'Nothing ticked can be applied here. A deposit is applied '
        'from the deposit itself.';
  }
  if (lines.isEmpty) {
    return 'Nothing to apply — what is ticked has no value left on it.';
  }
  return null;
}
