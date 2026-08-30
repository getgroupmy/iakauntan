import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'deposit_apply_sheet.dart';

/// Which way the money went, in the words a shop uses.
String depositKind(String? kind) =>
    kind == 'supplier' ? 'Paid to a supplier' : 'Held for a customer';

/// What a deposit's row says under its number.
///
/// The balance is only mentioned while there is one. A settled deposit
/// saying "RM 0.00 left" is a line that trains people to stop reading
/// the ones that matter.
String depositSummary(Map<String, dynamic> row) {
  final amount = num.tryParse('${row['amount'] ?? 0}') ?? 0;
  final balance = num.tryParse('${row['balance'] ?? 0}') ?? 0;
  return [
    '${row['party']}',
    Fmt.money(amount),
    if (balance > 0 && balance < amount) '${Fmt.money(balance)} left',
    if (balance >= amount) 'untouched',
  ].join(' · ');
}

/// Where a deposit went, once it is settled — or null while it is still
/// sitting there.
///
/// This is the sentence somebody looks for a year later, because
/// "settled" on its own does not say whether the customer got the money
/// back or the company kept it, and those are very different
/// conversations.
String? depositOutcome(Map<String, dynamic> row) {
  final applied = num.tryParse('${row['applied'] ?? 0}') ?? 0;
  final refunded = num.tryParse('${row['refunded'] ?? 0}') ?? 0;
  final forfeited = num.tryParse('${row['forfeited'] ?? 0}') ?? 0;
  final parts = <String>[
    if (applied > 0) '${Fmt.money(applied)} against documents',
    if (refunded > 0) '${Fmt.money(refunded)} given back',
    if (forfeited > 0) '${Fmt.money(forfeited)} kept',
  ];
  return parts.isEmpty ? null : parts.join(', ');
}

/// Why this deposit cannot be undone, or null when it can be.
///
/// `void_deposit` will only take one nothing has been done with:
/// "Deposit % has already been used: % applied, % given back, % kept.
/// Undo those first." Once part of it has settled an invoice, the way
/// back is to undo that -- a note vanishing from under a posted
/// settlement would leave the settlement pointing at nothing.
String? depositVoidBlockedBecause(Map<String, dynamic> row) {
  if ('${row['status']}' == 'void') return 'This one is already void.';
  final amount = num.tryParse('${row['amount'] ?? 0}') ?? 0;
  final balance = num.tryParse('${row['balance'] ?? 0}') ?? 0;
  if (balance != amount) {
    return 'Part of it has been used. Undo that first.';
  }
  return null;
}

/// What one line of a deposit's history says.
String depositEvent(Map<String, dynamic> row) {
  final what = switch ('${row['happened']}') {
    'applied' => 'Applied to ${row['document']}',
    'refund' => 'Given back',
    _ => 'Kept',
  };
  final reason = '${row['reason'] ?? ''}'.trim();
  return reason.isEmpty ? what : '$what — $reason';
}

/// Money taken or paid before there is a document for it.
class DepositsScreen extends ConsumerWidget {
  const DepositsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(
      depositNotesProvider((kind: null, status: null)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Deposits')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.savings_outlined),
        label: const Text('New deposit'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: notes,
        onRetry: () =>
            ref.invalidate(depositNotesProvider((kind: null, status: null))),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.savings_outlined,
              title: 'Nothing on deposit',
              message: 'Money taken before there is an invoice for it is '
                  'owed back until the job is done, and money paid to a '
                  'supplier in advance is still yours. Record it here and '
                  'the balance sheet says so.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final n = rows[i];
              final outcome = depositOutcome(n);
              return ListTile(
                isThreeLine: outcome != null,
                leading: Icon(
                  '${n['kind']}' == 'supplier'
                      ? Icons.outbond_outlined
                      : Icons.savings_outlined,
                ),
                title: Text('${n['deposit_no']} · ${depositKind('${n['kind']}')}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(depositSummary(n)),
                    if (outcome != null)
                      Text(
                        outcome,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
                trailing: StatusChip('${n['status']}', compact: true),
                onTap: () => _open(context, ref, n),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => const _DepositDialog(),
    );
    if (made == true) {
      ref.invalidate(depositNotesProvider((kind: null, status: null)));
    }
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> note,
  ) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DepositSheet(note: note),
    );
    if (changed == true) {
      ref.invalidate(depositNotesProvider((kind: null, status: null)));
    }
  }
}

class _DepositDialog extends ConsumerStatefulWidget {
  const _DepositDialog();

  @override
  ConsumerState<_DepositDialog> createState() => _DepositDialogState();
}

class _DepositDialogState extends ConsumerState<_DepositDialog> {
  String _kind = 'customer';
  String? _contact;
  String? _bank;
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _notes = TextEditingController();
  DateTime _date = DateTime.now();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null || _contact == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Recorded',
      action: () => repo.createDeposit(
        kind: _kind,
        contactId: _contact!,
        date: _date,
        amount: double.tryParse(_amount.text) ?? 0,
        bankAccountId: _bank,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final contacts =
        ref
            .watch(
              contactsProvider((
                type: _kind == 'customer' ? 'customer' : 'supplier',
                search: '',
              )),
            )
            .valueOrNull ??
        const <Contact>[];
    final banks =
        ref.watch(bankAccountsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final amount = double.tryParse(_amount.text) ?? 0;

    return AlertDialog(
      title: const Text('A deposit'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'customer',
                    label: Text('Taken'),
                    icon: Icon(Icons.savings_outlined, size: 18),
                  ),
                  ButtonSegment(
                    value: 'supplier',
                    label: Text('Paid'),
                    icon: Icon(Icons.outbond_outlined, size: 18),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() {
                  _kind = s.first;
                  // The contact list is a different list now, so a
                  // customer left selected would be sent as a supplier.
                  _contact = null;
                }),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                value: _contact,
                decoration: InputDecoration(
                  labelText: _kind == 'customer' ? 'From whom' : 'To whom',
                ),
                items: [
                  for (final c in contacts)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _contact = v),
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
                value: _bank,
                decoration: const InputDecoration(labelText: 'In or out of'),
                items: [
                  for (final b in banks)
                    DropdownMenuItem(
                      value: '${b['id']}',
                      child: Text('${b['name']}'),
                    ),
                ],
                onChanged: (v) => setState(() => _bank = v),
              ),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference',
                  hintText: 'Cheque number, transfer reference',
                ),
              ),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'What it is for',
                  hintText: 'Half up front on the fitted kitchen',
                ),
              ),
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
          onPressed: _busy || _contact == null || amount <= 0 ? null : _save,
          child: const Text('Record it'),
        ),
      ],
    );
  }
}

