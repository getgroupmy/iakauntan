import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Journals that post themselves.
///
/// The runner behind this has been on the nightly cron since 0058 and
/// there has never been a way to create a template for it, so it has
/// been working perfectly on an empty table. This is the missing half.
class RecurringScreen extends ConsumerWidget {
  const RecurringScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final templates = ref.watch(recurringJournalsProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Recurring journals'),
        actions: [
          if (canPost) ...[
            IconButton(
              tooltip: 'Run anything due now',
              icon: const Icon(Icons.play_arrow_outlined),
              onPressed: () => _runNow(context, ref),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: FilledButton.icon(
                onPressed: () => _edit(context, ref, null),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
              ),
            ),
          ],
        ],
      ),
      body: AsyncView(
        value: templates,
        onRetry: () => ref.invalidate(recurringJournalsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.repeat,
                title: 'Nothing recurring',
                message: 'Rent, depreciation of a lease, a monthly '
                    'management fee — anything the books post on a '
                    'schedule rather than because something happened.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(Space.lg),
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _TemplateTile(
                  template: list[i],
                  onTap: canPost ? () => _edit(context, ref, list[i]) : null,
                ),
              ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? template,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RecurringEditor(template: template),
    );
    if (saved == true) ref.invalidate(recurringJournalsProvider);
  }

  Future<void> _runNow(BuildContext context, WidgetRef ref) async {
    int? count;
    final ok = await runWithFeedback(
      context,
      action: () async {
        count = await ref.read(repoProvider)!.runRecurringJournals();
      },
      successMessage: 'Run complete',
      pendingMessage: 'Running…',
    );
    if (!ok || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(count == 0
          ? 'Nothing was due.'
          : '$count posted. The nightly job would have caught these anyway.'),
    ));
    ref.invalidate(recurringJournalsProvider);
    refreshLedgerData(ref);
  }
}

class _TemplateTile extends StatelessWidget {
  const _TemplateTile({required this.template, this.onTap});

  final Map<String, dynamic> template;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = template['is_active'] == true;
    final error = template['last_error']?.toString();
    final next = Fmt.parseDate(template['next_run_date']);

    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Expanded(child: Text(template['name']?.toString() ?? 'Untitled')),
          if (!active) const StatusChip('void', compact: true),
          if (template['auto_post'] != true)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: StatusChip('draft', compact: true),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_schedule(template)} · '
            '${next == null ? 'not scheduled' : 'next ${Fmt.date(next)}'}'
            '${template['last_run_date'] == null ? '' : ' · last ${Fmt.date(Fmt.parseDate(template['last_run_date']))}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          // The runner records why it could not post and leaves the date
          // alone so it retries. Without showing this, a template that
          // has failed every night for a month looks like one that has
          // simply not come round yet.
          if (error != null)
            Text(
              'Last run failed: $error',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.colors.danger),
            ),
        ],
      ),
    );
  }

  static String _schedule(Map<String, dynamic> t) {
    final every = (t['interval_count'] as num?)?.toInt() ?? 1;
    final unit = t['frequency']?.toString() ?? 'monthly';
    final noun = switch (unit) {
      'daily' => 'day',
      'weekly' => 'week',
      'quarterly' => 'quarter',
      'yearly' => 'year',
      _ => 'month',
    };
    return every == 1 ? 'Every $noun' : 'Every $every ${noun}s';
  }
}

/// One template: when it runs, and the journal it posts.
class _RecurringEditor extends ConsumerStatefulWidget {
  const _RecurringEditor({this.template});

  final Map<String, dynamic>? template;

  @override
  ConsumerState<_RecurringEditor> createState() => _RecurringEditorState();
}

class _RecurringEditorState extends ConsumerState<_RecurringEditor> {
  final _name = TextEditingController();
  final _interval = TextEditingController(text: '1');

  String _frequency = 'monthly';
  DateTime _start = DateTime.now();
  bool _autoPost = true;
  bool _active = true;
  bool _saving = false;

