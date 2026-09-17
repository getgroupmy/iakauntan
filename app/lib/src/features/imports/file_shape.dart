/// Which importer a file is actually for.
///
/// The report that produced this: a chart of accounts exported from
/// this product, uploaded under **Contacts**, previewed clean and
/// offered to import. It would have created eighty-eight customers
/// called "ASSETS", "Cash in Hand" and "Accumulated Depreciation",
/// because the contacts importer needs only a `name` and a chart has
/// one in every row.
///
/// Nothing was wrong with either importer. `parseCsvTable` maps the
/// headings an importer knows and drops the rest, by design — a file
/// from another system carries columns this one has no use for, and
/// refusing over a spare column would be a reason to give up on the
/// import. But dropping them also throws away the evidence that the
/// file was for somewhere else entirely, and by the time the rows reach
/// the database there is nothing left to notice: the server is handed
/// two good columns and cannot know about the five it never saw.
///
/// So the noticing has to happen here, at the only point where the
/// original headings still exist.
///
/// ## How a file is identified
///
/// By the columns only one importer reads. `account_subtype` belongs to
/// the chart and nothing else; `credit_limit` to contacts;
/// `outstanding_amount` to the open items. `code` and `name` belong to
/// everybody and prove nothing, which is exactly why the contacts
/// importer accepted a chart.
library;

import '../../core/csv.dart';
import 'import_screen.dart';

/// The vocabulary of every importer, in one place.
///
/// Built from the same maps the importers themselves use, so a column
/// added to one is a column this recognises — there is no second list
/// to keep in step.
Map<String, List<String>> importColumnsFor(ImportKind kind) => switch (kind) {
  ImportKind.contacts => contactColumns,
  ImportKind.items => itemColumns,
  ImportKind.accounts => accountColumns,
  ImportKind.openInvoices => openInvoiceColumns,
  ImportKind.openBills => openBillColumns,
  ImportKind.openingBalances => openingBalanceColumns,
  ImportKind.openingStock => openingStockColumns,
  ImportKind.salesTransactions => salesTransactionColumns,
};

/// Which of [headers] an importer understands.
Set<String> _recognised(ImportKind kind, List<String> headers) {
  final map = headerMapper(importColumnsFor(kind));
  return {
    for (final h in headers)
      if (map(h) != null) h,
  };
}

/// What a file looks like, and to whom.
class FileShape {
  const FileShape({required this.selected, required this.recognised});

  final ImportKind selected;

  /// Headings each importer understands.
  final Map<ImportKind, Set<String>> recognised;

  Set<String> get _mine => recognised[selected] ?? const {};

  /// The importer the file is more likely for, or null.
  ///
  /// The test is a strict superset: another importer explains
  /// everything this one does AND something more. That is the shape of
  /// the mistake this exists to catch -- a chart under Contacts, where
  /// `code` and `name` are read by both and five more columns are read
  /// by only one of them.
  ///
  /// Deliberately not "has a column nobody else reads". Open invoices
  /// and open bills share almost their whole vocabulary, so neither
  /// has a column exclusive to it and a file of invoices dropped on
  /// the opening-balances tab would have gone unremarked.
  ImportKind? get looksLike {
    ImportKind? best;
    for (final kind in ImportKind.values) {
      if (kind == selected) continue;
      final theirs = recognised[kind]!;
      if (theirs.length <= _mine.length) continue;
      if (!theirs.containsAll(_mine)) continue;
      if (best == null || theirs.length > recognised[best]!.length) {
        best = kind;
      }
    }
    return best;
  }

  /// The columns that say so: read by [looksLike] and not by the
  /// importer selected.
  Set<String> get evidence {
    final other = looksLike;
    if (other == null) return const {};
    return recognised[other]!.difference(_mine);
  }
}

/// Works out what the file in front of the screen is.
FileShape identifyFile({
  required ImportKind selected,
  required List<String> headers,
}) => FileShape(
  selected: selected,
  recognised: {
    for (final kind in ImportKind.values) kind: _recognised(kind, headers),
  },
);

/// The sentence shown when a file belongs somewhere else.
///
/// Null when the file is where it should be, which is the caller's cue
/// to draw nothing at all rather than a reassuring green tick — most
/// files are fine and a screen that congratulates you on every one of
/// them is a screen nobody reads.
///
/// Names the columns. "This looks wrong" is an opinion; "account_type,
/// account_subtype and is_group are columns only the chart of accounts
/// importer reads" is a fact somebody can check in the file they are
/// holding.
String? fileShapeWarning(FileShape shape) {
  final other = shape.looksLike;
  if (other == null) return null;
  final proof = shape.evidence.toList()..sort();
  return 'This looks like a file for ${importKindLabel(other)}, '
      'not ${importKindLabel(shape.selected)}. '
      '${_list(proof)} ${proof.length == 1 ? 'is a column' : 'are columns'} '
      'that importer reads and this one does not.';
}

/// Whether the mismatch is decisive enough to stop the import.
///
/// It is decisive whenever another importer explains everything this
/// one does and more, because then this importer knows nothing about
/// the file that the other does not — there is nothing to weigh.
/// Importing it here would build rows out of headings that mean
/// something else: the eighty-eight customers named after balance
/// sheet headings that started this.
///
/// A file each importer reads something of, and neither reads all of,
/// is ambiguous. `looksLike` returns null for those, and ambiguity is
/// the person's to resolve rather than the screen's.
bool fileShapeBlocks(FileShape shape) => shape.looksLike != null;

/// What the columns nobody reads should say.
///
/// Not a warning. A chart exported from this product carries
/// `is_active` and `current_balance`, which the importer does not read
/// — imported accounts are active and their balances come from the
/// ledger. Saying so is the difference between a column being ignored
/// and a column being ignored silently.
String? ignoredColumnsNote(ImportKind kind, List<String> headers) {
  final known = _recognised(kind, headers);
  final ignored = [
    for (final h in headers)
      if (!known.contains(h) && h.trim().isNotEmpty) h,
  ];
  if (ignored.isEmpty) return null;
  return '${_list(ignored)} ${ignored.length == 1 ? 'is' : 'are'} not read '
      'by this importer and will be left out.';
}

String _list(List<String> items) {
  if (items.length == 1) return '“${items.single}”';
  final quoted = [for (final i in items) '“$i”'];
  return '${quoted.sublist(0, quoted.length - 1).join(', ')} and '
      '${quoted.last}';
}
