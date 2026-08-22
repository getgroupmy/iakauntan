import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// What a budget's row says under its name.
String budgetSummary(Map<String, dynamic> row) {
  final lines = Fmt.toInt(row['lines']);
  final dept = '${row['department_code'] ?? ''}'.trim();
  return [
    '${row['year_name']}',
    if (dept.isNotEmpty) dept,
    lines == 0 ? 'nothing in it yet' : '$lines line${lines == 1 ? '' : 's'}',
  ].join(' · ');
}

/// The variance, said the way a director reads it.
///
/// A number on its own does not say whether it is good news: minus five
/// thousand of sales is bad and minus five thousand of rent is good.
/// The server answers that in `favourable`, and this turns it into
/// words rather than making every reader remember the convention.
String varianceLabel(Map<String, dynamic> row) {
  final v = num.tryParse('${row['variance'] ?? 0}') ?? 0;
  if (v == 0) return 'On plan';
  final pct = num.tryParse('${row['variance_pct'] ?? ''}');
  final money = Fmt.money(v.abs());
  final direction = v > 0 ? 'over' : 'under';
  return pct == null
      ? '$money $direction'
      : '$money $direction · ${pct.abs().toStringAsFixed(1)}%';
}

/// Green for good news, red for bad, and nothing for a line that is on
/// plan or for an account where the question does not apply.
Color? varianceColour(BuildContext context, Map<String, dynamic> row) {
  final v = num.tryParse('${row['variance'] ?? 0}') ?? 0;
  if (v == 0) return null;
  final good = row['favourable'];
  if (good is! bool) return null;
  return good ? context.colors.success : context.colors.danger;
}

/// The periods a report covers, named the way somebody asks for them.
String periodRangeLabel(int from, int to) {
  if (from == 1 && to == 12) return 'The whole year';
  if (from == to) return 'Period $from';
  if (from == 1 && to == 3) return 'First quarter';
  if (from == 1) return 'Year to period $to';
  return 'Periods $from to $to';
}

/// What was supposed to happen, and whether it did.
class BudgetsScreen extends ConsumerStatefulWidget {
  const BudgetsScreen({super.key});

  @override
  ConsumerState<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends ConsumerState<BudgetsScreen> {
  String? _open;
  int _from = 1;
  int _to = 12;

  @override
  Widget build(BuildContext context) {
    final budgets = ref.watch(budgetsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Budgets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.flag_outlined),
        label: const Text('New budget'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: budgets,
        onRetry: () => ref.invalidate(budgetsProvider),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.flag_outlined,
              title: 'No budget yet',
              message: 'Every management account has three columns: what '
                  'happened, what was supposed to, and the difference. '
                  'Set the second one here and the third comes free.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final b = rows[i];
              final id = '${b['id']}';
              final open = _open == id;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    leading: const Icon(Icons.flag_outlined),
                    title: Text('${b['name']}'),
                    subtitle: Text(budgetSummary(b)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        StatusChip('${b['status']}', compact: true),
                        _menu(b),
                      ],
                    ),
                    onTap: () => setState(() => _open = open ? null : id),
                  ),
                  if (open) _variance(id),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _menu(Map<String, dynamic> b) {
    final id = '${b['id']}';
    final status = '${b['status']}';
    return PopupMenuButton<String>(
      onSelected: (choice) => switch (choice) {
        'edit' => _edit(b),
        'fill' => _fill(id),
        'approve' => _run(
          () => ref.read(repoProvider)!.approveBudget(id),
          'Agreed',
        ),
        _ => _run(
          () => ref.read(repoProvider)!.archiveBudget(id),
          'Put away',
        ),
      },
      itemBuilder: (_) => [
        if (status == 'draft') ...[
          const PopupMenuItem(value: 'edit', child: Text('Change the numbers')),
          const PopupMenuItem(
            value: 'fill',
            child: Text('Fill it from last year'),
          ),
          const PopupMenuItem(value: 'approve', child: Text('Agree it')),
        ],
        if (status != 'archived')
          const PopupMenuItem(value: 'archive', child: Text('Put it away')),
      ],
    );
  }

  Widget _variance(String id) {
    final report = ref.watch(
      budgetVsActualProvider((budget: id, from: _from, to: _to)),
    );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  periodRangeLabel(_from, _to),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: _pickPeriods,
                child: const Text('Change the period'),
              ),
            ],
          ),
          AsyncView<List<Map<String, dynamic>>>(
            value: report,
            onRetry: () => ref.invalidate(
              budgetVsActualProvider((budget: id, from: _from, to: _to)),
            ),
            builder: (rows) {
              if (rows.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: Text('Nothing budgeted and nothing spent.'),
                );
              }
              return Column(
                children: [
                  for (final r in rows)
                    ListTile(
                      dense: true,
                      title: Text('${r['code']} ${r['name']}'),
                      subtitle: Text(
                        varianceLabel(r),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: varianceColour(context, r),
                        ),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Money(num.tryParse('${r['actual']}'), bold: true),
                          Text(
                            'plan ${Fmt.money(num.tryParse('${r['budget']}'))}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickPeriods() async {
    final picked = await showModalBottomSheet<({int from, int to})>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Which periods')),
            const Divider(height: 1),
            for (final r in const [
              (label: 'The whole year', from: 1, to: 12),
              (label: 'First quarter', from: 1, to: 3),
              (label: 'First half', from: 1, to: 6),
            ])
              ListTile(
                dense: true,
                title: Text(r.label),
                onTap: () =>
                    Navigator.of(ctx).pop((from: r.from, to: r.to)),
              ),
            const Divider(height: 1),
            for (var p = 1; p <= 12; p++)
              ListTile(
                dense: true,
                title: Text('Period $p on its own'),
                onTap: () => Navigator.of(ctx).pop((from: p, to: p)),
              ),
          ],
        ),
      ),
    );
    if (picked != null) {
      setState(() {
        _from = picked.from;
        _to = picked.to;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String message) async {
    final ok = await runWithFeedback(
      context,
      successMessage: message,
      action: action,
    );
    if (ok) ref.invalidate(budgetsProvider);
  }

  Future<void> _create() async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => const _BudgetDialog(),
    );
    if (made == true) ref.invalidate(budgetsProvider);
  }

  Future<void> _edit(Map<String, dynamic> b) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BudgetGrid(budget: b),
    );
    if (changed == true) {
      ref.invalidate(budgetsProvider);
      ref.invalidate(budgetLinesProvider('${b['id']}'));
    }
  }

  /// Last year's actuals plus a percentage — what people actually do,
  /// rather than typing a hundred and forty numbers.
  Future<void> _fill(String id) async {
    final years = await ref.read(fiscalYearsProvider.future);
    if (!mounted || years.isEmpty) return;
    final answer = await showDialog<({String year, double uplift})>(
      context: context,
      builder: (ctx) {
        String? year = years.first.id;
        final uplift = TextEditingController(text: '0');
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Fill it from last year'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: year,
                  decoration: const InputDecoration(labelText: 'From which year'),
                  items: [
                    for (final y in years)
                      DropdownMenuItem(value: y.id, child: Text(y.name)),
                  ],
                  onChanged: (v) => setLocal(() => year = v),
                ),
                TextField(
                  controller: uplift,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Plus what percentage',
                    hintText: '10 for ten per cent up, -5 for five down',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: year == null
                    ? null
                    : () => Navigator.of(ctx).pop((
                        year: year!,
                        uplift: double.tryParse(uplift.text) ?? 0,
                      )),
                child: const Text('Fill it'),
              ),
            ],
          ),
        );
      },
    );
    if (answer == null || !mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Filled — now argue about the six lines that matter',
      action: () => repo.buildBudgetFromActual(
        budgetId: id,
        fromYearId: answer.year,
        upliftPercent: answer.uplift,
      ),
    );
    if (ok) {
      ref.invalidate(budgetsProvider);
      ref.invalidate(budgetLinesProvider(id));
    }
  }
}

