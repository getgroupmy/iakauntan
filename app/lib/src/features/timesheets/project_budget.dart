import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../contacts/new_contact_dialog.dart';

/// The budget nothing was compared against.
///
/// `projects.budget_amount` has been a column since `0088` and the word
/// appears nowhere else — because nothing writes *any* column of
/// `projects`. The table had no front door: a project had to be
/// inserted by hand by somebody with a database connection, while the
/// timesheet screen's empty state said "No projects yet" and offered no
/// way to make one.
///
/// `report_project_budget` puts the budget beside what the ledger has
/// against it. What is here is the reading of that: where a job stands,
/// and what a screen may offer to do about it.

/// Where a job stands against its budget.
enum BudgetState {
  /// No budget was set. Not the same as being exactly on budget, and
  /// said differently for that reason.
  none,

  /// Comfortably inside it.
  within,

  /// Inside it, but not by much. Eighty-five per cent is the point at
  /// which a job is worth a conversation rather than a glance — early
  /// enough to change something, late enough not to be noise.
  close,

  /// Spent more than was budgeted.
  over,
}

BudgetState budgetStateOf(Map<String, dynamic> row) {
  final percent = (row['percent_spent'] as num?)?.toDouble();
  if (percent == null) return BudgetState.none;
  if (percent > 100) return BudgetState.over;
  if (percent >= 85) return BudgetState.close;
  return BudgetState.within;
}

/// The sentence under a project's name.
String describeBudget(Map<String, dynamic> row) {
  final cost = (row['cost_to_date'] as num?) ?? 0;
  switch (budgetStateOf(row)) {
    case BudgetState.none:
      return '${Fmt.money(cost)} spent · no budget set';
    case BudgetState.over:
      final over = ((row['variance'] as num?) ?? 0).abs();
      return '${Fmt.money(cost)} spent · ${Fmt.money(over)} over budget';
    case BudgetState.close:
    case BudgetState.within:
      final left = (row['variance'] as num?) ?? 0;
      return '${Fmt.money(cost)} spent · ${Fmt.money(left)} left';
  }
}

/// How full the bar is, clamped so an overrun does not run off the end.
///
/// Clamped for the bar only. The number beside it is not clamped,
/// because a job at 240 per cent should say so.
double budgetFraction(Map<String, dynamic> row) {
  final percent = (row['percent_spent'] as num?)?.toDouble();
  if (percent == null) return 0;
  return (percent / 100).clamp(0.0, 1.0);
}

/// Why this job cannot be closed as it stands, or null when it can.
///
/// `close_project` refuses this too, and its refusal is the one that
/// counts. Said here so the button can explain itself before the round
/// trip, and so the write-off is offered as a deliberate choice rather
/// than found by failing.
String? closeBlockedBecause(Map<String, dynamic> row) {
  final unbilled = (row['unbilled_time'] as num?) ?? 0;
  if (unbilled <= 0) return null;
  return '${Fmt.money(unbilled)} of billable time on this job has never '
      'been invoiced. Bill it, or close the job writing the time off.';
}

/// Every project, with what it has cost.
Future<void> showProjectBudgets(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _BudgetDialog(),
    );

class _BudgetDialog extends ConsumerStatefulWidget {
  const _BudgetDialog();

