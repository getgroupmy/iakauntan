import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'book_balance.dart';
import 'new_bank_account_dialog.dart';
import 'reconciliation_history_dialog.dart';
import '../shared/receipt_capture.dart';
import '../shared/scan_intake.dart';
import '../shared/scan_runner.dart';
import '../smartscan/scan_destination.dart';
import 'statement_import.dart';
import 'transfer_dialog.dart';
import 'transfers_history_dialog.dart';

/// Reconciling a bank account against its statement.
///
/// The question is not whether the two balances agree — they never do.
/// It is whether every difference is accounted for: book balance, less
/// what the bank has not seen yet, should equal the statement. What is
/// left over is the number that matters, and it is the one shown
/// largest.
class ReconciliationScreen extends ConsumerStatefulWidget {
  const ReconciliationScreen({
    super.key,
    this.openAccountId,
    this.openImport = false,
  });

  /// Which account to open on, where the caller knows. `0710`-era.
  ///
  /// The Bank statements screen sends it: somebody who pressed Upload
  /// beside Maybank means Maybank, and landing on whichever account
  /// sorts first is a statement imported into the wrong one.
  final String? openAccountId;

  /// Open the import straight away.
  ///
  /// So "Upload a statement" is one press rather than a press, a
  /// screen, and an unlabelled icon. The import itself stays here --
  /// the parse, the balance chain, the duplicate skip and the closing
  /// balance are all on this screen and a second copy of them would be
  /// a second set of answers to drift.
  final bool openImport;

  @override
  ConsumerState<ReconciliationScreen> createState() =>
      _ReconciliationScreenState();
}

class _ReconciliationScreenState extends ConsumerState<ReconciliationScreen> {
  final _statementBalance = TextEditingController(text: '0');

  String? _bankAccountId;
  late DateTime _asAt =
      DateTime(DateTime.now().year, DateTime.now().month, 0);

  Map<String, dynamic>? _status;
  List<Map<String, dynamic>> _lines = const [];
  bool _loading = false;

  @override
  void dispose() {
    _statementBalance.dispose();
    super.dispose();
  }

  double get _balance => double.tryParse(_statementBalance.text.trim()) ?? 0;

