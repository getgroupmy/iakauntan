import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../settings/new_account_dialog.dart';

/// Changing the six lines that matter.
///
/// The budget grid's own empty state has been telling people to "fill
/// it from last year and then change the lines that matter", and the
/// grid was read-only: `setBudgetLines` had no caller, so the only
/// budget anybody could have was last year's actuals times a
/// percentage. The one thing a budget is for -- arguing about the
/// handful of numbers that are actually decisions -- could not be done.

/// Whether this budget's numbers can still be changed.
///
/// `set_budget_lines` refuses anything but a draft: "Its numbers are
/// what was agreed and are not edited afterwards." Approving a budget
/// is what freezes it, and that is the point of approving one.
bool budgetIsEditable(String? status) => status == 'draft';

/// An amount, or null where it is not one.
///
/// Negatives are allowed. A budgeted contra -- returns against
/// revenue, a discount allowed -- is a real line, and refusing it here
/// would make people budget it as a positive somewhere it does not
/// belong.
double? budgetAmountOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null) return null;
  return double.parse(v.toStringAsFixed(2));
}

/// Whether an amount is still a line.
///
/// `set_budget_lines` skips a zero rather than storing it -- "A zero is
/// not a budget line" -- so setting one to nothing is how a line is
/// removed, and the form says so instead of leaving somebody hunting
/// for a delete button.
bool lineSurvives(num amount) => amount != 0;

/// The whole set, in the shape `set_budget_lines` takes.
///
/// The function deletes every line of the budget and re-inserts what it
/// is given. A payload holding only the row somebody edited would
/// therefore delete the rest of the budget, which is why the working
/// set is held whole and sent whole.
List<Map<String, dynamic>> budgetLinePayload(
  Iterable<Map<String, dynamic>> lines,
) =>
    [
      for (final l in lines)
        if (lineSurvives(num.tryParse('${l['amount'] ?? 0}') ?? 0))
          <String, dynamic>{
            'account': l['account_id'],
            'period': l['period_id'],
            'amount': num.tryParse('${l['amount']}') ?? 0,
          },
    ];

/// One amount replaced, or the row added where the budget had nothing
/// for that account in that period.
///
/// Order is preserved because the grid is read down a column of
/// accounts and a row that jumped on edit would be lost by the eye.
List<Map<String, dynamic>> withBudgetAmount(
  List<Map<String, dynamic>> lines,
  Map<String, dynamic> row,
  num amount,
) {
  final out = <Map<String, dynamic>>[];
  var found = false;
  for (final l in lines) {
    if (l['account_id'] == row['account_id'] &&
        l['period_id'] == row['period_id']) {
      found = true;
      out.add({...l, 'amount': amount});
    } else {
      out.add(l);
    }
  }
  if (!found) out.add({...row, 'amount': amount});
  return out;
}

/// What the budget adds up to as it stands.
///
/// Every line, whatever the account type, because this figure exists to
/// tell somebody their edit landed -- not to be a revenue total. The
/// list already reports revenue separately.
double budgetWorkingTotal(Iterable<Map<String, dynamic>> lines) =>
    double.parse(
      lines
          .fold<double>(
            0,
            (a, l) => a + (double.tryParse('${l['amount'] ?? 0}') ?? 0),
          )
          .toStringAsFixed(2),
    );