class _BudgetDialog extends ConsumerStatefulWidget {
  const _BudgetDialog();

  @override
  ConsumerState<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends ConsumerState<_BudgetDialog> {
  final _name = TextEditingController();
  final _department = TextEditingController();
  String? _year;

  @override
  void dispose() {
    _name.dispose();
    _department.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final years =
        ref.watch(fiscalYearsProvider).valueOrNull ?? const <FiscalYear>[];
    _year ??= years.isEmpty ? null : years.first.id;

    return AlertDialog(
      title: const Text('A budget'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'What it is called',
              hintText: 'Board plan, revised forecast',
            ),
            onChanged: (_) => setState(() {}),
          ),
          DropdownButtonFormField<String>(
            value: _year,
            decoration: const InputDecoration(labelText: 'Which year'),
            items: [
              for (final y in years)
                DropdownMenuItem(value: y.id, child: Text(y.name)),
            ],
            onChanged: (v) => setState(() => _year = v),
          ),
          TextField(
            controller: _department,
            decoration: const InputDecoration(
              labelText: 'For one department only',
              hintText: 'Leave blank for the whole company',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty || _year == null
              ? null
              : () async {
                  final repo = ref.read(repoProvider);
                  if (repo == null) return;
                  final ok = await runWithFeedback(
                    context,
                    successMessage: 'Started',
                    action: () => repo.saveBudget(
                      fiscalYearId: _year!,
                      name: _name.text.trim(),
                      departmentCode: _department.text.trim().isEmpty
                          ? null
                          : _department.text.trim(),
                    ),
                  );
                  if (ok && context.mounted) Navigator.of(context).pop(true);
                },
          child: const Text('Start it'),
        ),
      ],
    );
  }
}

/// The numbers, as a grid. Read-only here: a budget is typed against a
/// chart of accounts and twelve periods, which is a spreadsheet, and
/// the honest thing is to show what is in it and let the filling be
/// done from last year rather than pretend a phone is a good place to
/// type a hundred and forty figures.
class _BudgetGrid extends ConsumerWidget {
  const _BudgetGrid({required this.budget});

  final Map<String, dynamic> budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${budget['id']}';
    final lines = ref.watch(budgetLinesProvider(id));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              '${budget['name']}',
              subtitle: budgetSummary(budget),
            ),
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: lines,
                onRetry: () => ref.invalidate(budgetLinesProvider(id)),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(Space.md),
                      child: Text(
                        'Nothing in it. Fill it from last year and then '
                        'change the lines that matter.',
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final l = rows[i];
                      return ListTile(
                        dense: true,
                        title: Text('${l['code']} ${l['name']}'),
                        subtitle: Text('${l['period_name']}'),
                        trailing: Money(num.tryParse('${l['amount']}')),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