  Future<void> _refresh() async {
    final id = _bankAccountId;
    if (id == null) return;
    setState(() => _loading = true);
    try {
      final repo = ref.read(repoProvider)!;
      final status = await repo.bankReconciliationStatus(
        bankAccountId: id,
        asAt: _asAt,
        statementBalance: _balance,
      );
      final lines = await repo.bankStatementLines(id, onlyOpen: true);
      if (!mounted) return;
      setState(() {
        _status = status;
        _lines = lines;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final banks = ref.watch(bankAccountsProvider).value ?? const [];
    final canPost = ref.watch(canPostProvider);

    // Seed the account once the list arrives, so the screen is useful
    // without a first click.
    if (_bankAccountId == null && banks.isNotEmpty) {
      // The one the caller asked for, where it is still a real account
      // of this company's. A stale id in a link opens the first one
      // rather than an empty screen.
      final asked = widget.openAccountId;
      _bankAccountId = banks.any((b) => b['id'] == asked)
          ? asked
          : banks.first['id'] as String;
      // Once, and only because `_bankAccountId` was just set: this
      // whole block is inside `build`, which runs again on every
      // rebuild, and the condition above is the only thing stopping
      // the import dialog from reopening behind itself.
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _refresh();
        if (!mounted || !widget.openImport) return;
        await _import();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bank reconciliation'),
        actions: [
          // A transfer between the company's own accounts belongs here:
          // both ends of it turn up on a statement, and this is the
          // screen where somebody is looking at one.
          if (canPost)
            IconButton(
              tooltip: 'Transfer between accounts',
              icon: const Icon(Icons.swap_horiz),
              onPressed: () async {
                final done = await showTransferDialog(context);
                if (done == true) _refresh();
              },
            ),
          // The register of them, which was written and never read: a
          // transfer, once made, left the app entirely.
          IconButton(
            key: const ValueKey('transfers-history'),
            tooltip: 'Transfers made',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () async {
              if (await showTransfersHistory(context)) await _refresh();
            },
          ),
          if (canPost)
            IconButton(
              tooltip: 'Import statement',
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: _bankAccountId == null ? null : _import,
            ),
          // The register, which until 0157 was written and never read.
          if (ref.watch(canReadLedgerProvider))
            IconButton(
              key: const ValueKey('reconciliation-history'),
              tooltip: 'Reconciliation history',
              icon: const Icon(Icons.history),
              onPressed: _bankAccountId == null
                  ? null
                  : () async {
                      final changed = await showReconciliationHistory(
                        context,
                        bankAccountId: _bankAccountId!,
                      );
                      if (changed == true) await _refresh();
                    },
            ),
          // What the account itself says it holds, and the way to
          // rebuild it. `current_balance` is a running total kept by
          // twenty-three statements across the migrations, and
          // `resync_bank_balance` — asserted since 0175 and called by
          // nothing — is what puts it back in step with the ledger.
          IconButton(
            key: const ValueKey('book-balance'),
            tooltip: 'Book balance',
            icon: const Icon(Icons.account_balance_outlined),
            onPressed: _bankAccountId == null
                ? null
                : () async {
                    final account = banks.firstWhere(
                      (b) => b['id'] == _bankAccountId,
                      orElse: () => const <String, dynamic>{},
                    );
                    if (account.isEmpty) return;
                    if (await showBookBalance(context, account: account)) {
                      await _refresh();
                    }
                  },
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: banks.isEmpty
          ? const EmptyState(
              icon: Icons.account_balance_outlined,
              title: 'No bank accounts',
              message: 'Add a bank account in Settings before reconciling.',
            )
          : SingleChildScrollView(
              child: PageBody(
                maxWidth: 900,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Controls(
                      banks: banks,
                      bankAccountId: _bankAccountId,
                      asAt: _asAt,
                      balance: _statementBalance,
                      onBank: (v) {
                        setState(() => _bankAccountId = v);
                        _refresh();
                      },
                      onDate: (d) {
                        setState(() => _asAt = d);
                        _refresh();
                      },
                      onBalance: _refresh,
                    ),
                    const SizedBox(height: 16),
                    if (_loading) const LinearProgressIndicator(),
                    if (_status != null) ...[
                      _StatusCard(status: _status!),
                      const SizedBox(height: 16),
                      if (canPost)
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _complete,
                            icon: const Icon(Icons.check, size: 18),
                            label: const Text('Complete reconciliation'),
                          ),
                        ),
                      const SizedBox(height: 16),
                    ],
                    _LinesCard(
                      lines: _lines,
                      canPost: canPost,
                      onMatch: _match,
                      onUnmatch: _unmatch,
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _import() async {
    // A parse rather than the raw text, since `0683`: the dialog now
    // has three sources — a paste, a file, and a photograph — and only
    // the first two are text. Handing back what was READ lets all
    // three arrive the same way, and drops a second parse of the same
    // paste on the way out.
    final parsed = await showDialog<StatementParse>(
      context: context,
      builder: (_) => const _PasteDialog(),
    );
    if (parsed == null || !mounted) return;

    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(parsed.problems.join(' ')),
      ));
      return;
    }

    final result = await ref.read(repoProvider)!.importBankTransactions(
          _bankAccountId!,
          [for (final r in parsed.rows) r.toJson()],
        );

    if (!mounted) return;
    // Skipped lines and unreadable lines are both reported. A statement
    // that half-imports quietly reconciles to the wrong number.
    final checks = (result['balance_checks'] as num? ?? 0).toInt();
    final parts = <String>[
      '${result['imported']} imported',
      if ((result['skipped'] as num? ?? 0) > 0)
        '${result['skipped']} already there',
      // Worth saying out loud. It is the difference between a paste
      // that looks right and one the statement's own arithmetic agrees
      // with, and somebody who pastes a balance column deserves to know
      // the check happened rather than to assume it.
      if (checks > 0) 'balance follows on $checks lines',
      if (parsed.problems.isNotEmpty)
        '${parsed.problems.length} could not be read',
    ];

    // The figure the difference gets measured against, taken from the
    // bank instead of typed. `bank_reconciliation_status` subtracts the
    // statement balance from the books, so a slip in it is a difference
    // that is not there — and the search for it goes through the lines,
    // which are fine.
    final closing = (result['closing_balance'] as num?)?.toDouble();
    final closingDate = result['closing_date'] as String?;
    if (closing != null) {
      _statementBalance.text = closing.toStringAsFixed(2);
      final on = DateTime.tryParse(closingDate ?? '');
      if (on != null) _asAt = on;
      parts.add('closing ${Fmt.money(closing)}'
          '${on == null ? '' : ' at ${Fmt.date(on)}'}');
    }

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    await _refresh();
  }

  Future<void> _match(Map<String, dynamic> line) async {
    final repo = ref.read(repoProvider)!;
    final suggestions = await repo.suggestBankMatches(line['id'] as String);
    if (!mounted) return;

    if (suggestions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nothing posted matches that amount and date. '
            'Record the receipt or payment first.'),
      ));
      return;
    }

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _SuggestionDialog(line: line, suggestions: suggestions),
    );
    if (chosen == null || !mounted) return;

    final ok = await runWithFeedback(
      context,
      action: () => repo.matchBankTransaction(
        transactionId: line['id'] as String,
        sourceTable: chosen['source_table'] as String,
        sourceId: chosen['source_id'] as String,
      ),
      successMessage: 'Matched',
    );
    if (ok) await _refresh();
  }

  Future<void> _unmatch(Map<String, dynamic> line) async {
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.unmatchBankTransaction(line['id'] as String),
      successMessage: 'Unmatched',
    );
    if (ok) await _refresh();
  }

