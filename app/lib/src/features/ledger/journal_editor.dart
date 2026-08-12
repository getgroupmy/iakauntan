import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// A journal somebody writes by hand.
///
/// Everything else in this system reaches the ledger behind a document —
/// an invoice, a payroll run, a depreciation charge. This is the one
/// entry that is its own document: the accrual, the prepayment, the
/// reclassification, the correction to an opening balance. Without it a
/// bookkeeper has nowhere to put anything the automated paths do not
/// produce, which is most of what a month end consists of.
///
/// Returns the new journal's id, or null if nothing was posted.
Future<String?> showJournalEditor(BuildContext context, WidgetRef ref) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _JournalEditor(),
  );
}

/// One line of a hand-written journal.
class JournalDraft {
  JournalDraft({
    this.accountId,
    this.description = '',
    this.debit = 0,
    this.credit = 0,
    this.projectCode,
  });

  String? accountId;
  String description;
  double debit;
  double credit;

  /// Per line, not per journal: the entry that moves a cost from one job
  /// to another is a single journal touching two projects, and a header
  /// field could not express it.
  String? projectCode;

  bool get isEmpty => accountId == null && debit == 0 && credit == 0;

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        'description': description.trim().isEmpty ? null : description.trim(),
        'debit': debit,
        'credit': credit,
        if (projectCode != null) 'project_code': projectCode,
      };
}

/// What is wrong with a set of lines, or null if nothing is.
///
/// The database refuses an unbalanced journal with SQLSTATE 23514 and it
/// is right to, but a bookkeeper typing sixteen lines should be told
/// which way it is out while they are still typing.
String? journalProblem(List<JournalDraft> lines) {
  final used = lines.where((l) => !l.isEmpty).toList();
  if (used.isEmpty) return 'Enter at least two lines.';

  for (final l in used) {
    if (l.accountId == null) return 'Every line needs an account.';
    if (l.debit < 0 || l.credit < 0) {
      return 'Amounts are positive; use the other column to reverse a line.';
    }
    if (l.debit > 0 && l.credit > 0) {
      return 'A line is a debit or a credit, not both.';
    }
    if (l.debit == 0 && l.credit == 0) return 'Every line needs an amount.';
  }

  final debits = used.fold<double>(0, (s, l) => s + l.debit);
  final credits = used.fold<double>(0, (s, l) => s + l.credit);
  if ((debits - credits).abs() >= 0.005) {
    return 'Out by ${Fmt.money((debits - credits).abs())}.';
  }
  if (debits == 0) return 'The journal has no value.';
  return null;
}

class _JournalEditor extends ConsumerStatefulWidget {
  const _JournalEditor();

  @override
  ConsumerState<_JournalEditor> createState() => _JournalEditorState();
}

class _JournalEditorState extends ConsumerState<_JournalEditor> {
  final _description = TextEditingController();
  final _reference = TextEditingController();

  DateTime _date = DateTime.now();
  bool _saving = false;

  final List<JournalDraft> _lines = [JournalDraft(), JournalDraft()];

  @override
  void dispose() {
    _description.dispose();
    _reference.dispose();
    super.dispose();
  }

  double get _debits => _lines.fold(0, (s, l) => s + l.debit);
  double get _credits => _lines.fold(0, (s, l) => s + l.credit);

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];
    final projects = ref.watch(projectsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final problem = journalProblem(_lines);
    final narrow = MediaQuery.sizeOf(context).width < 700;

    return AlertDialog(
      title: const Text('New journal'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
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
                  flex: 2,
                  child: TextField(
                    controller: _description,
                    decoration: const InputDecoration(
                      labelText: 'Description *',
                      hintText: 'Accrue December electricity',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _reference,
                    decoration: const InputDecoration(labelText: 'Reference'),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              for (var i = 0; i < _lines.length; i++)
                _JournalLineRow(
                  key: ObjectKey(_lines[i]),
                  line: _lines[i],
                  accounts: accounts,
                  projects: projects,
                  narrow: narrow,
                  onChanged: () => setState(() {}),
                  onRemove: _lines.length > 2
                      ? () => setState(() => _lines.removeAt(i))
                      : null,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _lines.add(JournalDraft())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add line'),
                ),
              ),
              const Divider(height: 24),
              Row(children: [
                Expanded(
                  child: Text(
                    problem ?? 'Balanced',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: problem == null
                          ? context.colors.success
                          : context.colors.warning,
                    ),
                  ),
                ),
                Text('${Fmt.money(_debits)}  /  ${Fmt.money(_credits)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ]),
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
          onPressed: _saving || problem != null ? null : _post,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Post'),
        ),
      ],
    );
  }

  Future<void> _post() async {
    if (_description.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Give the journal a description — it is what the '
            'ledger will show.'),
      ));
      return;
    }

    // No draft state and no confirmation step: a manual journal posts
    // straight to the ledger, which is what makes it useful and what
    // makes `reverse_gl_entry` the way to undo one.
    setState(() => _saving = true);
    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref.read(repoProvider)!.createJournal(
              date: _date,
              description: _description.text.trim(),
              reference: _reference.text,
              lines: [
                for (final l in _lines)
                  if (!l.isEmpty) l.toJson(),
              ],
            );
      },
      successMessage: 'Journal posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, id);
  }
}

