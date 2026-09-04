import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/attachments_repository.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../shared/attachments_card.dart';
import '../shared/receipt_capture.dart';
import 'mileage_claim.dart';

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
  /// One of the claim statuses, or `mine` — which is not a status at
  /// all but "the ones waiting on me". It shares this field because it
  /// sits in the same segmented control and only one can be showing.
  String _filter = 'mine';

  bool get _mine => _filter == 'mine';

  @override
  Widget build(BuildContext context) {
    final claims = _mine
        ? ref.watch(claimsAwaitingMeProvider)
        : ref.watch(claimsProvider(_filter));

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
                  // First, and the one the screen opens on. A chain of
                  // four approvals makes "every submitted claim in the
                  // company" the wrong thing to greet an approver with.
                  ButtonSegment(
                      value: 'mine',
                      icon: Icon(Icons.how_to_reg_outlined, size: 18),
                      label: Text('For me')),
                  ButtonSegment(value: 'submitted', label: Text('Awaiting')),
                  ButtonSegment(value: 'approved', label: Text('Approved')),
                  ButtonSegment(value: 'all', label: Text('All')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) => setState(() => _filter = s.first),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: claims,
        onRetry: () => _mine
            ? ref.invalidate(claimsAwaitingMeProvider)
            : ref.invalidate(claimsProvider),
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: _mine
                    ? Icons.done_all_outlined
                    : Icons.receipt_long_outlined,
                title: _mine ? 'Nothing waiting on you' : 'No claims here',
                // Said separately because an empty "For me" is good news
                // and an empty "Awaiting" is not the same thing at all.
                message: _mine
                    ? 'Claims appear here when the chain reaches you.'
                    : 'Submitted claims appear here for approval.',
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
      // Every claim opens, so every claim can carry its receipt — the
      // one being approved as much as the one being typed.
      onTap: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ClaimSheet(claim: claim),
      ),
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
      // Deliberately not "Approved". One press clears one stage, and
      // the claim may still be sitting with three other people — saying
      // otherwise is how somebody goes looking for a reimbursement that
      // was never authorised. The chain on the claim says where it
      // actually is.
      successMessage: !approve
          ? 'Rejected'
          : 'Your approval is recorded — open the claim to see who is next',
    );
    ref.invalidate(claimsProvider);
    // The queue is derived from the chain, so a decision
    // changes it as surely as it changes the list.
    ref.invalidate(claimsAwaitingMeProvider);
    ref.invalidate(claimApprovalsProvider(claim.id));
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
    // The queue is derived from the chain, so a decision
    // changes it as surely as it changes the list.
    ref.invalidate(claimsAwaitingMeProvider);
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
                child: SearchablePicker<String>(
                  options: bankPickerOptions(accounts),
                  value: _bankAccountId,
                  label: 'Pay from',
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
  final _quantity = TextEditingController();
  String? _typeId;

  /// The claim type row behind `_typeId`, or null while the list is
  /// still arriving — which is a first frame rather than an error, and
  /// is why every function in `mileage_claim.dart` takes a nullable.
  Map<String, dynamic>? _selectedType(
    AsyncValue<List<Map<String, dynamic>>> types,
  ) {
    final list = types.valueOrNull;
    if (list == null || _typeId == null) return null;
    for (final t in list) {
      if (t['id'] == _typeId) return t;
    }
    return null;
  }
  final DateTime _date = DateTime.now();
  bool _saving = false;
  bool _payWithPayroll = true;

  /// Receipts chosen before the claim exists.
  ///
  /// Held as bytes rather than uploaded against a placeholder, which is
  /// how the scanned-bill flow does it: a claimant has no permission to
  /// write anything against an id that is not yet a claim of theirs, so
  /// the upload waits until there is a claim to hang it on.
  final _receipts = <CapturedFile>[];

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _amount.dispose();
    _quantity.dispose();
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
                data: (list) => SearchablePicker<String>(
                  options: [
                    for (final t in list)
                      PickerOption<String>(
                        value: t['id'] as String,
                        label: t['name']?.toString() ?? '',
                      ),
                  ],
                  value: _typeId,
                  label: 'Category',
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
              // 0368. A mileage type is claimed by the distance and
              // priced by the database, so asking for a ringgit figure
              // here would ask for a number that is then ignored — and
              // the distance, the one thing anybody could check against
              // a map, would go unrecorded.
              if (isMileage(_selectedType(types)))
                _MileageField(
                  controller: _quantity,
                  claimType: _selectedType(types),
                )
              else
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
              const SizedBox(height: Space.md),
              _ReceiptPicker(
                files: _receipts,
                onChanged: () => setState(() {}),
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

    final repo = ref.read(repoProvider)!;
    final ok = await runWithFeedback(
      context,
      action: () async {
        final id = await repo.createClaim(
          employeeId: me.id,
          title: _title.text.trim(),
          lines: [
            {
              'claim_type_id': _typeId,
              'expense_date': Fmt.iso(_date),
              'description': _description.text.trim(),
              // The distance for a measured type; the database prices
              // it and ignores anything sent as an amount. Sending both
              // would be two numbers that should agree and are stored
              // separately, which is the failure 0368 exists to remove.
              if (isMileage(_selectedType(ref.read(claimTypesProvider))))
                'quantity': double.parse(_quantity.text.trim())
              else
                'amount': double.parse(_amount.text.trim()),
            }
          ],
          payWithPayroll: _payWithPayroll,
        );

        // Now that there is a claim to attach to. A failure here must
        // not lose the claim, so it is reported and the claim stands —
        // the receipt can be added again from the claim itself.
        for (final file in _receipts) {
          await repo.uploadAttachment(
            table: 'expense_claims',
            recordId: id,
            fileName: file.name,
            bytes: file.bytes,
            mimeType: file.mimeType,
          );
        }
      },
      successMessage: 'Submitted for approval',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(claimsProvider);
    // The queue is derived from the chain, so a decision
    // changes it as surely as it changes the list.
    ref.invalidate(claimsAwaitingMeProvider);
      Navigator.pop(context);
    }
  }
}


/// Receipts chosen while a claim is still being typed.
///
/// A claim is a request to be paid back for money already spent, and the
/// receipt is the evidence. Offering it here rather than only afterwards
/// matters: somebody photographing a receipt is holding it *now*, and
/// "attach it later from the claim" is how a claim reaches a manager
/// with nothing behind it.
class _ReceiptPicker extends StatelessWidget {
  const _ReceiptPicker({required this.files, required this.onChanged});

  final List<CapturedFile> files;
  final VoidCallback onChanged;

  Future<void> _add(CapturedFile? file) async {
    if (file == null) return;
    files.add(file);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text('Receipts',
                style: Theme.of(context).textTheme.labelLarge),
          ),
          if (cameraLikely)
            IconButton(
              tooltip: 'Photograph it',
              icon: const Icon(Icons.photo_camera_outlined, size: 20),
              onPressed: () async => _add(await photographReceipt()),
            ),
          TextButton.icon(
            onPressed: () async => _add(await pickReceipt()),
            icon: const Icon(Icons.attach_file, size: 18),
            label: const Text('Attach'),
          ),
        ]),
        if (files.isEmpty)
          Text(
            'None yet. A claim with its receipt behind it is approved '
            'faster than one without.',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.xs,
            children: [
              for (final file in files)
                Chip(
                  label: Text(file.name, overflow: TextOverflow.ellipsis),
                  onDeleted: () {
                    files.remove(file);
                    onChanged();
                  },
                ),
            ],
          ),
      ],
    );
  }
}