  Future<void> _complete() async {
    final ok = await confirm(
      context,
      title: 'Complete the reconciliation?',
      message: 'The matched lines are locked to this reconciliation and '
          'cannot be unpicked afterwards.',
      confirmLabel: 'Complete',
    );
    if (!ok || !mounted) return;

    final done = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.completeBankReconciliation(
            bankAccountId: _bankAccountId!,
            statementDate: _asAt,
            statementBalance: _balance,
          ),
      successMessage: 'Reconciled to ${Fmt.date(_asAt)}',
    );
    if (done) await _refresh();
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.banks,
    required this.bankAccountId,
    required this.asAt,
    required this.balance,
    required this.onBank,
    required this.onDate,
    required this.onBalance,
  });

  final List<Map<String, dynamic>> banks;
  final String? bankAccountId;
  final DateTime asAt;
  final TextEditingController balance;
  final ValueChanged<String> onBank;
  final ValueChanged<DateTime> onDate;
  final VoidCallback onBalance;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final fields = <Widget>[
      SearchablePicker<String>(
        options: bankPickerOptions(banks),
        createLabel: 'Add bank account',
        // 0529 made this list writable for the first
        // time. Until then a company that opened a
        // second account had nowhere in the product to
        // say so.
        onCreate: (typed) =>
            createBankAccountFromPicker(context, typed: typed),
        value: bankAccountId,
        label: 'Account',
        onChanged: (v) => v == null ? null : onBank(v),
      ),
      InkWell(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: asAt,
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (picked != null) onDate(picked);
        },
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Statement date',
            suffixIcon: Icon(Icons.calendar_today, size: 18),
          ),
          child: Text(Fmt.date(asAt)),
        ),
      ),
      TextField(
        controller: balance,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onSubmitted: (_) => onBalance(),
        onEditingComplete: onBalance,
        decoration: const InputDecoration(
          labelText: 'Closing balance on the statement',
          prefixText: 'RM ',
        ),
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: narrow
            ? Column(
                children: [
                  for (final f in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: f,
                    ),
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 2, child: fields[0]),
                  const SizedBox(width: 14),
                  Expanded(child: fields[1]),
                  const SizedBox(width: 14),
                  Expanded(flex: 2, child: fields[2]),
                ],
              ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final Map<String, dynamic> status;

  @override
  Widget build(BuildContext context) {
    final difference = Fmt.toDouble(status['difference']);
    final balanced = difference.abs() < 0.005;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Where it stands'),
            _Line(label: 'Book balance', value: Fmt.toDouble(status['book_balance'])),
            _Line(
              label: 'Less what the bank has not seen',
              value: -Fmt.toDouble(status['unpresented']),
              caption: 'Unpresented cheques and deposits in transit',
            ),
            const Divider(height: 20),
            _Line(
              label: 'Statement should read',
              value: Fmt.toDouble(status['expected_statement']),
            ),
            _Line(
              label: 'Statement says',
              value: Fmt.toDouble(status['statement_balance']),
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    balanced ? 'Reconciled' : 'Out by',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                ),
                if (!balanced)
                  Money(
                    difference,
                    bold: true,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(color: context.colors.danger),
                  )
                else
                  Icon(Icons.check_circle, color: context.colors.success),
              ],
            ),
            if (!balanced)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${status['unmatched_lines']} statement lines are still '
                  'unmatched. A difference is a line nobody has matched, a '
                  'payment entered twice, or a charge the books have not '
                  'heard of.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.caption});

  final String label;
  final double value;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (caption != null)
                  Text(caption!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Money(value),
        ],
      ),
    );
  }
}

