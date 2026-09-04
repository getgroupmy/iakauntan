import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// What a run's row says under its number.
///
/// Pure and exported so the list and the tests agree. Capitalised is
/// only mentioned once there is something to say about it: on a draft it
/// is zero and saying so would read as a failure rather than as a thing
/// that has not happened yet.
String runSummary(Map<String, dynamic> row) {
  final total = num.tryParse('${row['total'] ?? 0}') ?? 0;
  final bills = Fmt.toInt(row['bills']);
  final parts = <String>[
    '$bills bill${bills == 1 ? '' : 's'}',
    Fmt.money(total),
  ];
  if ('${row['status']}' == 'posted') {
    final cap = num.tryParse('${row['capitalised'] ?? 0}') ?? 0;
    parts.add(
      cap >= total
          ? 'all of it onto stock'
          : '${Fmt.money(cap)} onto stock',
    );
  }
  return parts.join(' · ');
}

/// Why part of a line's share could not go onto the stock, or null when
/// all of it could.
///
/// This is the sentence somebody will come looking for, because the
/// difference between what was spread and what was capitalised is money
/// that stayed in the profit and loss, and nothing else in the system
/// will explain where it went.
String? shortfallReason(Map<String, dynamic> row) {
  final amount = num.tryParse('${row['amount'] ?? 0}') ?? 0;
  final cap = num.tryParse('${row['capitalised'] ?? 0}') ?? 0;
  if (cap >= amount) return null;
  final received = num.tryParse('${row['received'] ?? 0}') ?? 0;
  final onHand = num.tryParse('${row['on_hand'] ?? 0}') ?? 0;
  final gone = received - onHand;
  if (onHand <= 0) {
    return '${Fmt.money(amount - cap)} stays on the expense account: '
        'none of these are left';
  }
  return '${Fmt.money(amount - cap)} stays on the expense account: '
      '${Fmt.qty(gone)} of ${Fmt.qty(received)} were already sold';
}

/// A charge being written, before it has been saved.
class ChargeDraft {
  ChargeDraft({
    this.description = '',
    this.amount = 0,
    this.basis = 'value',
    this.accountId,
  });

  String description;
  double amount;
  String basis;
  String? accountId;

  Map<String, dynamic> toJson() => {
    'description': description,
    'amount': amount,
    'basis': basis,
    'account': accountId,
  };
}

/// Whether a draft can still be rewritten.
///
/// `upsert_landed_cost_run` refuses anything else in its own words:
/// "That run is already %, and what it did to the stock cannot be
/// rewritten by editing it." A posted run is undone by cancelling it,
/// not by editing what it was.
bool runIsAmendable(String? status) => status == 'draft';

/// What one charge on a saved run reads as.
///
/// `landed_cost_charges` has been readable since the module went in and
/// nothing displayed a row of it, so a run showed what it would put on
/// the stock and never what was being spread — the freight, the duty
/// and the account each was coded to.
String chargeLine(Map<String, dynamic> row) {
  final account = row['accounts'] as Map?;
  return [
    '${row['description']}',
    if (account != null) '${account['code']} ${account['name']}',
    chargeBasis('${row['basis']}'),
  ].join(' · ');
}

/// How a charge is spread, in words rather than the enum.
///
/// `app.landed_cost_basis` has exactly two arms, and `value` is what
/// the column defaults to — which is also the right thing to say about
/// a row that came back with nothing in it.
String chargeBasis(String? basis) =>
    basis == 'quantity' ? 'by quantity' : 'by value';

/// What the run is spreading, altogether.
double chargesTotal(Iterable<Map<String, dynamic>> rows) => double.parse(
      rows
          .fold<double>(
            0,
            (a, r) => a + (double.tryParse('${r['amount'] ?? 0}') ?? 0),
          )
          .toStringAsFixed(2),
    );

/// The saved charges, as drafts the dialog can edit.
List<ChargeDraft> draftsOf(Iterable<Map<String, dynamic>> rows) {
  final list = [
    for (final r in rows)
      ChargeDraft(
        description: '${r['description'] ?? ''}',
        amount: double.tryParse('${r['amount'] ?? 0}') ?? 0,
        basis: '${r['basis'] ?? 'value'}',
        accountId: r['account_id'] as String?,
      ),
  ];
  // A run with nothing on it still needs a row to type into, which is
  // what a fresh dialog starts with.
  return list.isEmpty ? [ChargeDraft()] : list;
}

/// Which bills a saved run covers.
List<String> billIdsOf(Iterable<Map<String, dynamic>> targets) =>
    [for (final t in targets) '${t['bill_id']}'];

/// Whether a run is worth sending to the server yet.
///
/// Checked here as well as on the server so somebody typing sees the
/// button come alive rather than being told no when they press it. The
/// server's refusal is the one that counts.
bool canSaveRun(List<String> bills, List<ChargeDraft> charges) =>
    bills.isNotEmpty &&
    charges.isNotEmpty &&
    charges.every((c) => c.amount > 0);