class _JournalLineRow extends StatefulWidget {
  const _JournalLineRow({
    super.key,
    required this.line,
    required this.accounts,
    required this.projects,
    required this.narrow,
    required this.onChanged,
    this.onRemove,
  });

  final JournalDraft line;
  final List<Account> accounts;
  final List<Map<String, dynamic>> projects;
  final bool narrow;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  State<_JournalLineRow> createState() => _JournalLineRowState();
}

class _JournalLineRowState extends State<_JournalLineRow> {
  late final _description =
      TextEditingController(text: widget.line.description);
  late final _debit = TextEditingController(
      text: widget.line.debit == 0 ? '' : widget.line.debit.toStringAsFixed(2));
  late final _credit = TextEditingController(
      text: widget.line.credit == 0 ? '' : widget.line.credit.toStringAsFixed(2));

  @override
  void dispose() {
    _description.dispose();
    _debit.dispose();
    _credit.dispose();
    super.dispose();
  }

  /// A line is a debit or a credit. Typing in one column empties the
  /// other rather than letting both stand, because a line with both is
  /// almost always a mistyped column and the database would take it.
  void _setDebit(String v) {
    widget.line.debit = double.tryParse(v) ?? 0;
    if (widget.line.debit > 0 && widget.line.credit > 0) {
      widget.line.credit = 0;
      _credit.text = '';
    }
    widget.onChanged();
  }

  void _setCredit(String v) {
    widget.line.credit = double.tryParse(v) ?? 0;
    if (widget.line.credit > 0 && widget.line.debit > 0) {
      widget.line.debit = 0;
      _debit.text = '';
    }
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final account = DropdownButtonFormField<String>(
      value: widget.line.accountId,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true, labelText: 'Account'),
      items: [
        for (final a in widget.accounts)
          if (!a.isGroup)
            DropdownMenuItem(
              value: a.id,
              child:
                  Text('${a.code} ${a.name}', overflow: TextOverflow.ellipsis),
            ),
      ],
      onChanged: (v) {
        widget.line.accountId = v;
        widget.onChanged();
      },
    );

    final description = TextField(
      controller: _description,
      decoration: const InputDecoration(isDense: true, labelText: 'Narrative'),
      onChanged: (v) => widget.line.description = v,
    );

    // Only once projects exist: a dropdown with nothing in it on every
    // line of every journal is a control that teaches people to ignore
    // controls.
    final project = widget.projects.isEmpty
        ? null
        : DropdownButtonFormField<String?>(
            value: widget.line.projectCode,
            isExpanded: true,
            decoration:
                const InputDecoration(isDense: true, labelText: 'Project'),
            items: [
              const DropdownMenuItem(value: null, child: Text('None')),
              for (final p in widget.projects)
                DropdownMenuItem(
                  value: p['code'] as String,
                  child: Text('${p['code']} · ${p['name']}',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              widget.line.projectCode = v;
              widget.onChanged();
            },
          );

    final debit = TextField(
      controller: _debit,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(isDense: true, labelText: 'Debit'),
      onChanged: _setDebit,
    );

    final credit = TextField(
      controller: _credit,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(isDense: true, labelText: 'Credit'),
      onChanged: _setCredit,
    );

    if (widget.narrow) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          children: [
            Row(children: [
              Expanded(child: account),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: widget.onRemove,
              ),
            ]),
            const SizedBox(height: 8),
            description,
            if (project != null) ...[
              const SizedBox(height: 8),
              project,
            ],
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: debit),
              const SizedBox(width: 8),
              Expanded(child: credit),
            ]),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: account),
          const SizedBox(width: 8),
          Expanded(flex: project == null ? 3 : 2, child: description),
          if (project != null) ...[
            const SizedBox(width: 8),
            Expanded(flex: 2, child: project),
          ],
          const SizedBox(width: 8),
          SizedBox(width: 110, child: debit),
          const SizedBox(width: 8),
          SizedBox(width: 110, child: credit),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }
}
