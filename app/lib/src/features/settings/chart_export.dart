/// The chart of accounts, as a file.
///
/// A chart leaves this product for three reasons and they want the same
/// file: an accountant who works in a spreadsheet, an auditor who asked
/// for the mapping, and somebody setting up a second company who would
/// otherwise type two hundred accounts again.
///
/// The columns are exactly the ones `import_accounts` reads (0550), in
/// the order it documents them, so a chart exported here goes back into
/// another company on this platform without a single heading being
/// renamed. That is the whole design constraint and it is worth
/// stating: an export whose columns do not match the importer's is a
/// backup nobody can restore.
library;

import '../../data/models.dart';

/// One CSV field, quoted only when it has to be.
///
/// Account names carry commas ("Rent, rates and insurance") and the
/// occasional quotation mark. RFC 4180 doubles an embedded quote; a
/// field that merely contains a comma needs wrapping and nothing else.
String csvField(String? value) {
  final v = value ?? '';
  if (!v.contains(',') && !v.contains('"') && !v.contains('\n')) return v;
  return '"${v.replaceAll('"', '""')}"';
}

/// The header row, and the order every row follows.
const chartExportColumns = [
  'code',
  'name',
  'account_type',
  'account_subtype',
  'is_group',
  'is_active',
  'current_balance',
];

/// The whole chart as CSV.
///
/// Sorted by code, which is the order a chart is read in and the order
/// that puts a heading immediately before the accounts under it — so
/// the file can be handed straight back to the importer, which requires
/// a parent to come before its children.
///
/// `parent_code` is not a column, and that is a limitation rather than
/// an oversight: [Account] does not carry the parent, and inventing one
/// by guessing at code prefixes would produce a file that imports into
/// a different shape than it left. The importer treats a missing
/// parent as "no parent", so a re-import is flat until the model
/// carries it.
String chartOfAccountsCsv(List<Account> accounts) {
  final rows = [...accounts]..sort((a, b) => a.code.compareTo(b.code));
  final buffer = StringBuffer()..writeln(chartExportColumns.join(','));
  for (final a in rows) {
    buffer.writeln([
      csvField(a.code),
      csvField(a.name),
      csvField(a.accountType),
      csvField(a.accountSubtype),
      a.isGroup ? 'true' : 'false',
      a.isActive ? 'true' : 'false',
      a.currentBalance.toStringAsFixed(2),
    ].join(','));
  }
  return buffer.toString();
}

/// What the file is called. The company and the day, because a chart
/// exported twice a year is two files in the same downloads folder.
String chartExportFilename(String? companyName, DateTime on) {
  final stem = (companyName ?? 'chart')
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final day = '${on.year.toString().padLeft(4, '0')}-'
      '${on.month.toString().padLeft(2, '0')}-'
      '${on.day.toString().padLeft(2, '0')}';
  return '${stem.isEmpty ? 'chart' : stem}-chart-of-accounts-$day.csv';
}