  /// The journal itself: account, debit, credit.
  final List<({String? accountId, double debit, double credit})> _lines = [
    (accountId: null, debit: 0, credit: 0),
    (accountId: null, debit: 0, credit: 0),
  ];

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    if (t != null) {
      _name.text = t['name']?.toString() ?? '';
      _interval.text = '${(t['interval_count'] as num?)?.toInt() ?? 1}';
      _frequency = t['frequency']?.toString() ?? 'monthly';
      _start = Fmt.parseDate(t['next_run_date']) ??
          Fmt.parseDate(t['start_date']) ??
          DateTime.now();
      _autoPost = t['auto_post'] == true;
      _active = t['is_active'] == true;

      final raw = (t['template'] as Map?)?['lines'] as List? ?? const [];
      if (raw.isNotEmpty) {
        _lines
          ..clear()
          ..addAll([
            for (final l in raw)
              (
                accountId: (l as Map)['account_id']?.toString(),
                debit: Fmt.toDouble(l['debit']),
                credit: Fmt.toDouble(l['credit']),
              ),
          ]);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _interval.dispose();
    super.dispose();
  }

  double get _debits => _lines.fold(0, (s, l) => s + l.debit);
  double get _credits => _lines.fold(0, (s, l) => s + l.credit);
  bool get _balances => (_debits - _credits).abs() < 0.005 && _debits > 0;

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(accountsProvider).value ?? const <Account>[];

    return AlertDialog(
      title: Text(widget.template == null ? 'New recurring journal' : _name.text),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'Monthly office rent',
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _frequency,
                    decoration: const InputDecoration(labelText: 'Every'),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Day')),
                      DropdownMenuItem(value: 'weekly', child: Text('Week')),
                      DropdownMenuItem(value: 'monthly', child: Text('Month')),
                      DropdownMenuItem(value: 'quarterly', child: Text('Quarter')),
                      DropdownMenuItem(value: 'yearly', child: Text('Year')),
                    ],
                    onChanged: (v) => setState(() => _frequency = v ?? 'monthly'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _interval,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Interval'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _start,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _start = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Next run',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(Fmt.date(_start)),
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoPost,
                onChanged: (v) => setState(() => _autoPost = v),
                title: const Text('Post automatically'),
                subtitle: Text(
                  _autoPost
                      ? 'The journal is posted on each run.'
                      : 'The schedule advances but nothing is posted — '
                          'useful for a reminder rather than an entry.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _active,
                onChanged: (v) => setState(() => _active = v),
                title: const Text('Active'),
              ),
              const Divider(height: 24),
              const SectionHeader('The journal'),
              for (var i = 0; i < _lines.length; i++)
                _JournalLine(
                  accounts: accounts,
                  line: _lines[i],
                  onChanged: (l) => setState(() => _lines[i] = l),
                  onRemove: _lines.length > 2
                      ? () => setState(() => _lines.removeAt(i))
                      : null,
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _lines
                      .add((accountId: null, debit: 0, credit: 0))),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add line'),
                ),
              ),
              const SizedBox(height: 8),
              // Said here rather than left to the database, because the
              // database only finds out on the night it runs and reports
              // it into last_error where nobody is looking.
              Row(children: [
                Expanded(
                  child: Text(
                    _balances
                        ? 'Balanced'
                        : _debits == 0
                            ? 'Enter the journal'
                            : 'Out by ${Fmt.money((_debits - _credits).abs())}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _balances
                          ? context.colors.success
                          : context.colors.warning,
                    ),
                  ),
                ),
                Text('${Fmt.money(_debits)} / ${Fmt.money(_credits)}',
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
          onPressed: _saving || !_balances ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Give the template a name.')));
      return;
    }
    if (_lines.any((l) => l.accountId == null && (l.debit != 0 || l.credit != 0))) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Every line with an amount needs an account.')));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveRecurringJournal(
            id: widget.template?['id'] as String?,
            name: _name.text.trim(),
            frequency: _frequency,
            intervalCount: int.tryParse(_interval.text.trim()) ?? 1,
            nextRun: _start,
            autoPost: _autoPost,
            isActive: _active,
            lines: [
              for (final l in _lines)
                if (l.accountId != null && (l.debit != 0 || l.credit != 0))
                  {
                    'account_id': l.accountId,
                    'debit': l.debit,
                    'credit': l.credit,
                  },
            ],
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _JournalLine extends StatelessWidget {
  const _JournalLine({
    required this.accounts,
    required this.line,
    required this.onChanged,
    this.onRemove,
  });

  final List<Account> accounts;
  final ({String? accountId, double debit, double credit}) line;
  final ValueChanged<({String? accountId, double debit, double credit})>
      onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              value: line.accountId,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final a in accounts)
                  if (!a.isGroup)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text('${a.code} ${a.name}',
                          overflow: TextOverflow.ellipsis),
                    ),
              ],
              onChanged: (v) => onChanged((
                accountId: v,
                debit: line.debit,
                credit: line.credit,
              )),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: TextFormField(
              initialValue: line.debit == 0 ? '' : line.debit.toStringAsFixed(2),
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, hintText: 'Dr'),
              onChanged: (v) => onChanged((
                accountId: line.accountId,
                debit: double.tryParse(v) ?? 0,
                credit: line.credit,
              )),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: TextFormField(
              initialValue:
                  line.credit == 0 ? '' : line.credit.toStringAsFixed(2),
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, hintText: 'Cr'),
              onChanged: (v) => onChanged((
                accountId: line.accountId,
                debit: line.debit,
                credit: double.tryParse(v) ?? 0,
              )),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
