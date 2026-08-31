import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The headline, in the words an owner would use.
///
/// A date on its own is a fact; "in six weeks" is the thing somebody
/// acts on. Pure and exported so the banner and the tests agree.
String runsOutLabel(DateTime? on, DateTime today) {
  if (on == null) return 'The bank stays in credit the whole way';
  final days = on.difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days <= 0) return 'The bank is short now';
  final weeks = days ~/ 7;
  if (weeks < 1) return 'The bank runs short in $days days';
  return 'The bank runs short in $weeks week${weeks == 1 ? '' : 's'} '
      '— ${Fmt.date(on)}';
}

/// Where an expected movement comes from, said plainly.
String movementSource(String? source) => switch (source) {
  'invoice' => 'A customer invoice',
  'bill' => 'A supplier bill',
  'cheque' => 'A post-dated cheque',
  'recurring' => 'A recurring document',
  'payroll' => 'Wages',
  _ => 'Entered by hand',
};

/// One week of the forecast, as a line somebody can read at a glance.
String weekLabel(Map<String, dynamic> row) {
  final start = DateTime.tryParse('${row['week_start']}');
  final n = Fmt.toInt(row['week_no']);
  return 'Week $n · ${Fmt.date(start)}';
}

/// Bad news when the week closes short. The one thing on the page that
/// has to be impossible to miss.
///
/// `overdrawn` is the server's answer and is read as one: a week is
/// short because the closing balance went below zero, and recomputing
/// that here from the figures on the row would be a second opinion that
/// could disagree with the first.
Tone? weekTone(Map<String, dynamic> row) =>
    row['overdrawn'] == true ? Tone.bad : null;

Color? weekColour(BuildContext context, Map<String, dynamic> row) =>
    context.toneColour(weekTone(row));

/// How late a customer actually pays, said the way somebody would
/// defend or dispute it.
String lagLabel(Map<String, dynamic> row) {
  final days = Fmt.toInt(row['lag_days']);
  if (days == 0) return 'Pays on the day';
  if (days < 0) return 'Pays ${-days} day${days == -1 ? '' : 's'} early';
  return 'Takes $days day${days == 1 ? '' : 's'} longer than the terms';
}

/// Whose habit actually moves the forecast.
///
/// A customer who owes nothing has no invoice for the lag to shift, so
/// their habit changes no week on the page — listing them buries the
/// three names somebody came here to argue about. The order the
/// function returns is kept: latest first, which is the order the
/// argument goes in.
List<Map<String, dynamic>> lagsWorthArguingAbout(
  Iterable<Map<String, dynamic>> rows,
) =>
    [
      for (final r in rows)
        if ((double.tryParse('${r['outstanding'] ?? 0}') ?? 0) > 0) r,
    ];

/// What the lags are holding up altogether.
double lagsOutstanding(Iterable<Map<String, dynamic>> rows) => double.parse(
      rows
          .fold<double>(
            0,
            (a, r) => a + (double.tryParse('${r['outstanding'] ?? 0}') ?? 0),
          )
          .toStringAsFixed(2),
    );

/// Where the number came from, said once so nobody has to guess how far
/// back it looks.
///
/// `app.contact_payment_lag` averages the last twelve settled invoices
/// and clamps each between thirty days early and a hundred and eighty
/// late, so one furious month cannot move a customer's habit by a year.
const String lagsProvenance =
    'The average of the last twelve invoices each customer settled, '
    'counted from the day it fell due. A single very late payment is '
    'capped at 180 days so it cannot move the habit by a year.';

/// What the bank will look like, and when it runs short.
class CashFlowScreen extends ConsumerStatefulWidget {
  const CashFlowScreen({super.key});

  @override
  ConsumerState<CashFlowScreen> createState() => _CashFlowScreenState();
}

class _CashFlowScreenState extends ConsumerState<CashFlowScreen> {
  int _weeks = 13;
  bool _useHistory = true;
  int? _openWeek;

