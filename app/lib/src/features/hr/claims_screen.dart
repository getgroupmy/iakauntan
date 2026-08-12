import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Expense claims, and the two ways one gets settled.
///
/// Marked "pay with payroll", the next run picks it up and posts it, so
/// nobody has to remember to reimburse it separately. Not marked, it
/// waits here to be posted by hand — reimbursed out of a bank account
/// now, or accrued and paid later. Approval on its own settles nothing
/// and never did; before the Post action below, a claim that was not
/// going through payroll simply stopped at "approved" and never reached
/// the ledger at all.
class ClaimsScreen extends ConsumerStatefulWidget {
  const ClaimsScreen({super.key});

  @override
  ConsumerState<ClaimsScreen> createState() => _ClaimsScreenState();
}

class _ClaimsScreenState extends ConsumerState<ClaimsScreen> {
  String _status = 'submitted';

  @override
  Widget build(BuildContext context) {
    final claims = ref.watch(claimsProvider(_status));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claims'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: FilledButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _NewClaimDialog(),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New claim'),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: FilterBar(
            child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'submitted', label: Text('Awaiting')),
                  ButtonSegment(value: 'approved', label: Text('Approved')),
                  ButtonSegment(value: 'all', label: Text('All')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: claims,
        onRetry: () => ref.invalidate(claimsProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.receipt_long_outlined,
                title: 'No claims here',
                message: 'Submitted claims appear here for approval.',
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _ClaimTile(claim: list[i]),
              ),
      ),
    );
  }
}

class _ClaimTile extends ConsumerWidget {
  const _ClaimTile({required this.claim});

  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = claim.status == 'submitted';
    final postable = claim.awaitingPosting && ref.watch(canPostProvider);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      title: Row(children: [
        Flexible(
          child: Text(claim.title ?? claim.claimNo,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(claim.status, compact: true),
        if (claim.paidAt != null) ...[
          const SizedBox(width: Space.xs),
          const StatusChip('completed', compact: true),
        ],
      ]),
      subtitle: Text(
        '${claim.employeeName ?? ''} · ${claim.claimNo} · '
        '${Fmt.date(claim.claimDate)}'
        '${claim.payWithPayroll ? ' · reimbursed with salary' : ''}'
        '${claim.awaitingPosting ? ' · not yet in the ledger' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: pending
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              Money(claim.totalAmount, bold: true),
              const SizedBox(width: Space.md),
              TextButton(
                onPressed: () => _decide(context, ref, false),
                child: Text('Reject',
                    style: TextStyle(color: context.colors.danger)),
              ),
              FilledButton(
                onPressed: () => _decide(context, ref, true),
                child: const Text('Approve'),
              ),
            ])
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Money(
                claim.status == 'approved'
                    ? claim.approvedAmount
                    : claim.totalAmount,
                bold: true,
              ),
              if (postable) ...[
                const SizedBox(width: Space.md),
                FilledButton.tonal(
                  onPressed: () => _post(context, ref),
                  child: const Text('Post'),
                ),
              ],
            ]),
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, bool approve) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.decideClaim(claim.id, approve),
      // Approval is not settlement. Promising payroll reimbursement for
      // a claim that is not going through payroll is how an approved
      // claim gets forgotten.
      successMessage: !approve
          ? 'Rejected'
          : claim.payWithPayroll
              ? 'Approved — it will be reimbursed with the next payroll'
              : 'Approved — post it to put the expense in the ledger',
    );
    ref.invalidate(claimsProvider);
  }

  Future<void> _post(BuildContext context, WidgetRef ref) async {
    // A record rather than a bare `String?`: "accrue it" is a real
    // choice that sends no bank account, and cancelling must not be
    // indistinguishable from making it.
    final choice = await showDialog<({String? bankAccountId})>(
      context: context,
      builder: (_) => _PostClaimDialog(claim: claim),
    );
    if (choice == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .postExpenseClaim(claim.id, bankAccountId: choice.bankAccountId),
      successMessage: choice.bankAccountId == null
          ? 'Posted to accruals'
          : 'Posted and reimbursed',
      pendingMessage: 'Posting…',
    );
    ref.invalidate(claimsProvider);
    refreshLedgerData(ref);
  }
}

/// How an approved claim reaches the ledger.
///
/// Either way the expense is recognised now, against the account each
/// claim type names. The choice is only what sits on the other side: a
/// bank account, and the employee has been paid; nothing, and it goes to
/// Other Payables and Accruals until they are.
class _PostClaimDialog extends ConsumerStatefulWidget {
  const _PostClaimDialog({required this.claim});