class _LinesCard extends StatelessWidget {
  const _LinesCard({
    required this.lines,
    required this.canPost,
    required this.onMatch,
    required this.onUnmatch,
  });

  final List<Map<String, dynamic>> lines;
  final bool canPost;
  final ValueChanged<Map<String, dynamic>> onMatch;
  final ValueChanged<Map<String, dynamic>> onUnmatch;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Statement lines',
              subtitle: lines.isEmpty
                  ? null
                  : '${lines.where((l) => l['is_reconciled'] != true).length} '
                      'still to match',
            ),
            if (lines.isEmpty)
              Text(
                'Nothing imported yet for this account.',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              for (final line in lines)
                _LineTile(
                  line: line,
                  canPost: canPost,
                  onMatch: () => onMatch(line),
                  onUnmatch: () => onUnmatch(line),
                ),
          ],
        ),
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.canPost,
    required this.onMatch,
    required this.onUnmatch,
  });

  final Map<String, dynamic> line;
  final bool canPost;
  final VoidCallback onMatch;
  final VoidCallback onUnmatch;

  @override
  Widget build(BuildContext context) {
    final matched = line['is_reconciled'] == true;
    final amount = Fmt.toDouble(line['amount']);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        matched ? Icons.link : Icons.link_off,
        size: 20,
        color: matched ? context.colors.success : null,
      ),
      title: Text(line['description']?.toString() ?? 'Statement line'),
      subtitle: Text(
        '${Fmt.date(Fmt.parseDate(line['transaction_date']))}'
        '${line['reference'] == null ? '' : ' · ${line['reference']}'}'
        '${matched ? ' · matched to ${_niceTable(line['matched_table'])}' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Money(amount, bold: true),
          if (canPost)
            IconButton(
              tooltip: matched ? 'Unmatch' : 'Match',
              icon: Icon(matched ? Icons.close : Icons.search, size: 20),
              onPressed: matched ? onUnmatch : onMatch,
            ),
        ],
      ),
    );
  }

  static String _niceTable(Object? table) => switch (table) {
        'receipts' => 'a receipt',
        'purchase_payments' => 'a payment',
        'expenses' => 'an expense',
        'gl_entries' => 'a journal',
        _ => 'the books',
      };
}

