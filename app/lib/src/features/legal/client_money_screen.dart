import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../documents/client_money_copy.dart';

/// Client money in, and client money out.
///
/// The two movements a solicitor's office makes most often, and until
/// now neither had a page. The client ledger existed (0021), the
/// arithmetic that guards it existed, and the only way to reach either
/// was the matter screen — one matter at a time, through a dialog
/// headed "Type", which is where you go when you already know which
/// matter you are looking for.
///
/// Somebody banking the morning's cheques does not. They have a cheque
/// and a client, and the matter is what they are looking up.
///
/// Both directions are one screen because they differ in three things —
/// which RPC, which transaction types, and whether a payee is asked
/// for — and are otherwise the same list of the same ledger. Splitting
/// them into two files would mean two places to fix the next thing.
class ClientMoneyScreen extends ConsumerWidget {
  const ClientMoneyScreen({super.key, required this.inbound});

  /// True for money received to hold; false for money paid out.
  final bool inbound;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(
      inbound ? clientReceiptsProvider : clientPayoutsProvider,
    );
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      floatingActionButton: !canPost
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _record(context, ref),
              icon: Icon(inbound ? Icons.south_west : Icons.north_east),
              label: Text(inbound ? 'Receive' : 'Pay out'),
            ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 980,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                inbound ? 'Money received on account' : 'Paid out for clients',
                subtitle: inbound
                    ? 'Held in the client account for a matter until '
                          'there is a bill to settle. Not income.'
                    : 'Disbursements paid on a client’s behalf, and the '
                          'balance returned when a matter closes.',
              ),
              const _HeldTotal(),
              const SizedBox(height: Space.md),
              AsyncView<List<Map<String, dynamic>>>(
                value: rows,
                onRetry: () => ref.invalidate(
                  inbound ? clientReceiptsProvider : clientPayoutsProvider,
                ),
                builder: (list) => list.isEmpty
                    ? EmptyState(
                        icon: inbound
                            ? Icons.account_balance_wallet_outlined
                            : Icons.payments_outlined,
                        title: inbound
                            ? 'Nothing received on account yet'
                            : 'Nothing paid out yet',
                        message: inbound
                            ? 'Money a client places with the firm before '
                                  'the work is done goes here, against the '
                                  'matter it is for.'
                            : 'Stamp duty, search fees, and the balance a '
                                  'client gets back when the matter closes.',
                      )
                    : Card(
                        child: Column(
                          children: [
                            for (final r in list) _Line(row: r),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ClientMoneyDialog(inbound: inbound),
    );
    if (saved == true) {
      ref
        ..invalidate(clientReceiptsProvider)
        ..invalidate(clientPayoutsProvider)
        ..invalidate(matterClientBalancesProvider)
        ..invalidate(matterSummaryProvider);
    }
  }
}

/// What the firm is holding altogether.
///
/// The number a partner is asked for and the one the client account
/// reconciliation starts from. Summed from the same rows the matter
/// pickers read, so the total and the parts cannot disagree.
class _HeldTotal extends ConsumerWidget {
  const _HeldTotal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final held = ref.watch(matterClientBalancesProvider).valueOrNull;
    if (held == null) return const SizedBox.shrink();
    final total = held.values.fold<double>(0, (sum, v) => sum + v);
    final matters = held.values.where((v) => v > 0).length;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.savings_outlined),
        title: Text('${Fmt.money(total)} held in the client account'),
        subtitle: Text(
          matters == 1
              ? 'for one matter'
              : 'across $matters matters',
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final matter = row['matters'] as Map<String, dynamic>?;
    final client = matter?['contacts'] as Map<String, dynamic>?;
    final amount = Fmt.toDouble(row['amount']);
    final type = '${row['transaction_type']}';
    return ListTile(
      key: ValueKey('client-txn-${row['id']}'),
      title: Text(
        [
          if (matter != null) '${matter['matter_no']}',
          if (client != null) '${client['name']}',
        ].join(' · '),
      ),
      subtitle: Text(
        [
          Fmt.date(DateTime.tryParse('${row['transaction_date']}')),
          if ((row['description'] ?? '').toString().isNotEmpty)
            '${row['description']}',
          if ((row['payee'] ?? '').toString().isNotEmpty)
            'to ${row['payee']}',
          if (type == 'refund') 'refund',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Text(
        Fmt.money(amount.abs()),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _ClientMoneyDialog extends ConsumerStatefulWidget {
  const _ClientMoneyDialog({required this.inbound});

  final bool inbound;

  @override
  ConsumerState<_ClientMoneyDialog> createState() =>
      _ClientMoneyDialogState();
}

class _ClientMoneyDialogState extends ConsumerState<_ClientMoneyDialog> {
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _payee = TextEditingController();
  final _reference = TextEditingController();

  String? _matterId;
  DateTime _date = DateTime.now();
  bool _refund = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_amount, _description, _payee, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  double _held(WidgetRef ref) {
    if (_matterId == null) return 0;
    return ref.watch(matterClientBalancesProvider).valueOrNull?[_matterId] ?? 0;
  }

  Future<void> _save() async {
    final matter = _matterId;
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (matter == null) {
      _say('Choose the matter this is for.');
      return;
    }
    if (amount <= 0) {
      _say('Type the amount.');
      return;
    }

    setState(() => _busy = true);
    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Posting…',
      successMessage: widget.inbound
          ? receiptDone(ReceiptDestination.onAccount)
          : paymentDone(PaymentSource.clientAccount),
      action: () => widget.inbound
          ? repo.receiveClientMoney(
              matterId: matter,
              amount: amount,
              date: _date,
              description: _text(_description),
              reference: _text(_reference),
            )
          : repo.payFromClientAccount(
              matterId: matter,
              amount: amount,
              payee: _text(_payee),
              date: _date,
              description: _text(_description),
              reference: _text(_reference),
              refund: _refund,
            ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final matters = ref.watch(mattersProvider(
      (status: 'open', search: ''),
    )).valueOrNull ?? const <Matter>[];
    final held = _held(ref);
    final typed = double.tryParse(_amount.text.trim()) ?? 0;
    // Only on the way out. Money coming in has no ceiling.
    final warning = widget.inbound
        ? null
        : overdrawWarning(held: held, amount: typed);

    return AlertDialog(
      title: Text(
        widget.inbound ? 'Receive into the client account' : 'Pay out for a client',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchablePicker<String>(
                key: const ValueKey('client-money-matter'),
                options: [
                  for (final m in matters)
                    PickerOption<String>(
                      value: m.id,
                      label: '${m.matterNo} · ${m.name}',
                      sublabel: m.clientName,
                    ),
                ],
                value: _matterId,
                label: 'Matter *',
                hint: 'Type a matter number, a name or the client',
                onChanged: (v) => setState(() => _matterId = v),
              ),
              if (_matterId != null) ...[
                const SizedBox(height: Space.xs),
                Text(
                  matterBalanceLine(held),
                  key: const ValueKey('client-money-balance'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Space.sm),
              TextField(
                key: const ValueKey('client-money-amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Amount *',
                  prefixText: 'RM ',
                  // The server refuses this too, and its message is the
                  // one that counts. This exists so the refusal arrives
                  // while the field is still in front of them.
                  errorText: warning,
                ),
              ),
              const SizedBox(height: Space.sm),
              // The same shape the matter screen uses, rather than a
              // widget of this file's own: two date fields in one
              // module that look different are two things to learn.
              InkWell(
                key: const ValueKey('client-money-date'),
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
              if (!widget.inbound) ...[
                const SizedBox(height: Space.sm),
                TextField(
                  controller: _payee,
                  decoration: const InputDecoration(
                    labelText: 'Paid to',
                    helperText: 'The stamp office, the land office, the '
                        'client themselves.',
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('client-money-refund'),
                  contentPadding: EdgeInsets.zero,
                  value: _refund,
                  onChanged: (v) => setState(() => _refund = v),
                  title: const Text('This is a refund to the client'),
                  subtitle: const Text(
                    'The balance going back at the end of a matter, '
                    'rather than a disbursement paid on their behalf.',
                  ),
                ),
              ],
              const SizedBox(height: Space.sm),
              TextField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'What it is for'),
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference',
                  helperText: 'The cheque number, or the transfer reference.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy || warning != null ? null : _save,
          child: Text(widget.inbound ? 'Receive' : 'Pay out'),
        ),
      ],
    );
  }
}
