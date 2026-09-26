import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/csv.dart';
import '../../core/download.dart';
import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'file_shape.dart';
import 'import_file.dart';
import 'import_template.dart';

/// Bringing a company's books across from whatever was in use before.
///
/// The preview is not a courtesy. Nothing is written unless every row is
/// good, so a file with one bad line imports nothing at all — and the
/// only humane way to run something with that rule is to be able to see
/// what it will say first. Both buttons call the same database function;
/// the preview one just tells it not to write.
///
/// The master files and the open items are on the same screen because
/// they are one job done in an order: the invoices name customers by
/// code, so the customer list has to be here first, and the screen says
/// so when a code does not resolve.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

/// What each importer accepts, and the column headings it answers to.
///
/// A file exported from another system has its own names for things, so
/// the common ones are listed rather than making somebody rename
/// columns before they can start.
const contactColumns = <String, List<String>>{
  'code': ['customer code', 'supplier code', 'account code', 'no', 'id'],
  'name': ['customer name', 'supplier name', 'company', 'company name'],
  'contact_type': ['type', 'kind'],
  'legal_name': ['registered name'],
  'tin': ['tax identification number', 'lhdn tin'],
  'registration_no': ['ssm', 'ssm no', 'company no', 'brn'],
  'sst_registration_no': ['sst no'],
  'email': ['e-mail', 'email address'],
  'phone': ['telephone', 'tel'],
  'mobile': ['handphone', 'hp'],
  'website': ['url'],
  'address_line1': ['address', 'address 1'],
  'address_line2': ['address 2'],
  'address_line3': ['address 3'],
  'postcode': ['post code', 'poskod', 'zip'],
  'city': ['town'],
  'state_code': ['state'],
  'country_code': ['country'],
  'currency': ['ccy'],
  'credit_limit': ['limit'],
  'notes': ['remarks'],
};

/// A chart from another system calls these a dozen things. `type` and
/// `subtype` are what most exports call them; `class` and `category`
/// are what the Malaysian SME packages tend to use.
const accountColumns = <String, List<String>>{
  'code': ['account code', 'account no', 'gl code', 'no', 'id'],
  'name': ['account name', 'description', 'title'],
  'account_type': ['type', 'class', 'category'],
  'account_subtype': ['subtype', 'sub type', 'sub-category', 'group type'],
  'parent_code': ['parent', 'parent account', 'header', 'heading'],
  'description': ['notes', 'remarks'],
  'is_group': ['group', 'is header', 'header account'],
};

const itemColumns = <String, List<String>>{
  'code': ['item code', 'product code', 'sku', 'no', 'id'],
  'name': ['item name', 'product name', 'description short'],
  'description': ['long description', 'details'],
  'item_type': ['type'],
  'barcode': ['ean', 'upc'],
  'uom_code': ['uom', 'unit', 'unit of measure'],
  'classification_code': ['classification', 'myinvois code'],
  'unit_price': ['price', 'selling price', 'sales price'],
  'cost_price': ['cost', 'purchase price'],
  'currency': ['ccy'],
  'track_inventory': ['stock', 'stocked', 'track stock'],
  'reorder_level': ['reorder', 'minimum stock'],
  'reorder_quantity': ['reorder qty'],
};

/// Open items, and the one heading that is worth arguing about.
///
/// `outstanding_amount` rather than `total` or `amount`, because a
/// column called total is filled in with the invoice total by everybody
/// who has ever prepared one of these files — and what belongs here is
/// what is still owed. The aliases below deliberately do not include
/// 'total' or 'amount' for the same reason: a heading that maps to the
/// wrong number silently overstates the receivables by everything
/// already collected.
const openInvoiceColumns = <String, List<String>>{
  'doc_no': ['invoice no', 'invoice number', 'document no', 'no'],
  'contact_code': ['customer code', 'customer', 'account code'],
  'doc_date': ['invoice date', 'date'],
  'due_date': ['due', 'payment due'],
  'outstanding_amount': ['outstanding', 'balance', 'balance due', 'unpaid'],
  'currency': ['ccy'],
  'exchange_rate': ['rate', 'fx rate'],
  'reference': ['your ref', 'po no', 'order no'],
  'description': ['particulars', 'remarks'],
};

/// 0631. One row per LINE, grouped by `doc_no`.
///
/// The aliases are the ones other packages actually print. `doc_type`
/// has none worth guessing at: a column called "type" in an export is
/// as likely to mean the item type or the tax type, and reading it as
/// the document type would turn every row into a credit note without
/// saying so.
const salesTransactionColumns = <String, List<String>>{
  'doc_no': ['invoice no', 'invoice number', 'document no', 'no'],
  'doc_type': ['document type'],
  'contact_code': ['customer code', 'customer', 'account code'],
  'doc_date': ['invoice date', 'date'],
  'due_date': ['due', 'payment due'],
  'currency': ['ccy'],
  'exchange_rate': ['rate', 'fx rate'],
  'reference': ['your ref', 'po no', 'order no'],
  'item_code': ['item', 'product code', 'stock code'],
  'description': ['particulars', 'remarks', 'details'],
  'quantity': ['qty', 'units'],
  'unit_price': ['price', 'rate per unit', 'unit rate'],
  'discount_percent': ['discount', 'disc %'],
  'tax_code': ['tax', 'sst code'],
};