class _PasteDialog extends ConsumerStatefulWidget {
  const _PasteDialog();

  @override
  ConsumerState<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends ConsumerState<_PasteDialog> {
  final _text = TextEditingController();
  String? _fileName;
  bool _reading = false;

  /// What a photograph was read as. `0683`.
  ///
  /// Held apart from `_text` rather than rendered into it: a scan comes
  /// back as rows, and turning them into CSV so the text box could hold
  /// them would mean formatting figures in order to parse them straight
  /// back — a round trip whose only possible effect is to lose one.
  StatementParse? _scanned;
  String? _scannedFrom;

  @override
  void initState() {
    super.initState();
    // Before the first frame, so a statement photographed in SmartScan
    // is already on screen when the import dialog opens rather than
    // appearing a moment later.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _takeParkedStatement();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// A statement is a file somebody downloaded. Making them open it in
  /// a text editor to copy it out is friction on the one step of
  /// reconciliation that is already tedious — and on an MT940, whose
  /// `.sta` or `.940` extension most editors will not open at all.
  ///
  /// No extension filter. Banks name these `.csv`, `.txt`, `.sta`,
  /// `.940` and `.TXT`, and a filter that misses one is a file the
  /// picker refuses to show for a reason nobody can see.
  ///
  /// ## And a PDF or a photograph is a statement too
  ///
  /// Asked for in one sentence: "bank statement should allow to upload
  /// pdf csv and also image not only csv". This button used to read
  /// whatever was picked with `readAsString`, so a PDF came back as a
  /// `FormatException` under "Could not read the file" — which reads as
  /// the statement being broken rather than the button being for
  /// something else. A PDF is what a bank emails and a photograph is
  /// what somebody has of a printed one, so between them they are most
  /// of the statements there are.
  ///
  /// ONE BUTTON, not two. Which importer a file belongs to is a
  /// question about the file, and `statementFileKind` answers it from
  /// the bytes — so nobody has to know that a CSV is free and a PDF
  /// costs a scan, and nobody picks the wrong button and pays for a
  /// reading of a file that could have been parsed here.
  Future<void> _openFile() async {
    setState(() => _reading = true);
    try {
      // Picked here rather than inside `captureAndRead`, because what
      // happens next depends on the bytes and asking twice would be a
      // second file dialog over a file already chosen.
      final file = await pickReceipt();
      if (file == null || !mounted) return;

      switch (statementFileKind(mimeType: file.mimeType, bytes: file.bytes)) {
        case StatementFile.scan:
          await _readStatement(file);
        case StatementFile.text:
          setState(() {
            _text.text = statementText(file.bytes)!;
            _fileName = file.name;
            // A file chosen now replaces a photograph taken earlier.
            // `statementPreview` gives the scan precedence, so leaving
            // it would import the old reading and say nothing.
            _scanned = null;
            _scannedFrom = null;
          });
        case StatementFile.neither:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'That is not a statement this can read. Online banking '
                'exports a CSV or an MT940; a PDF or a photograph of a '
                'printed statement works too. A spreadsheet has to be '
                'saved as CSV first.',
              ),
            ),
          );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not read the file: $e')));
    } finally {
      if (mounted) setState(() => _reading = false);
    }
  }

