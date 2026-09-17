import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../contacts/new_contact_dialog.dart';

/// Which way the money runs, in the words a bookkeeper uses rather than
/// the words the database uses.
String contraSide(String? side) =>
    side == 'receivable' ? 'They owe us' : 'We owe them';

/// What a note's row says under its number.
String contraSummary(Map<String, dynamic> row) {
  final inv = Fmt.toInt(row['invoices']);
  final bills = Fmt.toInt(row['bills']);
  return [
    '${row['party']}',
    Fmt.money(num.tryParse('${row['amount'] ?? 0}')),
    '$inv invoice${inv == 1 ? '' : 's'} against '
        '$bills bill${bills == 1 ? '' : 's'}',
  ].join(' · ');
}

/// One side of a contra being built: the documents ticked and what each
/// is being offset by.
typedef ContraPick = Map<String, double>;

/// The two sides, and whether they cancel.
///
/// Pure and exported so the dialog, the button and the tests agree. The
/// server refuses an unequal contra and that refusal is the one that
/// counts; this is so somebody sees the figure go level while typing
/// rather than being told no after pressing save.
({double receivable, double payable, double difference, bool ok}) contraBalance(
  ContraPick invoices,
  ContraPick bills,
) {
  double sum(ContraPick p) => p.values.fold(0, (a, b) => a + b);
  final r = sum(invoices);
  final p = sum(bills);
  // Rounded to the sen before comparing: two figures that differ by a
  // hundredth of a sen are the same money, and a button that stays grey
  // for that reason is unexplainable.
  final rr = (r * 100).roundToDouble() / 100;
  final pp = (p * 100).roundToDouble() / 100;
  return (
    receivable: rr,
    payable: pp,
    difference: (rr - pp).abs(),
    ok: rr > 0 && rr == pp,
  );
}

/// What is left for somebody to actually pay, said in words.
///
/// This is the sentence the contra exists for: the offset cancels the
/// smaller figure and somebody writes a cheque for the rest.
String contraRemainder(
  ({double receivable, double payable, double difference, bool ok}) b,
) {
  if (b.receivable == 0 && b.payable == 0) return 'Nothing picked yet';
  if (b.ok) return 'Level — nothing left either way';
  return b.receivable > b.payable
      ? '${Fmt.money(b.difference)} more on their side'
      : '${Fmt.money(b.difference)} more on ours';
}

/// Offsetting what a party owes against what is owed to them.
class ContraScreen extends ConsumerWidget {
  const ContraScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(contraNotesProvider(null));

    return Scaffold(
      appBar: AppBar(title: const Text('Contra')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context, ref),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('New contra'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: notes,
        onRetry: () => ref.invalidate(contraNotesProvider(null)),
        skeleton: const ListSkeleton(rows: 6),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.swap_horiz,
              title: 'Nothing offset',
              message: 'When a customer is also a supplier, what they owe '
                  'and what you owe them cancel. Record it here and both '
                  'ledgers agree with their control accounts afterwards.',
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final n = rows[i];
              return ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text('${n['contra_no']}'),
                subtitle: Text(contraSummary(n)),
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
      builder: (_) => const _ContraDialog(),
    );
    if (made == true) ref.invalidate(contraNotesProvider(null));
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> note,
  ) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ContraSheet(note: note),
    );
    if (changed == true) ref.invalidate(contraNotesProvider(null));
  }
}

class _ContraDialog extends ConsumerStatefulWidget {
  const _ContraDialog();

  @override
  ConsumerState<_ContraDialog> createState() => _ContraDialogState();
}