/// 0632. The purchase side of [salesTransactionColumns], and the one
/// column that makes it different: `supplier_doc_no`, what is printed
/// on the paper. `0628` reads it to decide whether the same bill has
/// arrived twice, so a file that loses it loses the duplicate check.
const purchaseTransactionColumns = <String, List<String>>{
  'doc_no': ['bill no', 'our ref', 'document no', 'no'],
  'supplier_doc_no': ['supplier invoice no', 'their ref', 'invoice no'],
  'doc_type': ['document type'],
  'contact_code': ['supplier code', 'supplier', 'account code'],
  'doc_date': ['bill date', 'invoice date', 'date'],
  'due_date': ['due', 'payment due'],
  'currency': ['ccy'],
  'exchange_rate': ['rate', 'fx rate'],
  'reference': ['your ref', 'po no', 'order no'],
  'item_code': ['item', 'product code', 'stock code'],
  'description': ['particulars', 'remarks', 'details'],
  'quantity': ['qty', 'units'],
  'unit_price': ['price', 'rate per unit', 'unit rate'],
  'discount_percent': ['discount', 'disc %'],
  'tax_code': ['tax', 'sst code'],
};

/// 0633. One row per LINE, grouped by `entry_no`, with the debit and
/// the credit in their own columns — which is how a general ledger
/// prints and how every package exports one.
///
/// `debit` and `credit` have no aliases beyond the obvious: a column
/// called "amount" in a journal export is unsigned as often as not, and
/// reading it as a debit would put half a file on the wrong side.
const journalColumns = <String, List<String>>{
  'entry_no': ['journal no', 'jv no', 'voucher no', 'entry'],
  'entry_date': ['journal date', 'date'],
  'account_code': ['account', 'account no', 'gl code', 'ledger code'],
  'description': ['particulars', 'narration', 'remarks', 'details'],
  'debit': ['dr'],
  'credit': ['cr'],
  'contact_code': ['customer code', 'supplier code'],
};

const openBillColumns = <String, List<String>>{
  'doc_no': ['bill no', 'our ref', 'document no', 'no'],
  'supplier_doc_no': ['supplier invoice no', 'their ref', 'invoice no'],
  'contact_code': ['supplier code', 'supplier', 'account code'],
  'doc_date': ['bill date', 'invoice date', 'date'],
  'due_date': ['due', 'payment due'],
  'outstanding_amount': ['outstanding', 'balance', 'balance due', 'unpaid'],
  'currency': ['ccy'],
  'exchange_rate': ['rate', 'fx rate'],
  'reference': ['po no', 'order no'],
  'description': ['particulars', 'remarks'],
};

/// The opening trial balance.
///
/// `debit` and `credit` as separate columns rather than one signed
/// amount, because that is how every trial balance any accountant has
/// ever exported is shaped, and asking somebody to collapse two columns
/// into one signed one is asking them to get a sign wrong.
const openingBalanceColumns = <String, List<String>>{
  'account_code': ['account', 'code', 'gl code', 'account no'],
  'debit': ['dr', 'debit amount'],
  'credit': ['cr', 'credit amount'],
  'description': ['account name', 'particulars', 'narration'],
};

/// Opening stock.
///
/// `unit_cost` and not `value`: the cost per unit is what every sale
/// after the changeover takes its cost of sales from, and a total value
/// divided back out by a quantity somebody typed is one rounding away
/// from a margin that drifts.
const openingStockColumns = <String, List<String>>{
  'item_code': ['item', 'product code', 'sku', 'code'],
  'warehouse_code': ['warehouse', 'location', 'store'],
  'quantity': ['qty', 'on hand', 'quantity on hand'],
  'unit_cost': ['cost', 'average cost', 'unit price'],
  'lot_no': ['batch', 'batch no', 'lot', 'serial', 'serial no'],
  'expiry_date': ['expiry', 'expires', 'best before'],
};

/// Which file is being brought across.
enum ImportKind {
  contacts,
  items,
  accounts,
  openInvoices,
  openBills,
  openingBalances,
  openingStock,
  // 0631 and 0632, last in the order for the reason the comment below
  // gives: the transactions name contacts, items and tax codes, so they
  // are imported after everything they refer to.
  salesTransactions,
  purchaseTransactions,
  journals,
}