/// A deposit, opened: what has happened to it and what can still be
/// done with what is left.
class _DepositSheet extends ConsumerWidget {
  const _DepositSheet({required this.note});

  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${note['id']}';
    final balance = num.tryParse('${note['balance'] ?? 0}') ?? 0;
    final history = ref.watch(depositHistoryProvider(id));

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
                    '${note['deposit_no']}',
                    subtitle: depositSummary(note),
                  ),
                ),
                StatusChip('${note['status']}', compact: true),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: history,
                onRetry: () => ref.invalidate(depositHistoryProvider(id)),
                builder: (rows) {
                  if (rows.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(Space.md),
                      child: Text('Nothing has happened to it yet.'),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => ListTile(
                      dense: true,
                      title: Text(depositEvent(rows[i])),
                      subtitle: Text(
                        Fmt.date(DateTime.tryParse('${rows[i]['on_date']}')),
                      ),
                      trailing: Money(num.tryParse('${rows[i]['amount'] ?? 0}')),
                    ),
                  );
                },
              ),
            ),
            if (balance > 0 && '${note['status']}' != 'void')
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => _settle(context, ref, id, 'refund'),
                      child: const Text('Give it back'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => _settle(context, ref, id, 'forfeit'),
                      child: const Text('Keep it'),
                    ),
                    const SizedBox(width: Space.sm),
                    // The ordinary outcome, and so the emphasised one:
                    // the job got done, the invoice went out, and the
                    // money already held pays part of it.
                    FilledButton(
                      key: const ValueKey('apply-deposit'),
                      onPressed: () => _apply(context, ref, id, balance),
                      child: const Text('Apply to a document'),
                    ),
                  ],
                ),
              ),
            // Undoing the note itself, as against settling it. Offered
            // only while nothing has been done with it, which is the
            // only state `void_deposit` takes.
            if (depositVoidBlockedBecause(note) == null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('void-deposit'),
                  onPressed: () => _voidIt(context, ref, id),
                  child: const Text('It was never taken — void it'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The contact and the currency come off the note itself: the list
  /// this sheet was opened from names the party but not which contact
  /// row it is, and `apply_deposit` refuses a document belonging to
  /// anybody else.
  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    String id,
    num balance,
  ) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    Map<String, dynamic> full;
    try {
      full = await repo.depositNote(id);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!context.mounted) return;

    final done = await showApplyDepositSheet(
      context,
      depositId: id,
      kind: '${full['kind']}',
      contactId: '${full['contact_id']}',
      currency: '${full['currency']}',
      balance: balance,
    );
    if (done && context.mounted) Navigator.of(context).pop(true);
  }

  /// Undo the note itself. `void_deposit` reverses the posting, puts
  /// the bank balance back, and insists on a reason.
  Future<void> _voidIt(BuildContext context, WidgetRef ref, String id) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Void ${note['deposit_no']}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'The posting is reversed and the bank balance goes back '
                'to where it was. Use this when the money never arrived, '
                'not when it is being given back.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              TextField(
                key: const ValueKey('void-deposit-reason'),
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Why',
                  hintText: 'The cheque was never banked',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () {
              final r = controller.text.trim();
              if (r.isNotEmpty) Navigator.of(ctx).pop(r);
            },
            child: const Text('Void it'),
          ),
        ],
      ),
    );
    if (reason == null || !context.mounted) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Voided and reversed',
      action: () => repo.voidDeposit(id, reason),
    );
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }

  Future<void> _settle(
    BuildContext context,
    WidgetRef ref,
    String id,
    String kind,
  ) async {
    final balance = num.tryParse('${note['balance'] ?? 0}') ?? 0;
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(
            kind == 'refund'
                ? 'Give back ${Fmt.money(balance)}'
                : 'Keep ${Fmt.money(balance)}',
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Why',
              // The server insists on a reason for keeping somebody's
              // money and does not for giving it back, which is the
              // right way round; the field is offered either way.
              hintText: kind == 'refund'
                  ? 'The job finished under the estimate'
                  : 'She cancelled inside the fortnight',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(kind == 'refund' ? 'Give it back' : 'Keep it'),
            ),
          ],
        );
      },
    );
    if (reason == null || !context.mounted) return;
    if (kind == 'forfeit' && reason.isEmpty) return;

    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: kind == 'refund' ? 'Given back' : 'Kept',
      action: () => repo.settleDeposit(
        depositId: id,
        kind: kind,
        amount: balance,
        reason: reason.isEmpty ? null : reason,
      ),
    );
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }
}
