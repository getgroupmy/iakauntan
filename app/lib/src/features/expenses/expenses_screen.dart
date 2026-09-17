import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/skeletons.dart';
import '../../core/searchable_picker.dart';
import '../../core/download.dart';
import '../../core/format.dart';
import '../../core/pdf_kit.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/attachments_repository.dart';
import '../../data/models.dart';
import '../../data/ocr_repository.dart';
import '../banking/new_bank_account_dialog.dart';
import '../contacts/new_contact_dialog.dart';
import '../settings/new_account_dialog.dart';
import '../shared/attachments_card.dart';
import '../shared/scan_runner.dart';
import 'expense_split.dart';
import 'expense_voucher_pdf.dart';
import '../shared/doc_scanner.dart';
import '../shared/receipt_capture.dart';
import '../shared/scan_intake.dart';
import '../shared/scan_result_dialog.dart';
import '../settings/tax_code_dialog.dart';

/// Photograph a receipt, then finish what the paper could not say.
///
/// The reading fills the description, the date, the reference and the
/// amount. What is left is what no receipt carries: which expense
/// account it belongs to, which tax code, and what it was paid from —
/// so the form opens with those empty and everything else already in.
Future<void> _scanExpense(BuildContext context, WidgetRef ref) async {
  final staged = await showScanIntake(
    context,
    ref,
    table: 'expenses',
    title: 'Scan an expense',
  );
  if (staged == null || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (_) => _ExpenseDialog(scanned: staged),
  );
}