  /// A PDF or a photograph, through the reader and into the same rows.
  ///
  /// `captureAndRead` is the whole of AI SmartScan's intake and it is
  /// reused rather than reimplemented: it refuses a PDF BEFORE the
  /// upload where the chosen reader cannot take one, shows the progress
  /// modal, keeps the file when the reading fails, and files it against
  /// `bank_transactions` so the scan inbox — and the Bank statements
  /// screen — can say what became of it.
  ///
  /// The reading becomes rows through `scannedStatement`, which is the
  /// same function the parked-photograph path uses. Two ways in, one
  /// interpretation.
  Future<void> _readStatement(CapturedFile file) async {
    final staged = await captureAndRead(
      context,
      ref,
      source: CaptureSource.file,
      table: ScanDestination.bankStatement.table,
      picked: file,
      // We KNOW what this is. Somebody pressed Upload on a screen that
      // imports bank statements and nothing else, so the reader is
      // told rather than asked -- which is what puts `rows` in the
      // schema at all.
      target: ScanDestination.bankStatement.targetKey,
    );
    if (staged == null || !mounted) return;

    // The file's own text layer, where it has one, and the statement's
    // own date off it.
    //
    // This OUTRANKS the `document_date` the reader was asked for, and
    // the reason is the whole of `95e08146`: two RHB statements came
    // back read faultlessly, every line a day and a month, and
    // `document_date` null — so a hundred and two lines were thrown
    // away for want of a year that was printed on page one of the file
    // as selectable text. A model is asked and may decline. A text
    // layer is read.
    //
    // Null on a photograph, on a phone, and on a PDF with no text in
    // it, and in every one of those cases the reading is used exactly
    // as it was before.
    final text = await pdfTextLayer(file.bytes, file.mimeType);
    if (!mounted) return;
    final period = text == null ? null : statementPeriodFromText(text);

    final parse = scannedStatement(staged.read, period: period);
    if (parse.rows.isEmpty && parse.problems.isEmpty) {
      // THREE different failures wore one sentence, and the sentence
      // was wrong about all of them.
      //
      // It said a platform administrator had to set the reader up
      // under Kinds of document. `0683` set the statement's five
      // columns up years ago and they are live — so the one person who
      // saw this was sent to configure something that was already
      // configured, on the strength of a guess this screen had no
      // business making.
      //
      // The file is kept in every case: `0708` refuses to delete it
      // once anything is built from it, and nothing has been built
      // here.
      final read = staged.read;
      final String why;
      if (read == null) {
        why = 'That document could not be read at all. The file is '
            'kept — open it from AI SmartScan to try a different '
            'reader, or paste the statement in below.';
      } else if (read.foundNothing) {
        why = 'Nothing legible came back from that document. The file '
            'is kept. A photograph of a screen, or a scan at an angle, '
            'is usually the reason.';
      } else {
        // Read perfectly well, and read as something else. Which is
        // worth saying plainly rather than calling it unreadable.
        why = 'That was read, but not as a bank statement — no lines '
            'with a date and an amount came back. The file is kept. '
            'Check it is the statement itself rather than a summary or '
            'an advice slip.';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
      return;
    }
    setState(() {
      _scanned = parse;
      _scannedFrom = 'read from ${file.name}';
      // The box and the reading are two answers to one question and
      // `statementPreview` prefers the reading, so the box is cleared
      // rather than left holding something that will not be imported.
      _text.clear();
      _fileName = null;
    });
  }

  /// Whatever AI SmartScan photographed on the way here.
  ///
  /// The button that used to sit on this screen is gone: scanning is
  /// one door now, and a statement is one of the things that comes
  /// through it. What arrives here is the reading, parked because a
  /// route cannot carry an `OcrExtraction`.
  ///
  /// Taken exactly once, so coming back to this screen later does not
  /// re-apply a photograph somebody has already dealt with.
  void _takeParkedStatement() {
    final staged = ref.read(pendingStatementProvider.notifier).take();
    if (staged == null) return;
    final parse = scannedStatement(staged.read);
    if (parse.rows.isEmpty && parse.problems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing on that photograph read as statement lines. The '
            'reader has to be asked for them, which a platform '
            'administrator sets up under Kinds of document.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _scanned = parse;
      _scannedFrom = 'photographed';
    });
  }


