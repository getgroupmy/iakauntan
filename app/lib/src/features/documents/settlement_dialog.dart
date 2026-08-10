import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Records a customer receipt or a supplier payment and allocates it
/// against open documents. Both directions share this dialog because the
/// only differences are wording and which table is written.
Future<void> showSettlementDialog(
  BuildContext context,
  WidgetRef ref, {
  required DocKind kind,
  String? contactId,
  String? documentId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettlementDialog(
      kind: kind,
      initialContactId: contactId,
      preselectDocumentId: documentId,
    ),
  );
}

class _SettlementDialog extends ConsumerStatefulWidget {
  const _SettlementDialog({
    required this.kind,
    this.initialContactId,
    this.preselectDocumentId,
  });

  final DocKind kind;
  final String? initialContactId;
  final String? preselectDocumentId;

  @override
  ConsumerState<_SettlementDialog> createState() => _SettlementDialogState();
}

class _SettlementDialogState extends ConsumerState<_SettlementDialog> {
  final _reference = TextEditingController();
  final _charges = TextEditingController();

  String? _contactId;
  String? _bankAccountId;
  String _paymentMode = '03';
  DateTime _date = DateTime.now();
  bool _saving = false;

  /// Amount being applied to each open document.
  final Map<String, double> _allocations = {};

  bool get _isReceipt => widget.kind.isSales;

  @override
  void initState() {
    super.initState();
    _contactId = widget.initialContactId;
  }

  @override
  void dispose() {
    _reference.dispose();
    _charges.dispose();
    super.dispose();
  }

  double get _allocated =>
      _allocations.values.fold(0, (sum, v) => sum + v);

  double get _bankCharges => double.tryParse(_charges.text) ?? 0;

  Future<void> _save() async {
    if (_contactId == null) return;
    if (_allocated <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Allocate the payment to at least one document.'),
      ));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recordSettlement(
            kind: widget.kind,
            contactId: _contactId!,
            amount: _allocated,
            date: _date,
            bankAccountId: _bankAccountId,
            paymentModeCode: _paymentMode,
            reference: _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
            bankCharges: _bankCharges,
            allocations: [
              for (final e in _allocations.entries)
                if (e.value > 0) (documentId: e.key, amount: e.value),
            ],
          ),
      successMessage:
          _isReceipt ? 'Receipt recorded and posted' : 'Payment recorded and posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshLedgerData(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref
            .watch(contactsProvider(
                (type: widget.kind.contactType, search: '')))
            .value ??
        const <Contact>[];
    final banks = ref.watch(bankAccountsProvider).value ?? const [];
    final modes = ref.watch(paymentModesProvider).value ?? const [];

    return AlertDialog(
      title: Text(_isReceipt ? 'Receive payment' : 'Pay supplier'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _contactId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: '${widget.kind.contactLabel} *',
                ),
                items: [
                  for (final c in contacts)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() {
                  _contactId = v;
                  _allocations.clear();
                }),
              ),
              const SizedBox(height: 14),
              if (_contactId != null) _OpenDocuments(
                kind: widget.kind,
                contactId: _contactId!,
                allocations: _allocations,
                preselect: widget.preselectDocumentId,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: InkWell(
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
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _paymentMode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Method'),
                    items: [
                      for (final m in modes)
                        DropdownMenuItem(
                          value: m['code'] as String,
                          child: Text(m['description'] as String,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _paymentMode = v ?? '03'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _bankAccountId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Bank account'),
                    items: [
                      for (final b in banks)
                        DropdownMenuItem(
                          value: b['id'] as String,
                          child: Text(b['name'] as String,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _bankAccountId = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _charges,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Bank charges',
                      prefixText: 'RM ',
                    ),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference',
                  hintText: 'Cheque or transaction number',
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.colors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Total being settled',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Money(_allocated, bold: true),
                  ],
                ),
              ),
              if (_bankCharges > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _isReceipt
                        ? 'Bank will be debited ${Fmt.money(_allocated - _bankCharges)} after charges.'
                        : 'Bank will be credited ${Fmt.money(_allocated + _bankCharges)} including charges.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
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
          onPressed: _saving || _allocated <= 0 ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isReceipt ? 'Record receipt' : 'Record payment'),
        ),
      ],
    );
  }
}

/// Open documents for the chosen contact, each with an editable amount.
class _OpenDocuments extends ConsumerStatefulWidget {
  const _OpenDocuments({
    required this.kind,
    required this.contactId,
    required this.allocations,
    required this.onChanged,
    this.preselect,
  });

  final DocKind kind;
  final String contactId;
  final Map<String, double> allocations;
  final VoidCallback onChanged;
  final String? preselect;

  @override
  ConsumerState<_OpenDocuments> createState() => _OpenDocumentsState();
}

class _OpenDocumentsState extends ConsumerState<_OpenDocuments> {
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(outstandingProvider(
        (kind: widget.kind, contactId: widget.contactId)));

    return AsyncView(
      value: docs,
      loading: const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      builder: (list) {
        if (list.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Nothing outstanding for this '
              '${widget.kind.contactLabel.toLowerCase()}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }

        // Preselect the document the user came from, once.
        if (!_seeded) {
          _seeded = true;
          final target = widget.preselect;
          if (target != null) {
            final match = list.where((d) => d.id == target).firstOrNull;
            if (match != null) {
              widget.allocations[match.id] = match.balanceAmount;
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => widget.onChanged());
            }
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('Apply to'),
            for (final doc in list)
              _AllocationRow(
                doc: doc,
                amount: widget.allocations[doc.id] ?? 0,
                onChanged: (value) {
                  if (value <= 0) {
                    widget.allocations.remove(doc.id);
                  } else {
                    widget.allocations[doc.id] =
                        value.clamp(0, doc.balanceAmount);
                  }
                  widget.onChanged();
                },
              ),
          ],
        );
      },
    );
  }
}

class _AllocationRow extends StatefulWidget {
  const _AllocationRow({
    required this.doc,
    required this.amount,
    required this.onChanged,
  });

  final BusinessDocument doc;
  final double amount;
  final ValueChanged<double> onChanged;

  @override
  State<_AllocationRow> createState() => _AllocationRowState();
}

class _AllocationRowState extends State<_AllocationRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: widget.amount == 0 ? '' : widget.amount.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(covariant _AllocationRow old) {
    super.didUpdateWidget(old);
    // Reflect a programmatic change (preselect, or clamping) without
    // fighting the user while they type.
    final shown = double.tryParse(_controller.text) ?? 0;
    if ((shown - widget.amount).abs() > 0.001) {
      _controller.text =
          widget.amount == 0 ? '' : widget.amount.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final selected = widget.amount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) =>
                widget.onChanged(v == true ? doc.balanceAmount : 0),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(doc.docNo,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${Fmt.money(doc.balanceAmount, currency: doc.currency)} open'
                  '${doc.dueDate != null ? ' · due ${Fmt.date(doc.dueDate)}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: doc.isOverdue ? context.colors.danger : null,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 130,
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, prefixText: 'RM '),
              onChanged: (v) => widget.onChanged(double.tryParse(v) ?? 0),
            ),
          ),
        ],
      ),
    );
  }
}