/// Money already spent, captured and posted in one step — there is no
/// useful draft state for an expense that has already left the bank.
class ExpensesScreen extends ConsumerWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expenses = ref.watch(expensesProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: [
          // Scan first, and before the blank form, because that is the
          // order the work happens in: somebody is holding a receipt and
          // has not yet decided which account it belongs to.
          if (canPost)
            TextButton.icon(
              onPressed: () => _scanExpense(context, ref),
              icon: const Icon(Icons.document_scanner_outlined, size: 18),
              label: const Text('Scan expense'),
            ),
          if (canPost)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _ExpenseDialog(),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Record expense'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: expenses,
        onRetry: () => ref.invalidate(expensesProvider),
        // Rows in a list, and the shape is decided by the screen
        // rather than by the payload -- a name and a value, on
        // every one of them. No avatar: these rows do not carry
        // one, and a bone where nothing goes reflows the moment
        // the data lands, which is the flicker a skeleton is for.
        skeleton: const ListSkeleton(leading: false),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_outlined,
              title: 'No expenses recorded',
              message: 'Capture rent, utilities and other running costs here.',
              action: canPost
                  ? FilledButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _ExpenseDialog(),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Record expense'),
                    )
                  : null,
            );
          }

          final total = list.fold<double>(
              0, (sum, e) => sum + Fmt.toDouble(e['total_amount']));

          return Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.35),
                child: Text(
                  '${list.length} expenses · ${Fmt.money(total)}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final account = e['accounts'] as Map?;
                    final payee = (e['contacts'] as Map?)?['name'];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 4),
                      title: Row(children: [
                        Flexible(
                          child: Text(
                            e['description']?.toString() ??
                                e['expense_no']?.toString() ??
                                '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        const SizedBox(width: 10),
                        StatusChip(e['status']?.toString() ?? 'draft',
                            compact: true),
                      ]),
                      subtitle: Text(
                        [
                          e['expense_no'],
                          // Who was paid, where there is one. First
                          // after the number because it is the question
                          // asked of a line of expenses more often than
                          // which account it landed in.
                          if (payee != null) payee,
                          if (account != null)
                            '${account['code']} ${account['name']}',
                          Fmt.date(Fmt.parseDate(e['expense_date'])),
                        ].where((v) => v != null).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing:
                          Money(Fmt.toDouble(e['total_amount']), bold: true),
                      // Until now an expense could be created and never
                      // opened again, which is why its receipt had
                      // nowhere to live. An expense without the receipt
                      // behind it is the line an auditor asks about and
                      // nobody can answer.
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ExpenseDetail(expense: e),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ExpenseDialog extends ConsumerStatefulWidget {
  const _ExpenseDialog({this.scanned});

  /// A receipt already captured, filed and read. The form opens filled
  /// in from it; abandoning the form still cleans the file up.
  final StagedReceipt? scanned;

  @override
  ConsumerState<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends ConsumerState<_ExpenseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  final _reference = TextEditingController();

  String? _accountId;

  /// A charge divided across several accounts. Empty is the ordinary
  /// case and behaves exactly as it always has: one account, one debit.
  ExpenseSplit _split = const ExpenseSplit.none();
  final _splitAmounts = <TextEditingController>[];

  String? _bankAccountId;

  /// Who was paid. Null is the ordinary case for petty cash and stays
  /// null: an expense with no payee is still an expense.
  String? _contactId;
  String? _taxCodeId;

  /// Which job and which department this cost belongs to, or null for
  /// both, which is the ordinary case.
  ///
  /// `expenses.project_code` has existed since the dimensions did and
  /// nothing in this app ever set it; `department_code` did not exist
  /// at all until `0639`. So a cost claimed here reached the ledger
  /// with both dimensions null however carefully it was coded, and the
  /// P&L's filters answered confidently while omitting every one of
  /// them — a department whose spending arrived this way read as a
  /// department that had UNDERSPENT, which is the one shape of
  /// reporting error nobody reports.
  String? _projectCode;
  String? _departmentCode;

  String _paymentMode = '03';
  DateTime _date = DateTime.now();
  bool _saving = false;
  bool _reading = false;

  /// The receipt, filed before this expense existed. Moved onto the
  /// expense when it is recorded, and deleted if this dialog is
  /// abandoned — an orphan under a record that was never created is
  /// storage nobody will ever find again.
  StagedReceipt? _receipt;

  @override
  void initState() {
    super.initState();
    final scanned = widget.scanned;
    if (scanned == null) return;
    _receipt = scanned;
    if (scanned.read != null) _apply(scanned.read!);
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _reference.dispose();
    for (final c in _splitAmounts) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _capture(CaptureSource source) async {
    setState(() => _reading = true);
    final staged = await captureAndRead(context, ref,
        source: source, table: 'expenses');
    if (!mounted) {
      // The dialog closed under it. Nothing here to attach it to, so it
      // is not left lying in the bucket.
      if (staged != null) {
        ref.read(repoProvider)?.deleteAttachmentById(staged.attachmentId);
      }
      return;
    }
    setState(() {
      _reading = false;
      // A second capture replaces the first, so the earlier file goes.
      final previous = _receipt;
      if (previous != null && staged != null) {
        ref.read(repoProvider)?.deleteAttachmentById(previous.attachmentId);
      }
      if (staged != null) _receipt = staged;
    });
    if (staged?.read == null) return;

    // Shown before it is applied. A machine reading a faded thermal
    // receipt is a good first draft, not a source document.
    final accepted = await showScanResult(context, staged!.read!, canApply: true);
    if (accepted == null) return;
    // What the paper was taken to be, onto the scan. `0614`.
    await rememberDocumentKind(ref,
        attachmentId: staged.attachmentId, accepted: accepted);
    if (mounted) setState(() => _apply(accepted));
  }

  void _apply(OcrExtraction read) {
    final net = read.netAmount;
    if (net != null) _amount.text = net.toStringAsFixed(2);
    if (read.documentDate != null) _date = read.documentDate!;
    // The supplier and the document number, joined, because an expense
    // has one description field and both belong in it.
    final description = [read.supplierName, read.documentNo]
        .whereType<String>()
        .join(' · ');
    if (description.isNotEmpty) _description.text = description;
    if (read.documentNo != null) _reference.text = read.documentNo!;
  }

  Future<void> _discardReceipt() async {
    final staged = _receipt;
    if (staged == null) return;
    setState(() => _receipt = null);
    await ref.read(repoProvider)?.deleteAttachmentById(staged.attachmentId);
  }

  double get _net =>
      _split.isOn ? _split.total : (double.tryParse(_amount.text) ?? 0);

  // ------------------------------------------------------------------
  // The split
  // ------------------------------------------------------------------
  void _startSplit() {
    // The first line is what has been typed so far, so turning the
    // split on never loses the account and amount already chosen.
    final typed = double.tryParse(_amount.text) ?? 0;
    setState(() {
      _split = ExpenseSplit([
        SplitLine(accountId: _accountId, amount: typed),
        const SplitLine(),
      ]);
      _splitAmounts
        ..add(TextEditingController(
            text: typed > 0 ? typed.toStringAsFixed(2) : ''))
        ..add(TextEditingController());
    });
  }

  void _endSplit() {
    setState(() {
      // Back to one account and one amount: the largest line, which is
      // the same rule the database uses for the header.
      final biggest = [..._split.lines]
        ..sort((a, b) => b.amount.compareTo(a.amount));
      if (biggest.isNotEmpty) {
        _accountId = biggest.first.accountId ?? _accountId;
        if (_split.total > 0) _amount.text = _split.total.toStringAsFixed(2);
      }
      _split = const ExpenseSplit.none();
      for (final c in _splitAmounts) {
        c.dispose();
      }
      _splitAmounts.clear();
    });
  }

  void _addSplitLine() => setState(() {
        _split = _split.withLine(const SplitLine());
        _splitAmounts.add(TextEditingController());
      });

  void _removeSplitLine(int i) => setState(() {
        _split = _split.without(i);
        _splitAmounts.removeAt(i).dispose();
      });

  double get _tax {
    // `valueOrNull`: `AsyncError.value` throws, so the `??` beside it
    // never ran and a failed tax-code load took this dialog down from
    // inside `build`. See scripts/check_async_value.py.
    final codes = ref.read(taxCodesProvider).valueOrNull ?? const <TaxCode>[];
    final rate =
        codes.where((t) => t.id == _taxCodeId).firstOrNull?.rate ?? 0;
    // `Fmt.taxOn`, not the arithmetic spelled out here, which was a
    // cent low whenever the answer sat exactly on a half-cent -- and
    // this figure is STORED: `recordExpense` inserts it as
    // `tax_amount`, and `0286` only checks that the total agrees with
    // it, so nothing downstream would have noticed.
    return Fmt.taxOn(_net, rate);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final wrong = _split.problem;
    if (wrong != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(wrong)));
      return;
    }
    // With a split the header account is the largest line's, which is
    // what `set_expense_split` writes back anyway; without one it is
    // the account that was chosen.
    final headerAccount = _split.isOn
        ? ([..._split.lines]..sort((a, b) => b.amount.compareTo(a.amount)))
            .first
            .accountId
        : _accountId;
    if (headerAccount == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () async {
        final repo = ref.read(repoProvider)!;
        final id = await repo.recordExpense(
          accountId: headerAccount,
          amount: _net,
          split: _split.isOn ? _split.toJson() : null,
          date: _date,
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          contactId: _contactId,
          bankAccountId: _bankAccountId,
          paymentModeCode: _paymentMode,
          taxCodeId: _taxCodeId,
          taxAmount: _tax,
          projectCode: _projectCode,
          departmentCode: _departmentCode,
          reference: _reference.text.trim().isEmpty
              ? null
              : _reference.text.trim(),
        );

        // The receipt was photographed before the expense existed, so it
        // is filed onto it now. Last, and deliberately: an expense that
        // posted is worth keeping even if moving the file fails, and the
        // file is still findable by its scan either way.
        final staged = _receipt;
        if (staged != null) {
          await repo.refileAttachment(
            attachmentId: staged.attachmentId,
            table: 'expenses',
            recordId: id,
          );
        }
      },
      successMessage: 'Expense recorded and posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshLedgerData(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only expense accounts are sensible here.
    final accounts = (ref.watch(accountsProvider).value ?? const <Account>[])
        .where((a) => a.accountType == 'expense' && !a.isGroup)
        .toList();
    final banks = ref.watch(bankAccountsProvider).value ?? const [];
    final modes = ref.watch(paymentModesProvider).value ?? const [];
    final projects = ref.watch(projectsProvider).valueOrNull ?? const [];
    final departments =
        ref.watch(departmentsProvider).valueOrNull ?? const [];
    // Suppliers, because that is what a payee is: the same list the
    // purchase side picks from, so a bill and the cash paid for it end
    // up against one contact rather than two spellings of one.
    final payees =
        ref.watch(contactsProvider((type: 'supplier', search: ''))).valueOrNull ??
            const <Contact>[];

    final ocr = ref.watch(ocrStatusProvider).valueOrNull ?? OcrSettings.off;

    return AlertDialog(
      title: const Text('Record expense'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Before the form, because this is the order the work
                // happens in: somebody is holding a receipt and has not
                // yet decided which account it belongs to.
                if (ocr.enabled) ...[
                  _ReceiptStrip(
                    reading: _reading,
                    receipt: _receipt,
                    price: ocr.keySource == 'platform' ? ocr.price : 0,
                    // Scan first where there is a scanner: it crops and
                    // straightens before anything reads it, which every
                    // reader does better on and a filed receipt looks
                    // better as.
                    onScan: docScannerLikely
                        ? () => _capture(CaptureSource.scanner)
                        : null,
                    onPhotograph: cameraLikely
                        ? () => _capture(CaptureSource.camera)
                        : null,
                    onPick: () => _capture(CaptureSource.file),
                    onDiscard: _discardReceipt,
                  ),
                  const SizedBox(height: 16),
                ],
                // One account, or several. A card statement is often
                // several: the RM 500 on the 14th was part flights and
                // part client dinner, and typing it as two expenses
                // with two numbers is how the receipt gets separated
                // from half of what it paid for.
                if (!_split.isOn) ...[
                  // The chart of accounts is the longest list in the
                  // product and the one people know by NUMBER. Typing
                  // "6100" should land on it; scrolling to it should
                  // not be the only way.
                  SearchablePicker<String>(
                    options: [
                      for (final a in accounts)
                        PickerOption(
                          value: a.id,
                          label: '${a.code} — ${a.name}',
                          keywords: [a.code, a.name],
                        ),
                    ],
                    value: _accountId,
                    label: 'Expense account *',
                    hint: 'Type a number or a name',
                    createLabel: 'Add account',
                    // The chart of accounts IS a list a company extends
                    // — a new expense heading, a new bank, a new
                    // reserve. "Nothing matches that" was a dead end in
                    // the box most likely to reach for something new.
                    onCreate: (typed) =>
                        createAccountFromPicker(context, typed: typed),
                    onChanged: (v) => setState(() => _accountId = v),
                    validator: (v) => v == null ? 'Choose an account' : null,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _startSplit,
                      icon: const Icon(Icons.call_split, size: 18),
                      label: const Text('Split across accounts'),
                    ),
                  ),
                ] else
                  _SplitEditor(
                    split: _split,
                    controllers: _splitAmounts,
                    accounts: accounts,
                    onAccount: (i, v) => setState(() =>
                        _split = _split.replace(
                            i, _split.lines[i].copyWith(accountId: v))),
                    onAmount: (i, v) => setState(() => _split = _split.replace(
                        i,
                        _split.lines[i]
                            .copyWith(amount: double.tryParse(v) ?? 0))),
                    onDescription: (i, v) => setState(() =>
                        _split = _split.replace(
                            i, _split.lines[i].copyWith(description: v))),
                    onAdd: _addSplitLine,
                    onRemove: _removeSplitLine,
                    onCancel: _endSplit,
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    // A split expense's amount is added up, never
                    // typed: the database writes the header from the
                    // lines, so a second figure here could only
                    // disagree with them.
                    child: _split.isOn
                        ? InputDecorator(
                            decoration: const InputDecoration(
                                labelText: 'Amount', prefixText: 'RM '),
                            child: Text(Fmt.money(_split.total)),
                          )
                        : TextFormField(
                            controller: _amount,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            onChanged: (_) => setState(() {}),
                            decoration: const InputDecoration(
                                labelText: 'Amount *', prefixText: 'RM '),
                            validator: (v) =>
                                (double.tryParse(v ?? '') ?? 0) <= 0
                                    ? 'Enter an amount'
                                    : null,
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TaxCodePicker(
                      value: _taxCodeId,
                      label: 'Tax',
                      allowEmpty: true,
                      onChanged: (v) => setState(() => _taxCodeId = v),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          suffixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Text(Fmt.date(_date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _paymentMode,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Paid by'),
                      items: [
                        for (final m in modes)
                          DropdownMenuItem(
                            value: m['code'] as String,
                            child: Text(m['description'] as String,
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _paymentMode = v ?? '03'),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                // Who was paid. The column, the posting and the payment
                // voucher have carried a payee since 0006 and nothing
                // has ever set one: `recordExpense` takes `contactId`
                // and no caller passed it, so `gl_lines.contact_id` was
                // null on every expense ever posted and the voucher
                // printed an em dash where the name goes.
                //
                // Optional, and deliberately. A toll, a parking ticket
                // and a kopi for a site visit have no payee worth
                // putting on file, and forcing one would fill the
                // contact list with them.
                SearchablePicker<String>(
                  key: const ValueKey('expense-payee'),
                  options: contactPickerOptions(payees),
                  value: _contactId,
                  allowEmpty: true,
                  emptyLabel: 'Nobody in particular',
                  label: 'Paid to',
                  hint: 'Type a name',
                  helperText:
                      'Who the money went to. Leave blank for petty cash '
                      'with no supplier behind it.',
                  createLabel: 'Add supplier',
                  onCreate: (typed) => createContactFromPicker(
                    context,
                    contactType: 'supplier',
                    typed: typed,
                  ),
                  onChanged: (v) => setState(() => _contactId = v),
                ),
                const SizedBox(height: 12),
                SearchablePicker<String>(
                  options: [
                    for (final b in banks)
                      PickerOption(
                        value: b['id'] as String,
                        label: b['name'] as String,
                      ),
                  ],
                  value: _bankAccountId,
                  allowEmpty: true,
                  emptyLabel: 'The default bank account',
                  label: 'Paid from',
                  helperText: 'Leave blank to use the default bank account',
                  createLabel: 'Add bank account',
                  onCreate: (typed) =>
                      createBankAccountFromPicker(context, typed: typed),
                  onChanged: (v) => setState(() => _bankAccountId = v),
                ),
                // Only once there is something to choose. A company
                // that has created neither gets neither control rather
                // than two empty ones, which is the rule the journal
                // editor's project picker already follows: a dropdown
                // with nothing in it teaches people to ignore
                // dropdowns.
                if (projects.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SearchablePicker<String>(
                    key: const ValueKey('expense-project'),
                    options: [
                      for (final p in projects)
                        PickerOption<String>(
                          value: p['code'] as String,
                          label: '${p['name']}',
                          sublabel: '${p['code']}',
                          keywords: ['${p['code']}'],
                        ),
                    ],
                    value: _projectCode,
                    allowEmpty: true,
                    emptyLabel: 'No job',
                    label: 'Job',
                    helperText: 'Which job this cost is against',
                    onChanged: (v) => setState(() => _projectCode = v),
                  ),
                ],
                if (departments.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SearchablePicker<String>(
                    key: const ValueKey('expense-department'),
                    options: [
                      for (final d in departments)
                        PickerOption<String>(
                          value: d['code'] as String,
                          label: '${d['name']}',
                          sublabel: '${d['code']}',
                          keywords: ['${d['code']}'],
                        ),
                    ],
                    value: _departmentCode,
                    allowEmpty: true,
                    emptyLabel: 'No department',
                    label: 'Department',
                    helperText:
                        'Whose budget this comes out of. Leave blank and '
                        'the cost is in the company total and in no '
                        'department.',
                    onChanged: (v) => setState(() => _departmentCode = v),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reference,
                  decoration: const InputDecoration(labelText: 'Reference'),
                ),
                if (_tax > 0) ...[
                  const SizedBox(height: 16),
                  Row(children: [
                    const Expanded(child: Text('Total including tax')),
                    Money(_net + _tax, bold: true),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            // A receipt captured for an expense that was never recorded
            // has nothing to hang off, so it goes with the dialog.
            _discardReceipt();
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Record and post'),
        ),
      ],
    );
  }
}

/// The receipt, before there is an expense to file it against.
/// The lines a charge is divided into.
///
/// Deliberately plain: an account, an amount and a note per line, with
/// the total added up underneath. Everything that decides whether the
/// split is sendable lives in [ExpenseSplit], not here.
class _SplitEditor extends StatelessWidget {
  const _SplitEditor({
    required this.split,
    required this.controllers,
    required this.accounts,
    required this.onAccount,
    required this.onAmount,
    required this.onDescription,
    required this.onAdd,
    required this.onRemove,
    required this.onCancel,
  });

  final ExpenseSplit split;
  final List<TextEditingController> controllers;
  final List<Account> accounts;
  final void Function(int, String?) onAccount;
  final void Function(int, String) onAmount;
  final void Function(int, String) onDescription;
  final VoidCallback onAdd;
  final void Function(int) onRemove;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final wrong = split.problem;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(
            child: Text('Split across accounts',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          TextButton(onPressed: onCancel, child: const Text('Use one account')),
        ]),
        for (var i = 0; i < split.lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: SearchablePicker<String>(
                    options: [
                      for (final a in accounts)
                        PickerOption(
                          value: a.id,
                          label: '${a.code} — ${a.name}',
                          keywords: [a.code, a.name],
                        ),
                    ],
                    value: split.lines[i].accountId,
                    label: 'Account',
                    hint: 'Type a number or a name',
                    createLabel: 'Add account',
                    onCreate: (typed) =>
                        createAccountFromPicker(context, typed: typed),
                    onChanged: (v) => onAccount(i, v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: controllers[i],
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Amount', prefixText: 'RM '),
                    onChanged: (v) => onAmount(i, v),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: TextFormField(
                    initialValue: split.lines[i].description,
                    decoration: const InputDecoration(labelText: 'For'),
                    onChanged: (v) => onDescription(i, v),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove this line',
                  icon: const Icon(Icons.close, size: 18),
                  // Two is the fewest a split can be. Below that it is
                  // not a split, and "Use one account" is the way back.
                  onPressed:
                      split.lines.length > 2 ? () => onRemove(i) : null,
                ),
              ],
            ),
          ),
        Row(children: [
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a line'),
          ),
          const Spacer(),
          Text('Total ${Fmt.money(split.total)}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ]),
        if (wrong != null)
          Text(wrong,
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).colorScheme.error)),
      ],
    );
  }
}

class _ReceiptStrip extends StatelessWidget {
  const _ReceiptStrip({
    required this.reading,
    required this.receipt,
    required this.price,
    required this.onScan,
    required this.onPhotograph,
    required this.onPick,
    required this.onDiscard,
  });

  final bool reading;
  final StagedReceipt? receipt;
  final double price;

  /// Null where there is no scanner, which leaves the plain camera as
  /// the first thing on the strip rather than a gap.
  final VoidCallback? onScan;
  final VoidCallback? onPhotograph;
  final VoidCallback onPick;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final held = receipt != null;

    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(
          held ? Icons.check_circle_outline : Icons.receipt_long_outlined,
          size: 20,
          color: held ? context.colors.success : context.scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            reading
                ? 'Reading it…'
                : held
                    ? 'Receipt attached. It will be filed against this expense.'
                    : price > 0
                        ? 'Scan the receipt and it fills this in '
                            '(${Fmt.money(price)}).'
                        : 'Scan the receipt and it fills this in.',
            style: const TextStyle(fontSize: 13),
          ),
        ),
        if (reading)
          const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
        else if (held)
          IconButton(
            tooltip: 'Remove the receipt',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDiscard,
          )
        else ...[
          if (onScan != null)
            IconButton(
              tooltip: 'Scan it',
              icon: const Icon(Icons.document_scanner_outlined, size: 20),
              onPressed: onScan,
            ),
          if (onPhotograph != null)
            IconButton(
              tooltip: 'Photograph it',
              icon: const Icon(Icons.photo_camera_outlined, size: 20),
              onPressed: onPhotograph,
            ),
          IconButton(
            tooltip: 'Choose a file',
            icon: const Icon(Icons.attach_file, size: 20),
            onPressed: onPick,
          ),
        ],
      ]),
    );
  }
}

/// An expense after it has been recorded, and the receipt behind it.
///
/// Read-only on purpose. A posted expense has a journal entry against
/// it, and letting the amount be edited here would put the two out of
/// step silently — correcting one means reversing it, which is a
/// different verb and a different screen. What was missing was not
/// editing but *evidence*: the paper the expense came from, which an
/// auditor asks for and which had nowhere to be filed.
class _ExpenseDetail extends ConsumerWidget {
  const _ExpenseDetail({required this.expense});

  final Map<String, dynamic> expense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = expense['accounts'] as Map?;
    final no = expense['expense_no']?.toString() ?? 'Expense';

    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(child: Text(value)),
          ]),
        );

    return AlertDialog(
      title: Row(children: [
        Expanded(child: Text(no)),
        StatusChip(expense['status']?.toString() ?? 'draft', compact: true),
      ]),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              line('Description', expense['description']?.toString() ?? '—'),
              line(
                'Paid to',
                (expense['contacts'] as Map?)?['name']?.toString() ?? '—',
              ),
              line('Date', Fmt.date(Fmt.parseDate(expense['expense_date']))),
              // A split expense's header account is only its largest
              // line, so showing it alone would be a quarter of the
              // truth. The lines replace it when there are any.
              ...switch (ref.watch(
                  expenseSplitProvider('${expense['id']}')).valueOrNull) {
                final List<Map<String, dynamic>> split
                    when split.isNotEmpty => [
                    for (final l in split)
                      line(l['line_no'] == 1 ? 'Split' : '',
                          '${l['account_code']} ${l['account_name']}'
                          ' · ${Fmt.money(Fmt.toDouble(l['amount']))}'
                          '${l['description'] == null ? '' : ' · ${l['description']}'}'),
                  ],
                _ => [
                    if (account != null)
                      line('Account', '${account['code']} ${account['name']}'),
                  ],
              },
              if (expense['reference'] != null &&
                  '${expense['reference']}'.trim().isNotEmpty)
                line('Reference', '${expense['reference']}'),
              line('Amount', Fmt.money(Fmt.toDouble(expense['total_amount']))),
              const SizedBox(height: Space.md),
              AttachmentsCard(
                table: 'expenses',
                recordId: '${expense['id']}',
                title: 'Receipt',
                subtitle: 'The paper this expense came from.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        // The paper an SME staples the receipt to, and the one an
        // auditor asks for when a cash payment has no supplier invoice
        // behind it. Offered on a posted expense only: a voucher for
        // something not in the books is a document that says the
        // company paid when it has not decided that yet.
        if ('${expense['status']}' == 'posted')
          TextButton.icon(
            onPressed: () => _printVoucher(context, ref),
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Payment voucher'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Future<void> _printVoucher(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final org = ref.read(currentOrgProvider).valueOrNull;
    final repo = ref.read(repoProvider);
    if (org == null || repo == null) return;
    try {
      // Re-read rather than print what the list is holding: the list
      // deliberately fetches neither the payee nor the bank account,
      // and a voucher missing both is not a voucher.
      final full = await repo.expenseForVoucher('${expense['id']}');
      if (full == null) return;
      final bytes = await buildExpenseVoucherPdf(
        org: org,
        expense: full,
        logo: await ref.read(orgLogoProvider.future),
        mode: org.usesPreprintedLetterhead
            ? LetterheadMode.stationery
            : LetterheadMode.printed,
      );
      final name =
          'voucher-${full['expense_no'] ?? full['id']}.pdf'
              .replaceAll(RegExp(r'[^A-Za-z0-9.\-]+'), '-');
      final saved = await saveBytesFile(name, 'application/pdf', bytes);
      if (!saved) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Vouchers are downloaded from the web app; open it in a '
              'browser to save the file.',
            ),
          ),
        );
      }
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
  }
}
