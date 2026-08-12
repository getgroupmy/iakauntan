import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Expense claims. An approved claim marked "pay with payroll" is picked
/// up by the next run and settled when that run posts, so nobody has to
/// remember to reimburse it separately.
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
        '${claim.payWithPayroll ? ' · reimbursed with salary' : ''}',
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
          : Money(
              claim.status == 'approved'
                  ? claim.approvedAmount
                  : claim.totalAmount,
              bold: true),
    );
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, bool approve) async {
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.decideClaim(claim.id, approve),
      successMessage: approve
          ? 'Approved — it will be reimbursed with the next payroll'
          : 'Rejected',
    );
    ref.invalidate(claimsProvider);
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