/// What each importer is called on the button that selects it.
///
/// An exhaustive switch on purpose: adding a kind to the enum without
/// naming it here is a compile error, which is the only way a list like
/// this stays in step with what it lists.
///
/// The order is `ImportKind.values`' own, and that order is the order
/// the job is done in: the master files first because the documents
/// name their rows, and the chart before the opening balances because
/// those name account numbers.
/// The columns a file of this kind cannot import without.
///
/// A top-level function rather than a getter on the screen's State, so
/// it can be asserted: which columns an importer REFUSES without is a
/// decision, and it was reachable from nothing until the mutation sweep
/// pointed out that deleting `doc_no` from the transaction importer's
/// list changed no test.
List<String> requiredColumnsFor(ImportKind kind) => switch (kind) {
  // A contact file may leave the code blank: the database draws one
  // from the row's series -- customer, supplier or prospect -- when
  // the file is imported, and says so at preview. An item file may
  // not, because the item code is what every later document line
  // names the item by.
  ImportKind.contacts => const ['name'],
  ImportKind.items => const ['code', 'name'],
  // The subtype and not the type: the subtype decides which line of
  // which statement the account lands on, and the type follows from
  // it (0550). A file naming only the type would leave every account
  // needing a decision this screen cannot make.
  ImportKind.accounts => const ['code', 'name', 'account_subtype'],
  ImportKind.openInvoices || ImportKind.openBills => const [
    'doc_no',
    'contact_code',
    'doc_date',
    'outstanding_amount',
  ],
  ImportKind.openingBalances => const ['account_code'],
  ImportKind.openingStock => const ['item_code', 'quantity', 'unit_cost'],
  // One row per line, so the required set is what a LINE needs:
  // which document it belongs to, whose it is, when, and what it
  // costs.
  ImportKind.salesTransactions => const [
    'doc_no',
    'contact_code',
    'doc_date',
    'unit_price',
  ],
  // The same four. `supplier_doc_no` is deliberately NOT required: a
  // subscription receipt or a toll carries no number of the supplier's,
  // and refusing the file over it would refuse the ordinary case to
  // protect the duplicate check.
  ImportKind.purchaseTransactions => const [
    'doc_no',
    'contact_code',
    'doc_date',
    'unit_price',
  ],
  // No `debit` or `credit` among them: a line carries ONE of the two,
  // so requiring either would refuse every file. Which one is present
  // is the importer's question, not the screen's.
  ImportKind.journals => const ['entry_no', 'entry_date', 'account_code'],
};

String importKindLabel(ImportKind kind) => switch (kind) {
  ImportKind.contacts => 'Contacts',
  ImportKind.items => 'Items',
  ImportKind.accounts => 'Chart of accounts',
  ImportKind.openInvoices => 'Open invoices',
  ImportKind.openBills => 'Open bills',
  ImportKind.openingBalances => 'Opening balances',
  ImportKind.openingStock => 'Opening stock',
  ImportKind.salesTransactions => 'Sales transactions',
  ImportKind.purchaseTransactions => 'Purchase transactions',
  ImportKind.journals => 'Journals',
};

/// Whether this kind writes to the ledger.
///
/// A top-level function rather than a getter on the state, because it is
/// the rule that decides which permission the screen asks for and it is
/// worth being able to assert on its own. A contact list is master data
/// and needs write access; an open invoice is a posting, and the
/// database refuses anybody who may prepare but not post — so a screen
/// that asked for write access throughout would offer an enabled button
/// to an accounts clerk and collect a refusal.
bool importNeedsPosting(ImportKind kind) =>
    // 0550. A chart is master data like the other two, and it is the
    // one piece of master data that decides what every future posting
    // lands on -- so `import_accounts` asks for `can_post` and this has
    // to ask for the same thing, or the screen offers an enabled button
    // to somebody the database will refuse.
    kind == ImportKind.accounts ||
    kind == ImportKind.openInvoices ||
    kind == ImportKind.openBills ||
    kind == ImportKind.openingBalances ||
    kind == ImportKind.openingStock;

/// How many rows would stop the file.
///
/// Only `error` does. `warning` is what the opening trial balance
/// answers when the old system's receivables figure and the invoices
/// actually brought across disagree — a real problem, and not one to
/// block a migration over, because the difference is exactly what
/// Opening Balance Equity is then left holding and the report says so.
/// Counting warnings here would make the most informative file in a
/// migration the one that cannot be imported.
int importBlockingErrors(List<Map<String, dynamic>> verdict) =>
    verdict.where((r) => r['status'] == 'error').length;