  @override
  Widget build(BuildContext context) {
    final weeks = ref.watch(
      cashForecastProvider((weeks: _weeks, useHistory: _useHistory)),
    );
    final runsOut = ref.watch(cashRunsOutProvider(_weeks)).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash flow'),
        actions: [
          PopupMenuButton<int>(
            onSelected: (v) => setState(() => _weeks = v),
            icon: const Icon(Icons.date_range_outlined),
            itemBuilder: (_) => [
              for (final w in const [4, 13, 26, 52])
                PopupMenuItem(value: w, child: Text('$w weeks')),
            ],
          ),
          IconButton(
            tooltip: _useHistory
                ? 'Using how late each customer actually pays'
                : 'Using the terms as written',
            icon: Icon(_useHistory ? Icons.history : Icons.event_outlined),
            onPressed: () => setState(() => _useHistory = !_useHistory),
          ),
          // The numbers behind the toggle beside it. The tooltip has
          // been claiming the forecast uses "how late each customer
          // actually pays" and there was no way to see, or dispute,
          // a single one of those figures.
          IconButton(
            key: const ValueKey('payment-lags'),
            tooltip: 'How late each customer pays',
            icon: const Icon(Icons.schedule_outlined),
            onPressed: _lags,
          ),
          IconButton(
            tooltip: 'What only you know',
            icon: const Icon(Icons.edit_calendar_outlined),
            onPressed: _items,
          ),
        ],
      ),
      body: Column(
        children: [
          _Banner(runsOut: runsOut),
          Expanded(
            child: AsyncView<List<Map<String, dynamic>>>(
              value: weeks,
              onRetry: () => ref.invalidate(
                cashForecastProvider((weeks: _weeks, useHistory: _useHistory)),
              ),
              builder: (rows) => ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final w = rows[i];
                  final n = Fmt.toInt(w['week_no']);
                  final open = _openWeek == n;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        title: Text(
                          weekLabel(w),
                          style: TextStyle(color: weekColour(context, w)),
                        ),
                        subtitle: Text(
                          'in ${Fmt.money(num.tryParse('${w['money_in']}'))} · '
                          'out ${Fmt.money(num.tryParse('${w['money_out']}'))}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: Money(
                          num.tryParse('${w['closing']}'),
                          bold: true,
                          colorNegative: true,
                        ),
                        onTap: () => setState(() => _openWeek = open ? null : n),
                      ),
                      if (open) _detail(w),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(Map<String, dynamic> week) {
    final from = DateTime.tryParse('${week['week_start']}');
    final to = DateTime.tryParse('${week['week_end']}');
    if (from == null || to == null) return const SizedBox.shrink();
    final detail = ref.watch(
      cashForecastDetailProvider((from: from, to: to, useHistory: _useHistory)),
    );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: AsyncView<List<Map<String, dynamic>>>(
        value: detail,
        onRetry: () => ref.invalidate(
          cashForecastDetailProvider((from: from, to: to, useHistory: _useHistory)),
        ),
        builder: (rows) {
          if (rows.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(Space.md),
              child: Text('Nothing expected either way this week.'),
            );
          }
          return Column(
            children: [
              for (final r in rows)
                ListTile(
                  dense: true,
                  leading: Icon(
                    r['direction'] == 'in'
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
                    size: 16,
                  ),
                  title: Text('${r['reference']}'),
                  subtitle: Text(
                    [
                      movementSource('${r['source']}'),
                      if ('${r['party'] ?? ''}'.trim().isNotEmpty)
                        '${r['party']}',
                      Fmt.date(DateTime.tryParse('${r['expected_on']}')),
                    ].join(' · '),
                  ),
                  trailing: Money(num.tryParse('${r['amount']}')),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Why the forecast moved an invoice.
  Future<void> _lags() => showDialog<void>(
        context: context,
        builder: (_) => const _LagsSheet(),
      );

  Future<void> _items() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ItemsSheet(),
    );
    if (changed == true) {
      ref.invalidate(cashForecastProvider((weeks: _weeks, useHistory: _useHistory)));
      ref.invalidate(cashRunsOutProvider(_weeks));
    }
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.runsOut});

  final DateTime? runsOut;

  @override
  Widget build(BuildContext context) {
    final short = runsOut != null;
    return Container(
      width: double.infinity,
      color: short
          ? context.colors.danger.withValues(alpha: 0.12)
          : context.colors.success.withValues(alpha: 0.12),
      padding: const EdgeInsets.all(Space.md),
      child: Row(
        children: [
          Icon(
            short ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            color: short ? context.colors.danger : context.colors.success,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              runsOutLabel(runsOut, DateTime.now()),
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The things the ledger cannot know: a tax instalment, a dividend, a
/// lorry somebody has decided to buy.
class _ItemsSheet extends ConsumerWidget {
  const _ItemsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(cashForecastItemsProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: SectionHeader(
                    'What only you know',
                    subtitle: 'A tax instalment, a dividend, a lorry',
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _add(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: items,
                onRetry: () => ref.invalidate(cashForecastItemsProvider),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(Space.md),
                      child: Text(
                        'Nothing yet. A forecast that ignores the tax '
                        'instalment is wrong in the direction that hurts.',
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final it = rows[i];
                      final live = it['is_active'] == true;
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${it['description']}',
                          style: live
                              ? null
                              : const TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                ),
                        ),
                        subtitle: Text(
                          [
                            it['direction'] == 'in' ? 'Coming in' : 'Going out',
                            Fmt.date(
                              DateTime.tryParse('${it['expected_on']}'),
                            ),
                            if ('${it['recurrence']}' != 'once')
                              '${it['recurrence']}',
                          ].join(' · '),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Money(num.tryParse('${it['amount']}')),
                            if (live)
                              IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Switch it off',
                                onPressed: () async {
                                  final repo = ref.read(repoProvider);
                                  if (repo == null) return;
                                  final ok = await runWithFeedback(
                                    context,
                                    successMessage: 'Switched off',
                                    action: () => repo.retireCashForecastItem(
                                      '${it['id']}',
                                    ),
                                  );
                                  if (ok && context.mounted) {
                                    ref.invalidate(cashForecastItemsProvider);
                                  }
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => const _ItemDialog(),
    );
    if (made == true) ref.invalidate(cashForecastItemsProvider);
  }
}

class _ItemDialog extends ConsumerStatefulWidget {
  const _ItemDialog();

  @override
  ConsumerState<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends ConsumerState<_ItemDialog> {
  String _direction = 'out';
  String _recurrence = 'once';
  final _description = TextEditingController();
  final _amount = TextEditingController();
  DateTime _on = DateTime.now().add(const Duration(days: 7));
  DateTime? _until;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(_amount.text) ?? 0;
    return AlertDialog(
      title: const Text('Something the books cannot know'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'out', label: Text('Going out')),
                  ButtonSegment(value: 'in', label: Text('Coming in')),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() => _direction = s.first),
              ),
              TextField(
                controller: _description,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'What it is',
                  hintText: 'Income tax instalment, a lorry, a dividend',
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'How much'),
                onChanged: (_) => setState(() {}),
              ),
              DropdownButtonFormField<String>(
                value: _recurrence,
                decoration: const InputDecoration(labelText: 'How often'),
                items: const [
                  DropdownMenuItem(value: 'once', child: Text('Once')),
                  DropdownMenuItem(value: 'weekly', child: Text('Every week')),
                  DropdownMenuItem(value: 'monthly', child: Text('Every month')),
                  DropdownMenuItem(
                    value: 'quarterly',
                    child: Text('Every quarter'),
                  ),
                  DropdownMenuItem(value: 'yearly', child: Text('Every year')),
                ],
                onChanged: (v) => setState(() => _recurrence = v ?? 'once'),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined, size: 18),
                title: Text('First on ${Fmt.date(_on)}'),
                trailing: const Text('Change'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _on,
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 1095)),
                  );
                  if (picked != null) setState(() => _on = picked);
                },
              ),
              // Only offered for something that repeats: a loan needs an
              // end date or the forecast pays it off for ever, and a
              // one-off has nothing to end.
              if (_recurrence != 'once')
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_busy_outlined, size: 18),
                  title: Text(
                    _until == null ? 'Goes on for ever' : 'Until ${Fmt.date(_until)}',
                  ),
                  trailing: const Text('Change'),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _until ?? _on.add(const Duration(days: 365)),
                      firstDate: _on,
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) setState(() => _until = picked);
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _description.text.trim().isEmpty || amount <= 0
              ? null
              : () async {
                  final repo = ref.read(repoProvider);
                  if (repo == null) return;
                  final ok = await runWithFeedback(
                    context,
                    successMessage: 'In the forecast',
                    action: () => repo.saveCashForecastItem(
                      direction: _direction,
                      description: _description.text.trim(),
                      amount: amount,
                      expectedOn: _on,
                      recurrence: _recurrence,
                      until: _recurrence == 'once' ? null : _until,
                    ),
                  );
                  if (ok && context.mounted) Navigator.of(context).pop(true);
                },
          child: const Text('Add it'),
        ),
      ],
    );
  }
}

/// How late each customer actually pays.
///
/// `customer_payment_lags` was written for exactly this — "so somebody
/// can see why the forecast moved an invoice and argue with it" — and
/// nothing watched it, so the toggle in the app bar made a claim the
/// screen could not support.
class _LagsSheet extends ConsumerWidget {
  const _LagsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lags = ref.watch(customerPaymentLagsProvider);

    return AlertDialog(
      title: const Text('How late each customer pays'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: AsyncView<List<Map<String, dynamic>>>(
          value: lags,
          onRetry: () => ref.invalidate(customerPaymentLagsProvider),
          builder: (all) {
            final rows = lagsWorthArguingAbout(all);
            if (rows.isEmpty) {
              return const EmptyState(
                icon: Icons.schedule_outlined,
                title: 'Nothing outstanding',
                message: 'A customer who owes nothing has no invoice for '
                    'a habit to move, so nothing here changes the '
                    'forecast.',
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  lagsProvenance,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
                const SizedBox(height: Space.sm),
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = rows[i];
                      return ListTile(
                        dense: true,
                        title: Text('${r['party']}'),
                        subtitle: Text(
                          lagLabel(r),
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Money(
                          num.tryParse('${r['outstanding'] ?? 0}'),
                        ),
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
                          '${rows.length} customers owing',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Money(lagsOutstanding(rows), bold: true),
                    ],
                  ),
                ),
              ],
            );
          },
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