/// Freight, duty and insurance being put onto the cost of the goods
/// they brought in.
class LandedCostScreen extends ConsumerWidget {
  const LandedCostScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(landedCostRunsProvider(null));

    return Scaffold(
      appBar: AppBar(title: const Text('Landed cost')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newRun(context, ref),
        icon: const Icon(Icons.local_shipping_outlined),
        label: const Text('New run'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: runs,
        onRetry: () => ref.invalidate(landedCostRunsProvider(null)),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.local_shipping_outlined,
              title: 'Nothing landed yet',
              message: 'Freight, duty and insurance are part of what the '
                  'stock cost. Put them on it here and the margin on '
                  'every sale of those goods stops being flattering.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              return ListTile(
                leading: const Icon(Icons.local_shipping_outlined),
                title: Text('${r['run_no']}'),
                subtitle: Text(runSummary(r)),
                trailing: StatusChip('${r['status']}', compact: true),
                onTap: () => _open(context, ref, r),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _newRun(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _RunDialog(),
    );
    if (saved == true) ref.invalidate(landedCostRunsProvider(null));
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> run,
  ) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RunSheet(run: run),
    );
    if (changed == true) ref.invalidate(landedCostRunsProvider(null));
  }
}

/// Writing a run down: which bills, and what is being spread over them.
class _RunDialog extends ConsumerStatefulWidget {
  const _RunDialog({
    this.run,
    this.bills = const [],
    this.charges = const [],
  });

  /// The run being rewritten, or null when one is being written.
  final Map<String, dynamic>? run;

  /// What it covers and what it spreads now. Passed in rather than read
  /// here because the sheet has already read them to show them.
  final List<String> bills;
  final List<ChargeDraft> charges;

  @override
  ConsumerState<_RunDialog> createState() => _RunDialogState();
}