  @override
  ConsumerState<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends ConsumerState<_BudgetDialog> {
  bool _includeClosed = false;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(projectBudgetProvider(_includeClosed));
    final canPost = ref.watch(canPostProvider);

    return AlertDialog(
      title: const Text('Job costing'),
      content: SizedBox(
        width: 680,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(
                  'Cost is read from the ledger, so a journal posted by '
                  'hand counts the same as a bill line.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: Space.md),
              FilterChip(
                key: const ValueKey('budget-include-closed'),
                label: const Text('Closed too'),
                selected: _includeClosed,
                onSelected: (v) => setState(() => _includeClosed = v),
              ),
            ]),
            const SizedBox(height: Space.md),
            Expanded(
              child: AsyncView(
                value: rows,
                onRetry: () =>
                    ref.invalidate(projectBudgetProvider(_includeClosed)),
                skeleton: const ListSkeleton(rows: 6, leading: false),
                builder: (list) {
                  if (list.isEmpty) {
                    return const EmptyState(
                      icon: Icons.folder_outlined,
                      title: 'No projects',
                      message: 'A project is what hours and costs are '
                          'recorded against.',
                    );
                  }
                  return ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) =>
                        _BudgetRow(row: list[i], canPost: canPost),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _BudgetRow extends ConsumerWidget {
  const _BudgetRow({required this.row, required this.canPost});

  final Map<String, dynamic> row;
  final bool canPost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = budgetStateOf(row);
    final open = row['is_active'] as bool? ?? true;
    final colour = switch (state) {
      BudgetState.over => context.colors.danger,
      BudgetState.close => context.colors.warning,
      BudgetState.within || BudgetState.none => null,
    };

    return ListTile(
      key: ValueKey('budget-${row['project_id']}'),
      title: Row(children: [
        Expanded(
          child: Text('${row['code']} · ${row['name']}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (!open)
          const Padding(
            padding: EdgeInsets.only(left: Space.sm),
            child: Text('closed', style: TextStyle(fontSize: 11)),
          ),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(describeBudget(row),
              style: TextStyle(fontSize: 12, color: colour)),
          if (state != BudgetState.none)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: LinearProgressIndicator(
                value: budgetFraction(row),
                color: colour,
              ),
            ),
          if (((row['unbilled_time'] as num?) ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(
                '${Fmt.money(row['unbilled_time'] as num?)} recorded and '
                'not invoiced',
                style: TextStyle(
                    fontSize: 11, color: context.colors.warning),
              ),
            ),
        ],
      ),
      trailing: canPost
          ? TextButton(
              key: ValueKey('budget-close-${row['project_id']}'),
              onPressed: () => _toggle(context, ref, open),
              child: Text(open ? 'Close' : 'Reopen'),
            )
          : null,
    );
  }

  Future<void> _toggle(
      BuildContext context, WidgetRef ref, bool open) async {
    final id = row['project_id'] as String;
    if (!open) {
      final ok = await runWithFeedback(
        context,
        action: () => ref.read(repoProvider)!.reopenProject(id),
        successMessage: 'Reopened',
      );
      if (ok) ref.invalidate(projectBudgetProvider);
      return;
    }

    // The write-off is asked for, not discovered by being refused. The
    // hours were meant to be charged for; deciding not to charge is a
    // decision and it is put as one.
    final blocked = closeBlockedBecause(row);
    var writeOff = false;
    if (blocked != null) {
      final answer = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Close the job?'),
          content: Text('$blocked\n\nHours left on a closed job are '
              'hours nobody is looking at.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not yet'),
            ),
            FilledButton(
              key: const ValueKey('budget-write-off'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Write it off and close'),
            ),
          ],
        ),
      );
      if (answer != true) return;
      writeOff = true;
    }

    if (!context.mounted) return;
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.closeProject(id, writeOff: writeOff),
      successMessage: 'Closed',
    );
    if (ok) {
      ref.invalidate(projectBudgetProvider);
      ref.invalidate(projectsProvider);
    }
  }
}

/// What a project row is, given what was entered.
///
/// The two rules the database holds, echoed here so the form can say
/// them where they are typed. `projects_budget_ck` and
/// `projects_dates_ck` are the ones that count.
String? projectBlockedBecause({
  required String code,
  required String name,
  required double? budget,
  required DateTime? start,
  required DateTime? end,
}) {
  if (code.trim().isEmpty) return 'Give it a code.';
  if (name.trim().isEmpty) return 'Give it a name.';
  if (budget != null && budget < 0) return 'A budget is not negative.';
  if (start != null && end != null && end.isBefore(start)) {
    return 'A job does not end before it starts.';
  }
  return null;
}

/// The row a project editor sends.
Map<String, dynamic> projectValues({
  required String code,
  required String name,
  String? contactId,
  double? budget,
  DateTime? start,
  DateTime? end,
}) => <String, dynamic>{
      'code': code.trim(),
      'name': name.trim(),
      'contact_id': contactId,
      // Cleared rather than left out: a budget somebody removed on
      // purpose has to come off the record, or the report goes on
      // measuring against a number nobody stands behind.
      'budget_amount': budget,
      'start_date': start == null ? null : Fmt.iso(start),
      'end_date': end == null ? null : Fmt.iso(end),
    };

/// Create or amend a project.
Future<bool> showProjectEditor(
  BuildContext context, {
  Map<String, dynamic>? project,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ProjectEditor(project: project),
    ) ??
    false;

class _ProjectEditor extends ConsumerStatefulWidget {
  const _ProjectEditor({this.project});

  final Map<String, dynamic>? project;

  @override
  ConsumerState<_ProjectEditor> createState() => _ProjectEditorState();
}

class _ProjectEditorState extends ConsumerState<_ProjectEditor> {
  late final TextEditingController _code = TextEditingController(
      text: widget.project?['code']?.toString() ?? '');
  late final TextEditingController _name = TextEditingController(
      text: widget.project?['name']?.toString() ?? '');
  late final TextEditingController _budget = TextEditingController(
      text: widget.project?['budget_amount'] == null
          ? ''
          : '${widget.project!['budget_amount']}');
  late String? _contactId = widget.project?['contact_id'] as String?;
  late DateTime? _start = Fmt.parseDate(widget.project?['start_date']);
  late DateTime? _end = Fmt.parseDate(widget.project?['end_date']);
  bool _saving = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _budget.dispose();
    super.dispose();
  }

  double? get _budgetValue {
    final text = _budget.text.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref
            .watch(contactsProvider((type: 'customer', search: '')))
            .valueOrNull ??
        const <Contact>[];
    final blocked = projectBlockedBecause(
      code: _code.text,
      name: _name.text,
      budget: _budgetValue,
      start: _start,
      end: _end,
    );

    return AlertDialog(
      title: Text(widget.project == null ? 'New project' : 'Amend project'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    key: const ValueKey('project-code'),
                    controller: _code,
                    enabled: !_saving && widget.project == null,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Code',
                      // The ledger carries the code, not the id, so
                      // renaming a project must not restate last year's
                      // job costing — which is `0088`'s own reasoning
                      // for using codes on the lines.
                      helperText: 'On the ledger lines',
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: TextField(
                    key: const ValueKey('project-name'),
                    controller: _name,
                    enabled: !_saving,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Name'),
                  ),
                ),
              ]),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                key: const ValueKey('project-customer'),
                options: contactPickerOptions(customers),
                value: _contactId,
                label: 'Customer',
                helperText: 'Time on a project with no customer cannot '
                    'be invoiced',
                hint: 'Type a name or a code',
                // Internal work is a real answer here, which is why the
                // helper says what it costs rather than refusing.
                allowEmpty: true,
                enabled: !_saving,
                createLabel: 'Add customer',
                onCreate: (typed) => createContactFromPicker(
                  context,
                  contactType: 'customer',
                  typed: typed,
                ),
                onChanged: (v) => setState(() => _contactId = v),
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('project-budget'),
                controller: _budget,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Budget',
                  helperText: 'What the job is expected to cost. Left '
                      'empty, nothing is measured against.',
                ),
              ),
              const SizedBox(height: Space.md),
              Row(children: [
                Expanded(
                  child: _ProjectDate(
                    label: 'Starts',
                    value: _start,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _start = d),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: _ProjectDate(
                    label: 'Ends',
                    value: _end,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _end = d),
                  ),
                ),
              ]),
              if (blocked != null) ...[
                const SizedBox(height: Space.md),
                Text(blocked,
                    style: TextStyle(
                        fontSize: 12, color: context.colors.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('project-save'),
          onPressed: _saving || blocked != null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveProject(
            projectValues(
              code: _code.text,
              name: _name.text,
              contactId: _contactId,
              budget: _budgetValue,
              start: _start,
              end: _end,
            ),
            id: widget.project?['id'] as String?,
          ),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(projectsProvider);
      ref.invalidate(projectBudgetProvider);
      Navigator.of(context).pop(true);
    }
  }
}

class _ProjectDate extends StatelessWidget {
  const _ProjectDate({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final bool enabled;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: enabled
                  ? () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: value ?? now,
                        firstDate: DateTime(now.year - 10),
                        lastDate: DateTime(now.year + 20),
                      );
                      if (picked != null) onChanged(picked);
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Text(value == null ? '—' : Fmt.date(value)),
              ),
            ),
          ),
          if (value != null && enabled)
            IconButton(
              icon: const Icon(Icons.clear, size: 16),
              onPressed: () => onChanged(null),
            ),
        ]),
      );
}