class _ContraDialogState extends ConsumerState<_ContraDialog> {
  String? _contact;
  final _invoices = <String, double>{};
  final _bills = <String, double>{};
  DateTime _date = DateTime.now();
  bool _busy = false;

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Offset',
      action: () => repo.createContra(
        date: _date,
        invoices: [
          for (final e in _invoices.entries)
            {'document': e.key, 'amount': e.value},
        ],
        bills: [
          for (final e in _bills.entries) {'document': e.key, 'amount': e.value},
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // A contra needs somebody who is on both sides, so the picker offers
    // the contacts that can be — not every customer in the book.
    final contacts =
        ref.watch(contactsProvider((type: 'both', search: ''))).valueOrNull ??
        const <Contact>[];
    final candidates = _contact == null
        ? const AsyncValue<List<Map<String, dynamic>>>.data([])
        : ref.watch(contraCandidatesProvider(_contact!));
    final rows = candidates.valueOrNull ?? const <Map<String, dynamic>>[];
    final balance = contraBalance(_invoices, _bills);

    return AlertDialog(
      title: const Text('Offset the two'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchablePicker<String>(
                options: contactPickerOptions(contacts),
                value: _contact,
                label: 'Who',
                hint: 'Type a name or a code',
                // No offer to add one: a contra needs somebody who is
                // BOTH a customer and a supplier, with documents on
                // each side. A contact created here would have neither.
                onChanged: (v) => setState(() {
                  _contact = v;
                  _invoices.clear();
                  _bills.clear();
                }),
              ),
              // The date decides which period the offset lands in. A
              // contra agreed at the end of a quarter is usually posted
              // into that quarter, not into whenever somebody got round
              // to typing it.
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
              const SizedBox(height: Space.md),
              if (_contact != null && rows.isEmpty && !candidates.isLoading)
                const Padding(
                  padding: EdgeInsets.all(Space.md),
                  child: Text(
                    'Nothing outstanding on both sides for them. A contra '
                    'needs an invoice to settle and a bill to settle it '
                    'against.',
                  ),
                ),
              for (final side in const ['receivable', 'payable'])
                if (rows.any((r) => r['side'] == side)) ...[
                  SectionHeader(contraSide(side)),
                  for (final r in rows.where((r) => r['side'] == side))
                    _CandidateTile(
                      row: r,
                      picked: side == 'receivable' ? _invoices : _bills,
                      onChanged: () => setState(() {}),
                    ),
                  const SizedBox(height: Space.sm),
                ],
              if (_contact != null) ...[
                const Divider(),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        contraRemainder(balance),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: balance.ok
                              ? context.colors.success
                              : context.colors.warning,
                        ),
                      ),
                    ),
                    Money(balance.receivable),
                    const Text('  vs  '),
                    Money(balance.payable),
                  ],
                ),
              ],
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
          onPressed: _busy || !balance.ok ? null : _save,
          child: const Text('Offset'),
        ),
      ],
    );
  }
}

/// One outstanding document, ticked or not, and for how much.
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.row,
    required this.picked,
    required this.onChanged,
  });

  final Map<String, dynamic> row;
  final Map<String, double> picked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final id = '${row['document_id']}';
    final outstanding = (num.tryParse('${row['outstanding'] ?? 0}') ?? 0)
        .toDouble();
    final on = picked.containsKey(id);

    return Row(
      children: [
        Expanded(
          child: CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: on,
            title: Text('${row['doc_no']}'),
            subtitle: Text(
              '${Fmt.date(DateTime.tryParse('${row['doc_date']}'))} · '
              '${Fmt.money(outstanding)} outstanding',
            ),
            onChanged: (v) {
              if (v == true) {
                // Defaults to the whole balance, which is what a contra
                // usually is; the field beside it takes less.
                picked[id] = outstanding;
              } else {
                picked.remove(id);
              }
              onChanged();
            },
          ),
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            key: ValueKey('$id-${on ? 'on' : 'off'}'),
            initialValue: on ? '${picked[id]}' : '',
            enabled: on,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(isDense: true),
            onChanged: (v) {
              picked[id] = double.tryParse(v) ?? 0;
              onChanged();
            },
          ),
        ),
      ],
    );
  }
}

/// A note, opened: what it settled, and the button that undoes it.
class _ContraSheet extends ConsumerWidget {
  const _ContraSheet({required this.note});

  final Map<String, dynamic> note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${note['id']}';
    final lines = ref.watch(contraLinesProvider(id));

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
                    '${note['contra_no']}',
                    subtitle: contraSummary(note),
                  ),
                ),
                StatusChip('${note['status']}', compact: true),
              ],
            ),
            const Divider(height: 1),
            Flexible(
              child: AsyncView<List<Map<String, dynamic>>>(
                value: lines,
                onRetry: () => ref.invalidate(contraLinesProvider(id)),
                skeleton: const ListSkeleton(rows: 6, leading: false),
                builder: (rows) => ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final l = rows[i];
                    return ListTile(
                      dense: true,
                      title: Text('${l['doc_no']}'),
                      subtitle: Text(contraSide('${l['side']}')),
                      trailing: Money(num.tryParse('${l['amount'] ?? 0}')),
                    );
                  },
                ),
              ),
            ),
            if ('${note['status']}' == 'posted')
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => _void(context, ref, id),
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Undo it'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _void(BuildContext context, WidgetRef ref, String id) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Undo the contra'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Why',
              hintText: 'Agreed wrong, the wrong invoice, he disputed it',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Keep it'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Undo it'),
            ),
          ],
        );
      },
    );
    // The server refuses a blank reason, so the screen does not send
    // one: a contra reversed without a reason is a question somebody
    // asks later and nobody can answer.
    if (reason == null || reason.isEmpty || !context.mounted) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Put back',
      action: () => repo.voidContra(id, reason),
    );
    if (ok && context.mounted) Navigator.of(context).pop(true);
  }
}
