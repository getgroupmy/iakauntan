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
  const ReconciliationScreen({super.key});

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
      _bankAccountId = banks.first['id'] as String;
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
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
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _PasteDialog(),
    );
    if (text == null || !mounted) return;

    final parsed = parseStatement(text);
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

class _PasteDialog extends StatefulWidget {
  const _PasteDialog();

  @override
  State<_PasteDialog> createState() => _PasteDialogState();
}

class _PasteDialogState extends State<_PasteDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _text.text.trim().isEmpty ? null : parseStatement(_text.text);

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
                'Paste the CSV your bank exports, including its header row. '
                'Columns are found by name, so the order does not matter. '
                'Lines already imported are skipped.',
                style: Theme.of(context).textTheme.bodySmall,
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
              : () => Navigator.pop(context, _text.text),
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