  @override
  Widget build(BuildContext context) {
    // The photograph wins while it is there, because it is the thing
    // somebody just did. Clearing it is what the button below is for.
    final preview = statementPreview(_scanned, _text.text);

    return AlertDialog(
      title: const Text('Import statement'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Open the file your bank exports, or paste it. A CSV needs '
                'its header row — columns are found by name, so the order '
                'does not matter. An MT940, which is what corporate '
                'accounts get, is recognised on its own. A PDF or a '
                'photograph of a printed statement is read by AI '
                'SmartScan. Lines already imported are skipped.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('statement-open-file'),
                    onPressed: _reading ? null : _openFile,
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('Open a file'),
                    // The label stays short; what it accepts is in the
                    // sentence above, where there is room to say why a
                    // PDF takes longer than a CSV.
                  ),
                  if (_fileName != null) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _fileName!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                  if (_scannedFrom != null) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        _scannedFrom!,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    // Said, and undoable. A photograph overrides the
                    // text box while it is there, and somebody who
                    // photographed the wrong page needs a way back to
                    // the paste still sitting underneath it.
                    IconButton(
                      key: const ValueKey('statement-scan-clear'),
                      tooltip: 'Use the pasted text instead',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() {
                        _scanned = null;
                        _scannedFrom = null;
                      }),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                maxLines: 10,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'Date,Description,Amount\n'
                      '06/03/2026,Transfer in,1000.00',
                  border: OutlineInputBorder(),
                ),
              ),
              if (preview != null) ...[
                const SizedBox(height: 12),
                Text(
                  '${preview.rows.length} lines read'
                  '${preview.problems.isEmpty ? '' : ', ${preview.problems.length} could not be'}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: preview.problems.isEmpty
                        ? context.colors.success
                        : context.colors.warning,
                  ),
                ),
                for (final problem in preview.problems.take(5))
                  Text(problem, style: Theme.of(context).textTheme.bodySmall),
                // What was READ and then CHANGED, kept apart from what
                // could not be read: a sign put right off the running
                // balance is a line that WILL be imported, and burying
                // it in the problem list would read as a line that will
                // not. Every one of them is shown -- a correction
                // nobody was told about is a correction nobody can
                // disagree with.
                if (preview.notices.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // The heading used to read "N lines were corrected
                  // against the running balance", which was true when a
                  // sign repair was the only notice there was and
                  // became false the moment a second kind existed. It
                  // was wrong twice over: it named a cause that no
                  // longer applied to every notice, and it counted
                  // NOTICES as LINES -- a single notice covering
                  // fifty-five lines would have announced itself as
                  // one. Each notice below says its own count and its
                  // own cause, so the heading says neither.
                  Text(
                    noticesHeading(preview.notices.length),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: context.colors.warning,
                    ),
                  ),
                  for (final notice in preview.notices)
                    Text(notice, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: preview == null || preview.isEmpty
              ? null
              : () => Navigator.pop(context, preview),
          child: const Text('Import'),
        ),
      ],
    );
  }
}

class _SuggestionDialog extends StatelessWidget {
  const _SuggestionDialog({required this.line, required this.suggestions});

  final Map<String, dynamic> line;
  final List<Map<String, dynamic>> suggestions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Match to'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${line['description'] ?? 'Statement line'} · '
                '${Fmt.money(Fmt.toDouble(line['amount']))} on '
                '${Fmt.date(Fmt.parseDate(line['transaction_date']))}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              // Suggestions, not automatic matching: the wrong receipt
              // against the wrong deposit reconciles and leaves a
              // customer's account wrong, with nothing to catch it.
              for (final s in suggestions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${s['doc_no']} · ${s['contact_name'] ?? ''}'),
                  subtitle: Text(
                    '${Fmt.date(Fmt.parseDate(s['doc_date']))} · '
                    '${s['day_gap']} day${s['day_gap'] == 1 ? '' : 's'} apart',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: Money(Fmt.toDouble(s['amount'])),
                  onTap: () => Navigator.pop(context, s),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