/// Change the lines of a draft budget.
Future<bool> showBudgetLineEditor(
  BuildContext context, {
  required Map<String, dynamic> budget,
  required List<Map<String, dynamic>> lines,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _LineEditor(budget: budget, lines: lines),
    ) ??
    false;

class _LineEditor extends ConsumerStatefulWidget {
  const _LineEditor({required this.budget, required this.lines});

  final Map<String, dynamic> budget;
  final List<Map<String, dynamic>> lines;

  @override
  ConsumerState<_LineEditor> createState() => _LineEditorState();
}

class _LineEditorState extends ConsumerState<_LineEditor> {
  late List<Map<String, dynamic>> _lines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Held whole, because the function replaces the set.
    _lines = [for (final l in widget.lines) {...l}];
  }

  List<FiscalPeriod> _periods() {
    final years = ref.watch(fiscalYearsProvider).valueOrNull ??
        const <FiscalYear>[];
    for (final y in years) {
      if (y.id == widget.budget['year_id']) return y.periods;
    }
    return const <FiscalPeriod>[];
  }

  Future<void> _editAmount(Map<String, dynamic> row) async {
    final controller = TextEditingController(
      text: '${row['amount'] ?? 0}',
    );
    final answer = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${row['code']} · ${row['period_name']}'),
        content: TextField(
          key: const ValueKey('budget-amount'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: const InputDecoration(
            labelText: 'Budgeted',
            helperText: 'Nothing budgeted? Set it to zero and the line goes.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = budgetAmountOf(controller.text);
              if (v != null) Navigator.of(ctx).pop(v);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (answer == null) return;
    setState(() => _lines = withBudgetAmount(_lines, row, answer));
  }

  Future<void> _addLine() async {
    final accounts = ref.read(accountsProvider).valueOrNull ?? const <Account>[];
    final periods = _periods();
    if (accounts.isEmpty || periods.isEmpty) return;

    final answer = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        // A heading has no balance of its own, and set_budget_lines
        // refuses one: "No such account, or it is a heading."
        final postable = accounts.where((a) => !a.isGroup).toList();
        String? accountId = postable.isEmpty ? null : postable.first.id;
        String? periodId = periods.first.id;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Budget another account'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SearchablePicker<String>(
                    key: const ValueKey('budget-account'),
                    options: accountPickerOptions(postable),
                    value: accountId,
                    label: 'Account',
                    hint: 'Type a number or a name',
                    createLabel: 'Add account',
                    onCreate: (typed) =>
                        createAccountFromPicker(context, typed: typed),
                    onChanged: (v) => setLocal(() => accountId = v),
                  ),
                  const SizedBox(height: Space.md),
                  DropdownButtonFormField<String>(
                    key: const ValueKey('budget-period'),
                    value: periodId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Period'),
                    items: [
                      for (final p in periods)
                        DropdownMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    onChanged: (v) => setLocal(() => periodId = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: accountId == null || periodId == null
                    ? null
                    : () {
                        final a =
                            postable.firstWhere((x) => x.id == accountId);
                        final p =
                            periods.firstWhere((x) => x.id == periodId);
                        Navigator.of(ctx).pop(<String, dynamic>{
                          'account_id': a.id,
                          'code': a.code,
                          'name': a.name,
                          'period_id': p.id,
                          'period_no': p.periodNo,
                          'period_name': p.name,
                          'amount': 0,
                        });
                      },
                child: const Text('Add'),
              ),
            ],
          ),
        );
      },
    );
    if (answer == null || !mounted) return;
    await _editAmount(answer);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final id = '${widget.budget['id']}';
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.setBudgetLines(id, budgetLinePayload(_lines)),
      successMessage: 'Budget changed',
      doing: 'Change a budget',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(budgetLinesProvider(id));
      ref.invalidate(budgetsProvider);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kept = _lines.where(
      (l) => lineSurvives(num.tryParse('${l['amount'] ?? 0}') ?? 0),
    );

    return AlertDialog(
      title: Text('${widget.budget['name']}'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Every line is sent together, because the budget is replaced '
              'rather than patched. A line set to zero is removed.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.scheme.onSurfaceVariant),
            ),
            const SizedBox(height: Space.sm),
            Expanded(
              child: _lines.isEmpty
                  ? const Center(
                      child: Text('Nothing budgeted yet.'),
                    )
                  : ListView.separated(
                      itemCount: _lines.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final l = _lines[i];
                        final amount =
                            num.tryParse('${l['amount'] ?? 0}') ?? 0;
                        final gone = !lineSurvives(amount);
                        return ListTile(
                          dense: true,
                          enabled: !_saving,
                          onTap: () => _editAmount(l),
                          title: Text(
                            '${l['code']} ${l['name']}',
                            style: TextStyle(
                              decoration:
                                  gone ? TextDecoration.lineThrough : null,
                            ),
                          ),
                          subtitle: Text(
                            gone
                                ? '${l['period_name']} — will be removed'
                                : '${l['period_name']}',
                          ),
                          trailing: Money(amount),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${kept.length} lines',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Money(budgetWorkingTotal(kept), bold: true),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('budget-add-line'),
          onPressed: _saving ? null : _addLine,
          child: const Text('Budget another account'),
        ),
        const Spacer(),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('budget-save-lines'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