/// The rows the verdict lists, in the order it lists them.
///
/// Errors first, because with a hundred rows and two mistakes the two
/// are what somebody came for. Then warnings, which do not stop the
/// file but are the reason the control accounts are in it at all: a
/// row saying the old system's receivables and the invoices actually
/// brought across disagree is the single most useful line on the
/// screen, and hiding it because it is not fatal would waste it.
///
/// Then the rows that are fine and still have something to say. A
/// contact row that left the code blank is told at preview what shape
/// the code it gets will take, and after the import, which code it
/// got. Without these the preview of such a file reads 'all of them
/// fine' and the drawn codes are on nobody's screen. A fine row with
/// nothing to say is not listed: a hundred rows of 'ok' would bury the
/// two that matter.
List<Map<String, dynamic>> importRowsToList(
  List<Map<String, dynamic>> verdict,
) {
  final bad = verdict.where((r) => r['status'] == 'error').toList();
  final warned = verdict.where((r) => r['status'] == 'warning').toList();
  final noted = verdict
      .where(
        (r) =>
            r['status'] != 'error' &&
            r['status'] != 'warning' &&
            (r['message']?.toString() ?? '').isNotEmpty,
      )
      .toList();
  return [...bad, ...warned, ...noted];
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final _text = TextEditingController();

  ImportKind _kind = ImportKind.contacts;
  bool _busy = false;
  CsvTable? _table;
  List<Map<String, dynamic>>? _verdict;
  String? _failure;

  /// What was done to the file to make it readable, when anything was.
  /// See `readImportFile`: a stray non-breaking space is swapped for an
  /// ordinary one rather than refusing a whole export, and saying so is
  /// the difference between that and changing somebody's file quietly.
  String? _fileNote;

  /// What the file in the box looks like, and to whom (0552).
  ///
  /// Null until something has been parsed. Held rather than recomputed
  /// in `build` because the parse is what produces the headings, and a
  /// screen that re-derived this on every frame would be answering a
  /// question about a file it had not read.
  FileShape? _shape;

  /// The day the ledger takes the opening balances on. Today by default,
  /// which is what somebody sitting down to migrate usually means.
  DateTime _asAt = DateTime.now();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _openItems => importNeedsPosting(_kind);

  Map<String, List<String>> get _aliases => importColumnsFor(_kind);

  List<String> get _required => requiredColumnsFor(_kind);

  int get _errorCount => importBlockingErrors(_verdict ?? const []);

  Future<void> _run({required bool commit}) async {
    final table = parseCsvTable(_text.text, headerMapper(_aliases));
    final shape = identifyFile(selected: _kind, headers: table.header);
    setState(() {
      _table = table;
      _shape = shape;
      _verdict = null;
      _failure = null;
    });
    if (table.isEmpty) return;

    // A file that belongs to another importer does not get as far as
    // the database. It would be accepted there: the parse has already
    // dropped the columns that prove where it belongs, so the server
    // is handed two good columns and cannot know about the five it
    // never saw. This is the last point at which anything can tell.
    if (fileShapeBlocks(shape)) return;

    setState(() => _busy = true);
    final repo = ref.read(repoProvider)!;
    try {
      final rows = switch (_kind) {
        ImportKind.contacts || ImportKind.items => await repo.importRows(
          contacts: _kind == ImportKind.contacts,
          rows: table.rows,
          commit: commit,
        ),
        ImportKind.accounts => await repo.importAccounts(
          rows: table.rows,
          commit: commit,
        ),
        ImportKind.openInvoices ||
        ImportKind.openBills => await repo.importOpenItems(
          invoices: _kind == ImportKind.openInvoices,
          rows: table.rows,
          asAt: _asAt,
          commit: commit,
        ),
        ImportKind.openingBalances => await repo.importOpeningBalances(
          rows: table.rows,
          asAt: _asAt,
          commit: commit,
        ),
        ImportKind.openingStock => await repo.importOpeningStock(
          rows: table.rows,
          asAt: _asAt,
          commit: commit,
        ),
        // No `asAt`: these are not a changeover balance taken on one
        // day, they are the documents themselves and each keeps its own
        // date.
        ImportKind.salesTransactions => await repo.importSalesTransactions(
          rows: table.rows,
          commit: commit,
        ),
        ImportKind.purchaseTransactions =>
          await repo.importPurchaseTransactions(
            rows: table.rows,
            commit: commit,
          ),
        ImportKind.journals => await repo.importJournals(
          rows: table.rows,
          commit: commit,
        ),
      };
      setState(() => _verdict = rows);
      if (commit) {
        ref.invalidate(contactsProvider);
        ref.invalidate(itemsProvider);
        ref.invalidate(migrationProgressProvider);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported ${rows.length} ${_noun()}')),
          );
        }
      }
    } catch (err) {
      // The database refuses the whole file when a row is wrong, and the
      // message says how many. Shown as it came rather than reduced to
      // "import failed".
      setState(() => _failure = errorText(err));
    }
    if (mounted) setState(() => _busy = false);
  }

  /// Reads an uploaded file into the box.
  ///
  /// Into the box rather than straight into a preview, because the box
  /// is what the person can then correct: a file with one bad heading
  /// is fixed in place in ten seconds, and a screen that swallowed the
  /// file and reported a verdict about it would send them back to the
  /// spreadsheet.
  /// Hand over a blank file with the right headings.
  ///
  /// Not `exportTextFile`: that records a security event, and this file
  /// holds no company data at all. Writing "somebody exported" every
  /// time a person downloads an empty template would put noise in the
  /// one log that has to stay readable — `security_log` is where an
  /// auditor looks for a copy that actually left.
  Future<void> _downloadTemplate() async {
    final saved = await saveTextFile(
      importTemplateFilename(_kind),
      'text/csv',
      importTemplateCsv(_kind),
    );
    if (!mounted) return;
    // A build that cannot hand over a file says so rather than doing
    // nothing: the column chips above are the same information, and
    // somebody who pressed a button deserves to know why nothing
    // happened.
    if (!saved) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This app cannot save a file here. The column names are '
            'listed above.',
          ),
        ),
      );
    }
  }

  Future<void> _upload() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: importFileExtensions),
      ],
    );
    if (file == null) return;

    final read = readImportFile(await file.readAsBytes(), name: file.name);
    if (!mounted) return;
    setState(() {
      _failure = read.problem;
      _fileNote = read.note;
      _verdict = null;
      _table = null;
      _shape = null;
      if (read.text != null) _text.text = read.text!;
    });
    if (read.text != null) await _run(commit: false);
  }

  String _noun() => switch (_kind) {
    ImportKind.contacts => 'contacts',
    ImportKind.items => 'items',
    ImportKind.accounts => 'accounts',
    ImportKind.openInvoices => 'open invoices',
    ImportKind.openBills => 'open bills',
    ImportKind.openingBalances => 'opening balances',
    ImportKind.openingStock => 'opening stock lines',
    ImportKind.salesTransactions => 'transaction lines',
    ImportKind.purchaseTransactions => 'purchase transaction lines',
    ImportKind.journals => 'journal lines',
  };

  @override
  Widget build(BuildContext context) {
    final table = _table;
    // Master files need only write access. Open items post to the
    // ledger, and the database asks for the same thing an accounts clerk
    // does not have.
    final allowed = _openItems
        ? ref.watch(canPostProvider)
        : ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // Built from `ImportKind.values`, not typed out.
              //
              // It was typed out, and 0550 added a seventh kind --
              // the chart of accounts -- with its aliases, its
              // required columns, its RPC and its section heading all
              // wired up, and no button. Everything behind it worked
              // and none of it was reachable. A hand-kept list beside
              // an enum drifts the first time somebody adds to one and
              // not the other; this cannot, and the label switch is
              // exhaustive, so a new kind fails to compile until it
              // has a name.
              child: SegmentedButton<ImportKind>(
                showSelectedIcon: false,
                segments: [
                  for (final kind in ImportKind.values)
                    ButtonSegment(
                      value: kind,
                      label: Text(importKindLabel(kind)),
                    ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  _table = null;
                  _shape = null;
                  _verdict = null;
                  _failure = null;
                }),
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Progress(),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader(
                        switch (_kind) {
                          ImportKind.contacts => 'Customers and suppliers',
                          ImportKind.items => 'Items',
                          ImportKind.accounts => 'The chart of accounts',
                          ImportKind.openInvoices => 'Invoices still unpaid',
                          ImportKind.openBills => 'Bills still unpaid',
                          ImportKind.openingBalances =>
                            'The opening trial balance',
                          ImportKind.openingStock => 'Stock on hand',
                          ImportKind.salesTransactions =>
                            'Invoices and credit notes, in full',
                          ImportKind.purchaseTransactions =>
                            'Bills and supplier credit notes, in full',
                          // Said here rather than only in the migration:
                          // this is the one importer that posts, and
                          // somebody about to run it over a year of
                          // journals is entitled to know before they
                          // press it.
                          ImportKind.journals =>
                            'Journals — these post to the ledger',
                        },
                        subtitle:
                            'Upload the file, or paste it with its header '
                            'row. Nothing is written until every row is '
                            'good.',
                      ),
                      if (_openItems) ...[
                        const SizedBox(height: Space.sm),
                        _ChangeoverField(
                          value: _asAt,
                          onPick: _busy
                              ? null
                              : (d) => setState(() => _asAt = d),
                        ),
                        const SizedBox(height: Space.sm),
                        Text(
                          switch (_kind) {
                            ImportKind.openingBalances =>
                              'Paste the trial balance as the old system '
                                  'gives it, receivables and payables '
                                  'included. Those two are not posted again '
                                  '— the open invoices and bills already did '
                                  '— but they are compared against what came '
                                  'across, which is the most useful check in '
                                  'a migration. Everything else is posted, '
                                  'and the difference goes to Opening '
                                  'Balance Equity, which comes to zero when '
                                  'the two halves agree.',
                            ImportKind.openingStock =>
                              'Quantities and the cost per unit, which is '
                                  'what cost of sales will be charged at '
                                  'until the next purchase. No journal is '
                                  'posted — the inventory figure came in '
                                  'with the trial balance, and posting it '
                                  'again would double it — but the value of '
                                  'this file is compared against what the '
                                  'inventory accounts already say, and any '
                                  'difference is reported rather than '
                                  'adjusted away.',
                            _ =>
                              'What goes in the amount column is what is '
                                  'still owed, not the original total — '
                                  'anything already received stays in the '
                                  'old system, which is where anybody asking '
                                  'will look. Each document keeps the date '
                                  'it was raised so the ageing is right; the '
                                  'ledger takes the whole lot on the '
                                  'changeover date above. No tax is posted: '
                                  'it was declared under the old system, and '
                                  'declaring it twice is the mistake this '
                                  'avoids.',
                          },
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: Space.sm),
                      _Columns(aliases: _aliases, required: _required),
                      const SizedBox(height: Space.md),
                      Wrap(
                        spacing: Space.md,
                        runSpacing: Space.sm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            key: const ValueKey('import-upload'),
                            onPressed: _busy ? null : _upload,
                            icon: const Icon(Icons.upload_file, size: 18),
                            label: const Text('Upload a file'),
                          ),
                          // Beside the upload button rather than buried
                          // in help, because the moment somebody needs
                          // it is the moment they are looking at this
                          // row wondering what to upload.
                          OutlinedButton.icon(
                            key: const ValueKey('import-template'),
                            onPressed: _busy ? null : _downloadTemplate,
                            icon: const Icon(Icons.download, size: 18),
                            label: const Text('Download template'),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        // The three formats worth stating. Dates lead
                        // because they are the one that fails silently:
                        // `31/01/2026` is not a date Postgres reads in
                        // this order, so it becomes null and the row is
                        // rejected for a missing date nobody left out.
                        'CSV, saved as UTF-8. Or paste it below. Dates as '
                        'YYYY-MM-DD. Numbers may carry RM and thousands '
                        'separators. Yes/no columns take yes, y, true or 1.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: Space.sm),
                      TextField(
                        controller: _text,
                        maxLines: 10,
                        minLines: 6,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                        decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          hintText: switch (_kind) {
                            ImportKind.contacts =>
                              'code,name,contact_type,email\n'
                                  'C-001,Alpha Trading Sdn Bhd,customer,'
                                  'ap@alpha.com\n'
                                  ',Beta Supplies Sdn Bhd,supplier,',
                            ImportKind.items =>
                              'code,name,unit_price,uom_code\n'
                                  'ITEM-1,Widget,12.50,C62',
                            ImportKind.accounts =>
                              'code,name,account_subtype,parent_code,'
                                  'is_group\n'
                                  '8000,Motor vehicle expenses,'
                                  'operating_expense,,true\n'
                                  '8010,Fuel,operating_expense,8000,',
                            ImportKind.openInvoices =>
                              'doc_no,contact_code,doc_date,due_date,'
                                  'outstanding_amount\n'
                                  'INV-2025-0912,C-001,2025-11-03,'
                                  '2025-12-03,3000.00',
                            ImportKind.openBills =>
                              'doc_no,supplier_doc_no,contact_code,doc_date,'
                                  'outstanding_amount\n'
                                  'BILL-77,ST-2026-4411,S-001,2026-05-02,800',
                            ImportKind.openingBalances =>
                              'account_code,debit,credit\n'
                                  '1110,5000.00,\n'
                                  '3100,,5000.00',
                            ImportKind.openingStock =>
                              'item_code,quantity,unit_cost\n'
                                  'WIDGET-1,100,10.00',
                            // Two lines of ONE invoice, because that is
                            // the shape people get wrong: the number
                            // repeats down the file and the header
                            // repeats with it.
                            ImportKind.salesTransactions =>
                              'doc_no,contact_code,doc_date,description,'
                                  'quantity,unit_price\n'
                                  'INV-2025-0912,C-001,2025-11-03,'
                                  'Consulting,2,500.00\n'
                                  'INV-2025-0912,C-001,2025-11-03,'
                                  'Travel,1,250.00',
                            // The supplier's number is on every line
                            // because it belongs to the document, and a
                            // file where it changes halfway is two bills
                            // run together.
                            ImportKind.purchaseTransactions =>
                              'doc_no,supplier_doc_no,contact_code,'
                                  'doc_date,description,quantity,'
                                  'unit_price\n'
                                  'BILL-77,ST-2026-4411,S-001,2026-05-02,'
                                  'Paper,10,4.50',
                            // Both sides of one entry, because a journal
                            // that does not balance is the mistake this
                            // importer exists to catch.
                            ImportKind.journals =>
                              'entry_no,entry_date,account_code,'
                                  'description,debit,credit\n'
                                  'JV-0088,2026-02-01,6900,Depreciation,'
                                  '400.00,\n'
                                  'JV-0088,2026-02-01,1800,Depreciation,'
                                  ',400.00',
                          },
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: _busy ? null : () => _run(commit: false),
                            icon: const Icon(
                              Icons.fact_check_outlined,
                              size: 18,
                            ),
                            label: const Text('Check it'),
                          ),
                          const SizedBox(width: Space.md),
                          FilledButton.icon(
                            // Only once it has been checked and come back
                            // clean: the import would refuse it anyway,
                            // and refusing it here says why sooner.
                            key: const ValueKey('import-commit'),
                            onPressed:
                                _busy ||
                                    !allowed ||
                                    _verdict == null ||
                                    _errorCount > 0 ||
                                    // Belt and braces. `_run` already
                                    // returns before the database when
                                    // the file belongs elsewhere, so
                                    // there is no verdict to enable
                                    // this -- but a button that can be
                                    // pressed on a file the screen has
                                    // just called wrong is a button
                                    // somebody will press.
                                    (_shape != null && fileShapeBlocks(_shape!))
                                ? null
                                : () => _run(commit: true),
                            icon: const Icon(Icons.upload, size: 18),
                            label: const Text('Import'),
                          ),
                          const Spacer(),
                          if (_busy)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // 0552. The file belongs to another importer. Shown
              // before anything about rows, because "this is the wrong
              // list" makes every message under it beside the point.
              if (_shape != null && fileShapeWarning(_shape!) != null) ...[
                const SizedBox(height: Space.lg),
                Card(
                  key: const ValueKey('wrong-importer'),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.swap_horiz,
                              size: 18,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: Space.sm),
                            Text(
                              fileShapeBlocks(_shape!)
                                  ? 'This file is for another importer'
                                  : 'This file may be for another importer',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                        const SizedBox(height: Space.sm),
                        Text(fileShapeWarning(_shape!)!),
                        const SizedBox(height: Space.md),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            key: const ValueKey('switch-importer'),
                            onPressed: () => setState(() {
                              _kind = _shape!.looksLike!;
                              _table = null;
                              _shape = null;
                              _verdict = null;
                              _failure = null;
                            }),
                            icon: const Icon(Icons.arrow_forward, size: 18),
                            label: Text(
                              'Import it as '
                              '${importKindLabel(_shape!.looksLike!).toLowerCase()}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              // Not a warning, and deliberately not phrased as one. A
              // chart exported from this product carries `is_active`
              // and `current_balance`, which the importer does not
              // read. The difference this makes is between a column
              // being ignored and a column being ignored silently.
              if (table != null &&
                  _shape != null &&
                  !fileShapeBlocks(_shape!) &&
                  ignoredColumnsNote(_kind, table.header) != null) ...[
                const SizedBox(height: Space.md),
                Text(
                  ignoredColumnsNote(_kind, table.header)!,
                  key: const ValueKey('ignored-columns'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (table != null && table.problems.isNotEmpty) ...[
                const SizedBox(height: Space.lg),
                _Panel(
                  danger: true,
                  title: 'The file could not be read',
                  lines: table.problems,
                ),
              ],
              if (_failure != null) ...[
                const SizedBox(height: Space.lg),
                _Panel(
                  danger: true,
                  title: 'Nothing was imported',
                  lines: [_failure!],
                ),
              ],
              if (_fileNote != null) ...[
                const SizedBox(height: Space.lg),
                _Panel(
                  title: 'About the file',
                  lines: [_fileNote!],
                ),
              ],
              if (_verdict != null) ...[
                const SizedBox(height: Space.lg),
                _Verdict(rows: _verdict!, errors: _errorCount),
              ],
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

/// Where the migration has got to.
///
/// Six importers on one screen are a job rather than six features, and
/// done out of order they refuse each other one message at a time. This
/// is the order, with what is there for each — and the last line, which
/// is the only one that can say the job is finished.
///
/// Counts rather than ticks, because for four of the six there is no
/// honest "done": a firm with no stock and no items has finished those
/// steps by having nothing to bring across, and a tick would be either a
/// lie or a nag. 0153 has the reasoning.
class _Progress extends ConsumerWidget {
  const _Progress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return Card(
      // Keyed because several of the step names are also headings on the
      // cards below — 'Customers and suppliers' is both step one and the
      // title of the importer for it — so a test asking what this card
      // says has to be able to say *this card*.
      key: const ValueKey('migration-progress'),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(
              'Moving onto this system',
              subtitle: 'The order these have to be done in',
            ),
            AsyncView(
              value: ref.watch(migrationProgressProvider),
              onRetry: () => ref.invalidate(migrationProgressProvider),
              skeleton: const ListSkeleton(rows: 4, leading: false),
              builder: (rows) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final r in rows)
                    if (r['step_no'] != 7)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 26,
                              child: Text(
                                '${r['step_no']}.',
                                style: TextStyle(fontSize: 12, color: muted),
                              ),
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r['step']?.toString() ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    r['detail']?.toString() ?? '',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              Fmt.qty(Fmt.toDouble(r['quantity'])),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                  const Divider(height: Space.lg),
                  for (final r in rows)
                    if (r['step_no'] == 7) _MigrationVerdict(row: r),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The suspense account, which is the only line here that is a verdict
/// rather than a count.
class _MigrationVerdict extends StatelessWidget {
  const _MigrationVerdict({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final amount = Fmt.toDouble(row['quantity']);
    final detail = row['detail']?.toString() ?? '';
    // Nil reads as finished only when something has been brought across,
    // and the sentence from the database is what tells the two apart —
    // so the tick follows the sentence rather than the number.
    final done = detail.contains('everything from the old books is here');

    return Row(
      key: const ValueKey('migration-verdict'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          done ? Icons.check_circle_outline : Icons.pending_outlined,
          size: 18,
          color: done ? context.colors.success : context.colors.warning,
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${row['step']} · ${Fmt.money(amount)}',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              Text(detail, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}

/// The day the books change hands.
///
/// Its own field rather than a column in the file, because it is one
/// fact about the whole migration and not about any invoice in it —
/// repeated per row it would be something to get inconsistently wrong.
class _ChangeoverField extends StatelessWidget {
  const _ChangeoverField({required this.value, required this.onPick});

  final DateTime value;
  final ValueChanged<DateTime>? onPick;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Changeover date',
        helperText: 'Every ledger entry in this file carries it',
        isDense: true,
      ),
      child: Row(
        children: [
          Expanded(child: Text(Fmt.date(value))),
          TextButton(
            key: const ValueKey('import-as-at'),
            onPressed: onPick == null
                ? null
                : () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: value,
                      firstDate: DateTime(2015),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) onPick!(picked);
                  },
            child: const Text('Pick'),
          ),
        ],
      ),
    );
  }
}

/// What the file may contain, so somebody can arrange their spreadsheet
/// before pasting rather than by trial and error.
class _Columns extends StatelessWidget {
  const _Columns({required this.aliases, required this.required});

  final Map<String, List<String>> aliases;
  final List<String> required;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final field in aliases.keys)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(
              field,
              style: TextStyle(
                fontSize: 11,
                fontWeight: required.contains(field)
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            side: required.contains(field)
                ? BorderSide(color: context.colors.success)
                : null,
          ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.lines, this.danger = false});

  final String title;
  final List<String> lines;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colour = danger ? context.colors.danger : context.colors.success;
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          for (final l in lines)
            Text(l, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

String _label(Map<String, dynamic> row) {
  final v = (row['code'] ?? row['doc_no'])?.toString() ?? '';
  return v.isEmpty ? '' : ' · $v';
}

/// The per-row answer. What is listed, and in what order, is
/// [importRowsToList]'s to say.
class _Verdict extends StatelessWidget {
  const _Verdict({required this.rows, required this.errors});

  final List<Map<String, dynamic>> rows;
  final int errors;

  @override
  Widget build(BuildContext context) {
    final imported = rows.where((r) => r['status'] == 'imported').length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              imported > 0
                  ? 'Imported $imported rows'
                  : errors == 0
                  ? '${rows.length} rows, all of them fine'
                  : '$errors of ${rows.length} rows need fixing',
              subtitle: imported > 0
                  ? null
                  : errors == 0
                  ? 'Nothing has been written yet. Import writes them.'
                  : 'Nothing will be written until these are fixed.',
            ),
            for (final r in importRowsToList(rows))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (r['status']) {
                    'error' => Icons.error_outline,
                    'warning' => Icons.info_outline,
                    // A fine row with a note: a code drawn, or about
                    // to be. Not a danger colour, because there is
                    // nothing to fix.
                    _ => Icons.tag,
                  },
                  size: 18,
                  color: switch (r['status']) {
                    'error' => context.colors.danger,
                    'warning' => context.colors.warning,
                    _ => context.colors.info,
                  },
                ),
                title: Text(
                  // The master-file importers answer with `code` and
                  // the open-item ones with `doc_no`. Whichever is
                  // there, because the row number alone is not what
                  // somebody looks for in a spreadsheet.
                  'Row ${r['row_no']}${_label(r)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(r['message']?.toString() ?? ''),
              ),
          ],
        ),
      ),
    );
  }
}