class _RunDialogState extends ConsumerState<_RunDialog> {
  late final List<String> _bills;
  late final List<ChargeDraft> _charges;
  final _notes = TextEditingController();
  late DateTime _date;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bills = [...widget.bills];
    _charges = widget.charges.isEmpty ? [ChargeDraft()] : [...widget.charges];
    final run = widget.run;
    _date = run == null
        ? DateTime.now()
        : DateTime.tryParse('${run['run_date']}') ?? DateTime.now();
    _notes.text = '${run?['notes'] ?? ''}';
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.saveLandedCostRun(
        // With an id the function deletes the run's bills and charges
        // and writes these instead, which is what makes correcting a
        // typo something other than starting again.
        id: widget.run?['id'] as String?,
        date: _date,
        bills: _bills,
        charges: [for (final c in _charges) c.toJson()],
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // Only posted bills: a draft has put nothing on a shelf, and the
    // server refuses one anyway.
    final bills = ref
        .watch(
          documentsProvider((
            kind: DocKind.purchase,
            docType: 'bill',
            status: 'all',
            search: '',
          )),
        )
        .valueOrNull
        ?.where((d) => const {'posted', 'partial', 'completed'}.contains(d.status))
        .toList();
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const <Account>[];

    return AlertDialog(
      title: Text(
        widget.run == null
            ? 'A landed cost run'
            : 'Change ${widget.run!['run_no']}',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The date decides which period the entry lands in, so it
              // is a choice rather than today: a freight invoice for
              // last month's shipment is usually posted into last
              // month.
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined, size: 18),
                title: Text(Fmt.date(_date)),
                trailing: const Text('Change'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(_date.year - 3),
                    lastDate: DateTime(_date.year + 3),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
              ),
              const SectionHeader(
                'The goods',
                subtitle: 'The bills the charges are spread over',
              ),
              if (bills == null)
                const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: LinearProgressIndicator(),
                )
              else if (bills.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: Text('No posted bills to spread anything over.'),
                )
              else
                for (final b in bills.take(40))
                  CheckboxListTile(
                    dense: true,
                    value: _bills.contains(b.id),
                    title: Text(b.docNo),
                    subtitle: Text(
                      '${Fmt.date(b.docDate)} · ${Fmt.money(b.totalAmount)}',
                    ),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _bills.add(b.id);
                      } else {
                        _bills.remove(b.id);
                      }
                    }),
                  ),
              const SizedBox(height: Space.md),
              SectionHeader(
                'The charges',
                subtitle: 'Each comes off the account it was coded to',
                action: TextButton.icon(
                  onPressed: () => setState(() => _charges.add(ChargeDraft())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ),
              for (var i = 0; i < _charges.length; i++)
                _ChargeRow(
                  key: ObjectKey(_charges[i]),
                  charge: _charges[i],
                  accounts: accounts,
                  onChanged: () => setState(() {}),
                  onRemove: _charges.length == 1
                      ? null
                      : () => setState(() => _charges.removeAt(i)),
                ),
              const SizedBox(height: Space.md),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Container number, bill of lading',
                ),
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
          onPressed: _busy || !canSaveRun(_bills, _charges) ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ChargeRow extends StatelessWidget {
  const _ChargeRow({
    super.key,
    required this.charge,
    required this.accounts,
    required this.onChanged,
    this.onRemove,
  });

  final ChargeDraft charge;
  final List<Account> accounts;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 4,
                child: TextFormField(
                  initialValue: charge.description,
                  decoration: const InputDecoration(
                    hintText: 'Ocean freight',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    charge.description = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  initialValue: charge.amount == 0 ? '' : '${charge.amount}',
                  textAlign: TextAlign.right,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Amount',
                    isDense: true,
                  ),
                  onChanged: (v) {
                    charge.amount = double.tryParse(v) ?? 0;
                    onChanged();
                  },
                ),
              ),
              if (onRemove != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: charge.basis,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Spread by',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'value',
                      child: Text('What the goods cost'),
                    ),
                    DropdownMenuItem(
                      value: 'quantity',
                      child: Text('How many there are'),
                    ),
                  ],
                  onChanged: (v) {
                    charge.basis = v ?? 'value';
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: SearchablePicker<String>(
                  // The 200 the dropdown was capped at is gone with it:
                  // the cap existed because a list that long is
                  // unscrollable, and a box you type into is not.
                  options: accountPickerOptions(accounts),
                  value: charge.accountId,
                  label: 'Comes off',
                  hint: 'Freight and Import Duty',
                  onChanged: (v) {
                    charge.accountId = v;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A run, opened: what each line takes, and the button that commits it.
class _RunSheet extends ConsumerWidget {
  const _RunSheet({required this.run});

  final Map<String, dynamic> run;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${run['id']}';
    final draft = runIsAmendable('${run['status']}');
    final preview = ref.watch(landedCostPreviewProvider(id));
    // What is being spread, and over which bills. Both have been
    // readable since the module went in and neither was shown, so a run
    // said what it would put on the stock and never what it was made
    // of.
    final charges = ref.watch(landedCostChargesProvider(id)).valueOrNull ??
        const <Map<String, dynamic>>[];
    final targets = ref.watch(landedCostTargetsProvider(id)).valueOrNull ??
        const <Map<String, dynamic>>[];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: SectionHeader(
                    '${run['run_no']}',
                    subtitle: runSummary(run),
                  ),
                ),
                StatusChip('${run['status']}', compact: true),
              ],
            ),
            if (charges.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              for (final c in charges)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          chargeLine(c),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      Money(num.tryParse('${c['amount'] ?? 0}')),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Spread over ${targets.length} '
                        'bill${targets.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Money(chargesTotal(charges), bold: true),
                  ],
                ),
              ),
              const SizedBox(height: Space.sm),
            ],
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: preview,
                onRetry: () => ref.invalidate(landedCostPreviewProvider(id)),
                builder: (rows) => ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final short = shortfallReason(r);
                    return ListTile(
                      dense: true,
                      title: Text('${r['item_code']} · ${r['description']}'),
                      subtitle: Text(
                        [
                          '${r['bill_no']}',
                          '${Fmt.qty(num.tryParse('${r['on_hand']}'))} of '
                              '${Fmt.qty(num.tryParse('${r['received']}'))} left',
                          if (short != null) short,
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      trailing: Money(
                        num.tryParse('${r['capitalised'] ?? 0}'),
                        bold: true,
                      ),
                    );
                  },
                ),
              ),
            ),
            if (draft)
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => _cancel(context, ref, id),
                      child: const Text('Throw it away'),
                    ),
                    const SizedBox(width: Space.sm),
                    // Correcting a mistyped freight figure used to mean
                    // throwing the run away and re-entering every bill
                    // and every charge.
                    TextButton(
                      key: const ValueKey('amend-run'),
                      onPressed: () => _amend(context, ref, charges, targets),
                      child: const Text('Change it'),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () => _post(context, ref, id),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Put it on the stock'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _post(BuildContext context, WidgetRef ref, String id) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'On the stock',
      action: () => repo.postLandedCostRun(id),
    );
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _amend(
    BuildContext context,
    WidgetRef ref,
    List<Map<String, dynamic>> charges,
    List<Map<String, dynamic>> targets,
  ) async {
    final id = '${run['id']}';
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _RunDialog(
        run: run,
        bills: billIdsOf(targets),
        charges: draftsOf(charges),
      ),
    );
    if (saved != true || !context.mounted) return;
    ref
      ..invalidate(landedCostRunsProvider(null))
      ..invalidate(landedCostPreviewProvider(id))
      ..invalidate(landedCostChargesProvider(id))
      ..invalidate(landedCostTargetsProvider(id));
    Navigator.of(context).pop(true);
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, String id) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Thrown away',
      action: () => repo.cancelLandedCostRun(id),
    );
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }
}