/// One claim, with whatever was filed against it.
///
/// Reached by tapping the claim. Every claim can carry documents — the
/// one being typed, through the picker above, and every claim that
/// already exists, through here — which is what "all claims should have
/// an attachment option" asks for.
class _ClaimSheet extends ConsumerWidget {
  const _ClaimSheet({required this.claim});

  final ExpenseClaim claim;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(claim.title ?? claim.claimNo,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              StatusChip(claim.status, compact: true),
            ]),
            const SizedBox(height: Space.xs),
            Text(
              '${claim.claimNo} · ${Fmt.date(claim.claimDate)}'
              '${claim.employeeName == null ? '' : ' · ${claim.employeeName}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            Money(claim.totalAmount, bold: true),
            const SizedBox(height: Space.lg),
            Flexible(
              child: SingleChildScrollView(
                child: Column(children: [
                  _ApprovalChain(claimId: claim.id),
                  const SizedBox(height: Space.md),
                  AttachmentsCard(
                  table: 'expense_claims',
                  recordId: claim.id,
                  title: 'Receipts',
                  // The claimant is not staff, and the database knows
                  // it. Once the claim is in the ledger its paperwork
                  // stops being theirs to change — which is exactly what
                  // `app.can_attach_to` enforces, so a button offered
                  // here is one the database will honour.
                  canAttach: claim.glEntryId == null,
                  subtitle: claim.glEntryId != null
                      // Said plainly, because the buttons go away and an
                      // unexplained absence reads as a fault.
                      ? 'This claim is in the ledger, so its paperwork is '
                          'now the accountant\'s record.'
                      : 'The evidence behind the claim.',
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Who has to see this claim, and who already has.
///
/// A claim goes to the manager who knows whether the trip happened, the
/// unit head who owns the budget, HR who owns the policy and finance who
/// owns the money — in that order, one at a time. Showing the whole
/// chain rather than only the current step answers the question people
/// actually ask, which is not "what is the status" but "who is it
/// sitting with, and how much longer".
class _ApprovalChain extends ConsumerWidget {
  const _ApprovalChain({required this.claimId});

  final String claimId;

  static const _stageNames = {
    'manager': 'Department manager',
    'unit_head': 'Unit head',
    'hr': 'Human resources',
    'finance': 'Finance',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final steps = ref.watch(claimApprovalsProvider(claimId));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Approvals'),
            AsyncView(
              value: steps,
              onRetry: () => ref.invalidate(claimApprovalsProvider(claimId)),
              loading: const LinearProgressIndicator(),
              builder: (list) {
                if (list.isEmpty) {
                  return Text(
                    'No approval chain — this claim predates it, or it was '
                    'not submitted for approval.',
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                }
                // The first step still pending is the one it is waiting
                // on; everything after that has not been asked yet.
                final waitingOn = list.indexWhere(
                    (s) => s['status']?.toString() == 'pending');
                return Column(children: [
                  for (var i = 0; i < list.length; i++)
                    _Step(
                      row: list[i],
                      label: _stageNames[list[i]['stage']?.toString()] ??
                          '${list[i]['stage']}',
                      isNext: i == waitingOn,
                    ),
                ]);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.row, required this.label, required this.isNext});

  final Map<String, dynamic> row;
  final String label;
  final bool isNext;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'pending';
    final approver = row['approver'];
    final name = approver is Map ? approver['full_name']?.toString() : null;
    final note = row['note']?.toString();

    final (icon, colour) = switch (status) {
      'approved' => (Icons.check_circle, context.colors.success),
      'rejected' => (Icons.cancel, context.colors.danger),
      // Skipped is not a failure and should not be red. Nobody held the
      // role, the chain went round it, and the claim is none the worse.
      'skipped' => (Icons.remove_circle_outline, context.scheme.outline),
      _ => (
          isNext ? Icons.hourglass_top : Icons.circle_outlined,
          isNext ? context.colors.warning : context.scheme.outline
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: colour),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name == null ? label : '$label · $name',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isNext ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (isNext)
                Text('Waiting on this',
                    style: TextStyle(
                        fontSize: 11, color: context.colors.warning)),
              if (note != null && note.isNotEmpty)
                Text(note,
                    style: TextStyle(
                        fontSize: 11,
                        color: context.scheme.onSurfaceVariant)),
              if (row['decided_at'] != null)
                Text(
                  Fmt.dateTime(DateTime.tryParse('${row['decided_at']}')),
                  style: TextStyle(
                      fontSize: 11, color: context.scheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

/// The distance box on a claim measured by the kilometre.
///
/// Says what it comes to as the number is typed. The database computes
/// the figure that is stored — two numbers that should agree and are
/// stored separately are two numbers that will not — and this is the
/// same arithmetic for the one thing a form has to do: tell somebody
/// what they are about to claim before they send it.
class _MileageField extends StatefulWidget {
  const _MileageField({required this.controller, required this.claimType});

  final TextEditingController controller;
  final Map<String, dynamic>? claimType;

  @override
  State<_MileageField> createState() => _MileageFieldState();
}

class _MileageFieldState extends State<_MileageField> {
  @override
  Widget build(BuildContext context) {
    final comes = mileageAmount(
      claimType: widget.claimType,
      quantity: widget.controller.text,
    );
    final rate = (widget.claimType?['rate_per_unit'] as num?)?.toDouble() ?? 0;
    final unit = (widget.claimType?['unit_label'] as String?)?.trim();

    return TextFormField(
      controller: widget.controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: claimQuantityLabel(widget.claimType),
        suffixText: unit == null || unit.isEmpty ? null : unit,
        helperText: comes != null
            ? 'Comes to ${Fmt.money(comes)}'
            : rate > 0
            ? 'At ${Fmt.money(rate)} each'
            : null,
      ),
      validator: (v) => mileageBlockedBecause(
        claimType: widget.claimType,
        quantity: v ?? '',
      ),
    );
  }
}
