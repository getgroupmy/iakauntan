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
import '../banking/new_bank_account_dialog.dart';
import '../contacts/new_contact_dialog.dart';

/// Which way the cheque goes, in the words a shop uses.
String chequeDirection(String? d) =>
    d == 'outgoing' ? 'We wrote it' : 'We were given it';

/// When it matures, said the way somebody reading a register asks.
///
/// The overdue case is the whole reason the register exists: a cheque
/// whose date went by while nobody was looking is money sitting in a
/// drawer, and "in -5 days" would bury that.
String chequeWhen(Map<String, dynamic> row) {
  final days = Fmt.toInt(row['days_to_go']);
  final status = '${row['status']}';
  if (status == 'cleared') return 'Cleared';
  if (status == 'bounced') return 'Returned';
  if (status == 'cancelled') return 'Handed back';
  if (days < 0) {
    final late = -days;
    return 'Was due $late day${late == 1 ? '' : 's'} ago — not banked';
  }
  if (days == 0) return 'Due today';
  return 'Due in $days day${days == 1 ? '' : 's'}';
}

/// What a cheque's row says under its number.
String chequeSummary(Map<String, dynamic> row) => [
  '${row['party']}',
  'no. ${row['cheque_no']}',
  if ('${row['bank_name'] ?? ''}'.trim().isNotEmpty) '${row['bank_name']}',
  Fmt.date(DateTime.tryParse('${row['cheque_date']}')),
].join(' · ');

/// Bad news for a cheque that bounced, and worth looking at for one
/// that matured and is still sitting there.
///
/// Only `held` and `deposited` can be late. A cheque that has cleared
/// is finished, and one that was cancelled or handed back is finished
/// too — their `days_to_go` goes on counting down and means nothing, so
/// colouring on it would put a warning against a cheque nobody owes
/// anything about.
Tone? chequeTone(Map<String, dynamic> row) {
  final status = '${row['status']}';
  if (status == 'bounced') return Tone.bad;
  if (status != 'held' && status != 'deposited') return null;
  return Fmt.toInt(row['days_to_go']) < 0 ? Tone.warn : null;
}

Color? chequeColour(BuildContext context, Map<String, dynamic> row) =>
    context.toneColour(chequeTone(row));

/// What can still be done to a cheque in this state.
///
/// Pure so the menu and the tests agree about the state machine rather
/// than each having its own copy of it.
List<String> chequeActions(String? status) => switch (status) {
  'held' => const ['deposit', 'clear', 'bounce', 'cancel'],
  'deposited' => const ['clear', 'bounce'],
  _ => const [],
};