  final ExpenseClaim claim;

  @override
  ConsumerState<_PostClaimDialog> createState() => _PostClaimDialogState();
}

class _PostClaimDialogState extends ConsumerState<_PostClaimDialog> {
  bool _reimburseNow = true;
  String? _bankAccountId;

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(bankAccountsProvider).valueOrNull ?? const [];
    if (_bankAccountId == null && accounts.isNotEmpty) {
      _bankAccountId = accounts.first['id'] as String;
    }
    // With no bank account on file there is nothing to pay from, so the
    // only honest option is to accrue.
    final canReimburse = accounts.isNotEmpty;

    return AlertDialog(
      title: const Text('Post claim'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.claim.claimNo} · '
              '${Fmt.money(widget.claim.approvedAmount)}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: Space.md),
            RadioListTile<bool>(
              value: true,
              groupValue: _reimburseNow && canReimburse,
              onChanged: canReimburse
                  ? (_) => setState(() => _reimburseNow = true)
                  : null,
              contentPadding: EdgeInsets.zero,
              title: const Text('Reimburse now'),
              subtitle: Text(canReimburse
                  ? 'Paid straight out of a bank account'
                  : 'No bank account has been set up yet'),
            ),
            if (_reimburseNow && canReimburse)
              Padding(
                padding: const EdgeInsets.only(left: 32, bottom: Space.sm),
                child: DropdownButtonFormField<String>(
                  value: _bankAccountId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      isDense: true, labelText: 'Pay from'),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: a['id'] as String,
                        child: Text(a['name']?.toString() ?? '',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _bankAccountId = v),
                ),
              ),
            RadioListTile<bool>(
              value: false,
              groupValue: _reimburseNow && canReimburse,
              onChanged: (_) => setState(() => _reimburseNow = false),
              contentPadding: EdgeInsets.zero,
              title: const Text('Accrue it'),
              subtitle: const Text(
                  'Recognise the expense now and pay the employee later'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (
              bankAccountId:
                  _reimburseNow && canReimburse ? _bankAccountId : null,
            ),
          ),
          child: const Text('Post'),
        ),
      ],
    );
  }
}

class _NewClaimDialog extends ConsumerStatefulWidget {
  const _NewClaimDialog();

  @override
  ConsumerState<_NewClaimDialog> createState() => _NewClaimDialogState();
}

class _NewClaimDialogState extends ConsumerState<_NewClaimDialog> {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  String? _typeId;
  final DateTime _date = DateTime.now();
  bool _saving = false;
  bool _payWithPayroll = true;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final types = ref.watch(claimTypesProvider);

    return AlertDialog(
      title: const Text('New claim'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'What is this for? *'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Give the claim a title' : null,
              ),
              const SizedBox(height: Space.md),
              types.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('$e'),
                data: (list) => DropdownButtonFormField<String>(
                  value: _typeId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final t in list)
                      DropdownMenuItem(
                        value: t['id'] as String,
                        child: Text(t['name']?.toString() ?? ''),
                      ),
                  ],
                  onChanged: (v) => setState(() => _typeId = v),
                ),
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description *'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Describe the expense' : null,
              ),
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Amount (RM) *', prefixText: 'RM '),
                validator: (v) {
                  final n = double.tryParse((v ?? '').trim());
                  if (n == null || n <= 0) return 'Enter an amount';
                  return null;
                },
              ),
              const SizedBox(height: Space.sm),
              // The column has always defaulted to true and nothing ever
              // set it, so every claim went down the payroll route by
              // accident rather than by choice.
              SwitchListTile(
                value: _payWithPayroll,
                onChanged: (v) => setState(() => _payWithPayroll = v),
                contentPadding: EdgeInsets.zero,
                title: const Text('Reimburse with the next payroll'),
                subtitle: Text(_payWithPayroll
                    ? 'The next payroll run pays and posts it'
                    : 'Somebody posts it from this screen once approved'),
              ),
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
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Submit'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final me = ref.read(myEmployeeProvider).valueOrNull;
    if (me == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Your login is not linked to an employee record yet'),
      ));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.createClaim(
            employeeId: me.id,
            title: _title.text.trim(),
            lines: [
              {
                'claim_type_id': _typeId,
                'expense_date': Fmt.iso(_date),
                'description': _description.text.trim(),
                'amount': double.parse(_amount.text.trim()),
              }
            ],
            payWithPayroll: _payWithPayroll,
          ),
      successMessage: 'Submitted for approval',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(claimsProvider);
      Navigator.pop(context);
    }
  }
}