/// Cheques dated in the future, and what became of them.
class ChequesScreen extends ConsumerWidget {
  const ChequesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(
      postDatedChequesProvider((direction: null, status: null)),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Post-dated cheques')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _record(context, ref),
        icon: const Icon(Icons.event_note_outlined),
        label: const Text('Record one'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: rows,
        onRetry: () => ref.invalidate(
          postDatedChequesProvider((direction: null, status: null)),
        ),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.event_note_outlined,
              title: 'No cheques on hand',
              message: 'A cheque dated next month is not money in the bank. '
                  'Record it here and the customer stops being chased, '
                  'while the bank balance waits until it clears.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = list[i];
              return ListTile(
                isThreeLine: true,
                leading: Icon(
                  '${c['direction']}' == 'outgoing'
                      ? Icons.call_made
                      : Icons.call_received,
                ),
                title: Text('${c['pdc_no']} · ${chequeDirection('${c['direction']}')}'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chequeSummary(c)),
                    Text(
                      [
                        chequeWhen(c),
                        if ('${c['bounce_reason'] ?? ''}'.trim().isNotEmpty)
                          '${c['bounce_reason']}',
                      ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: chequeColour(context, c),
                      ),
                    ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Money(num.tryParse('${c['amount']}')),
                    _menu(context, ref, c),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _menu(BuildContext context, WidgetRef ref, Map<String, dynamic> c) {
    final actions = chequeActions('${c['status']}');
    if (actions.isEmpty) return const SizedBox(width: 8);
    final id = '${c['id']}';
    return PopupMenuButton<String>(
      onSelected: (choice) => switch (choice) {
        'deposit' => _run(
          context,
          ref,
          () => ref.read(repoProvider)!.depositPdc(id),
          'Paid in',
        ),
        'clear' => _run(
          context,
          ref,
          () => ref.read(repoProvider)!.clearPdc(id),
          'Cleared',
        ),
        'bounce' => _withReason(
          context,
          ref,
          id,
          bounce: true,
        ),
        _ => _withReason(context, ref, id, bounce: false),
      },
      itemBuilder: (_) => [
        for (final a in actions)
          PopupMenuItem(
            value: a,
            child: Text(switch (a) {
              'deposit' => 'Pay it in',
              'clear' => 'It cleared',
              'bounce' => 'It bounced',
              _ => 'Hand it back',
            }),
          ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action,
    String message,
  ) async {
    final ok = await runWithFeedback(
      context,
      successMessage: message,
      action: action,
    );
    if (ok) {
      ref.invalidate(postDatedChequesProvider((direction: null, status: null)));
      ref.invalidate(pdcMaturingProvider);
    }
  }

  Future<void> _withReason(
    BuildContext context,
    WidgetRef ref,
    String id, {
    required bool bounce,
  }) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: Text(bounce ? 'It bounced' : 'Hand it back'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Why',
              hintText: bounce
                  ? 'Refer to drawer, signature differs, post-dated'
                  : 'He asked for it back and paid cash',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(bounce ? 'Record it' : 'Hand it back'),
            ),
          ],
        );
      },
    );
    // The server refuses a blank reason on both, and the reason is what
    // decides whether a cheque is re-presented or the customer chased.
    if (reason == null || reason.isEmpty || !context.mounted) return;
    await _run(
      context,
      ref,
      () => bounce
          ? ref.read(repoProvider)!.bouncePdc(id, reason)
          : ref.read(repoProvider)!.cancelPdc(id, reason),
      bounce ? 'Returned' : 'Handed back',
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChequeDialog(),
    );
    if (made == true) {
      ref.invalidate(postDatedChequesProvider((direction: null, status: null)));
      ref.invalidate(pdcMaturingProvider);
    }
  }
}

class _ChequeDialog extends ConsumerStatefulWidget {
  const _ChequeDialog();

  @override
  ConsumerState<_ChequeDialog> createState() => _ChequeDialogState();
}

class _ChequeDialogState extends ConsumerState<_ChequeDialog> {
  String _direction = 'incoming';
  String? _contact;
  String? _bank;
  final _chequeNo = TextEditingController();
  final _bankName = TextEditingController();
  final _amount = TextEditingController();
  // Default a month out: a cheque dated today is a receipt and the
  // server refuses it, so the picker should not start on a date that
  // cannot be used.
  DateTime _date = DateTime.now().add(const Duration(days: 30));
  final _settles = <String, double>{};
  bool _busy = false;

  @override
  void dispose() {
    _chequeNo.dispose();
    _bankName.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final repo = ref.read(repoProvider);
    if (repo == null || _contact == null) return;
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'In the register',
      action: () => repo.recordPdc(
        direction: _direction,
        contactId: _contact!,
        chequeNo: _chequeNo.text.trim(),
        chequeDate: _date,
        amount: double.tryParse(_amount.text) ?? 0,
        documents: [
          for (final e in _settles.entries)
            {'document': e.key, 'amount': e.value},
        ],
        bankAccountId: _bank,
        bankName: _bankName.text.trim().isEmpty ? null : _bankName.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final incoming = _direction == 'incoming';
    final contacts =
        ref
            .watch(
              contactsProvider((
                type: incoming ? 'customer' : 'supplier',
                search: '',
              )),
            )
            .valueOrNull ??
        const <Contact>[];
    final banks =
        ref.watch(bankAccountsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final amount = double.tryParse(_amount.text) ?? 0;
    final settled = _settles.values.fold<double>(0, (a, b) => a + b);
    // The server refuses a cheque that settles less than its face
    // value, so the button says no first rather than after the dialog
    // has closed.
    final settlesOk = settled == 0 || (settled * 100).round() == (amount * 100).round();

    return AlertDialog(
      title: const Text('A post-dated cheque'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'incoming',
                    label: Text('Given to us'),
                    icon: Icon(Icons.call_received, size: 18),
                  ),
                  ButtonSegment(
                    value: 'outgoing',
                    label: Text('Written by us'),
                    icon: Icon(Icons.call_made, size: 18),
                  ),
                ],
                selected: {_direction},
                onSelectionChanged: (s) => setState(() {
                  _direction = s.first;
                  _contact = null;
                  _settles.clear();
                }),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                options: contactPickerOptions(contacts),
                value: _contact,
                label: incoming ? 'From whom' : 'To whom',
                hint: 'Type a name or a code',
                createLabel: incoming ? 'Add customer' : 'Add supplier',
                onCreate: (typed) => createContactFromPicker(
                  context,
                  contactType: incoming ? 'customer' : 'supplier',
                  typed: typed,
                ),
                onChanged: (v) => setState(() {
                  _contact = v;
                  _settles.clear();
                }),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _chequeNo,
                      decoration: const InputDecoration(
                        labelText: 'Cheque number',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _bankName,
                      decoration: const InputDecoration(labelText: 'Which bank'),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'How much'),
                onChanged: (_) => setState(() {}),
              ),
              SearchablePicker<String>(
                options: bankPickerOptions(banks),
                createLabel: 'Add bank account',
                // 0529 made this list writable for the first
                // time. Until then a company that opened a
                // second account had nowhere in the product to
                // say so.
                onCreate: (typed) =>
                    createBankAccountFromPicker(context, typed: typed),
                value: _bank,
                label: incoming
                    ? 'Where it will be banked'
                    : 'Which of ours it is drawn on',
                onChanged: (v) => setState(() => _bank = v),
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined, size: 18),
                title: Text('Dated ${Fmt.date(_date)}'),
                trailing: const Text('Change'),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    // Tomorrow at the earliest: a cheque that can be
                    // banked today is a receipt.
                    firstDate: DateTime.now().add(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
              ),
              if (_contact != null) ...[
                const Divider(),
                SectionHeader(
                  'What it settles',
                  subtitle: settled == 0
                      ? 'Leave it blank to record the cheque on its own'
                      : 'Must come to ${Fmt.money(amount)}',
                ),
                _Settles(
                  contactId: _contact!,
                  incoming: incoming,
                  picked: _settles,
                  onChanged: () => setState(() {}),
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
          onPressed:
              _busy ||
                  _contact == null ||
                  amount <= 0 ||
                  _chequeNo.text.trim().isEmpty ||
                  !settlesOk
              ? null
              : _save,
          child: const Text('Record it'),
        ),
      ],
    );
  }
}

/// The outstanding documents a cheque can be put against — the same
/// list a contra uses, because "what does this party still owe" is the
/// same question.
class _Settles extends ConsumerWidget {
  const _Settles({
    required this.contactId,
    required this.incoming,
    required this.picked,
    required this.onChanged,
  });

  final String contactId;
  final bool incoming;
  final Map<String, double> picked;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows =
        ref.watch(contraCandidatesProvider(contactId)).valueOrNull ??
        const <Map<String, dynamic>>[];
    final side = incoming ? 'receivable' : 'payable';
    final mine = rows.where((r) => r['side'] == side).toList();
    if (mine.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(Space.md),
        child: Text('Nothing outstanding for them.'),
      );
    }
    return Column(
      children: [
        for (final r in mine)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: picked.containsKey('${r['document_id']}'),
            title: Text('${r['doc_no']}'),
            subtitle: Text(
              '${Fmt.money(num.tryParse('${r['outstanding']}'))} outstanding',
            ),
            onChanged: (v) {
              final id = '${r['document_id']}';
              if (v == true) {
                picked[id] =
                    (num.tryParse('${r['outstanding']}') ?? 0).toDouble();
              } else {
                picked.remove(id);
              }
              onChanged();
            },
          ),
      ],
    );
  }
}
