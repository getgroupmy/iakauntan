import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;
import 'statutory_charge_payment.dart';

/// The two charges that come with holding land in Malaysia.
///
/// Cukai tanah is set by the state and cukai pintu by the local
/// authority, so neither is worked out here. What this keeps is the due
/// date, because the penalty is for being late rather than for being
/// wrong.
const Map<String, String> statutoryChargeNames = {
  'quit_rent': 'Quit rent (cukai tanah)',
  'assessment': 'Assessment (cukai pintu)',
};

/// Whether the charge is billed in halves.
///
/// Assessment is half-yearly and quit rent is annual, so a half on a
/// quit rent is a period that does not exist -- and the unique key
/// counts it as a different charge, which is how the same year gets
/// entered twice.
bool hasHalves(String kind) => kind == 'assessment';

int? yearOf(String text) {
  final v = int.tryParse(text.trim());
  if (v == null || v < 1900 || v > 2200) return null;
  return v;
}

double? amountOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v < 0) return null;
  return v;
}

/// What a quit rent or assessment record is, given what was entered.
Map<String, dynamic> statutoryChargeValues({
  required String siteId,
  required String kind,
  required int periodYear,
  int? periodHalf,
  required double amount,
  required DateTime dueDate,
  DateTime? paidOn,
  String? authority,
  String? accountNo,
  String? reference,
  String? notes,
  /// Whether a supplier bill stands behind the charge.
  ///
  /// When one does, `paid_on` and the receipt it names are the
  /// database's to derive — `0387` overwrites the first from the bill's
  /// settlement and the second is not the record of anything. Sending
  /// either back would be sending the database its own answer, and
  /// blanking a value the screen never offered to edit.
  bool billed = false,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  return <String, dynamic>{
    'site_id': siteId,
    'kind': kind,
    'period_year': periodYear,
    'period_half': hasHalves(kind) ? periodHalf : null,
    'amount': amount,
    'due_date': Fmt.iso(dueDate),
    if (!billed) 'paid_on': paidOn == null ? null : Fmt.iso(paidOn),
    'authority': trimmed(authority),
    'account_no': trimmed(accountNo),
    // A payment reference for a bill nobody has paid is a reference to
    // nothing.
    if (!billed) 'reference': paidOn == null ? null : trimmed(reference),
    'notes': trimmed(notes),
  };
}

/// Record a quit rent or assessment, or mark one paid.
Future<bool> showStatutoryChargeSheet(
  BuildContext context, {
  required String siteId,
  Map<String, dynamic>? charge,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _StatutorySheet(siteId: siteId, charge: charge),
    ) ??
    false;

class _StatutorySheet extends ConsumerStatefulWidget {
  const _StatutorySheet({required this.siteId, this.charge});

  final String siteId;
  final Map<String, dynamic>? charge;

  @override
  ConsumerState<_StatutorySheet> createState() => _StatutorySheetState();
}

class _StatutorySheetState extends ConsumerState<_StatutorySheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _year;
  late final TextEditingController _amount;
  late final TextEditingController _authority;
  late final TextEditingController _accountNo;
  late final TextEditingController _reference;
  late final TextEditingController _notes;

  late String _kind;
  int? _half;
  DateTime? _due;
  DateTime? _paid;
  bool _saving = false;

  /// The bill this charge was raised on, if it was.
  ///
  /// While one stands, `paid_on` is the bill's and the guard in `0387`
  /// overwrites whatever is typed. Offering a date picker for a value
  /// the database is going to replace is how a screen teaches somebody
  /// the wrong thing about their own books, so it is shown and not
  /// asked for.
  String? _billId;
  String? _billNo;

  @override
  void initState() {
    super.initState();
    final c = widget.charge;
    _year = TextEditingController(
      text: '${c?['period_year'] ?? DateTime.now().year}',
    );
    _amount = TextEditingController(
      text: c?['amount'] == null ? '' : '${c!['amount']}',
    );
    _authority = TextEditingController(text: c?['authority'] as String? ?? '');
    _accountNo = TextEditingController(text: c?['account_no'] as String? ?? '');
    _reference = TextEditingController(text: c?['reference'] as String? ?? '');
    _notes = TextEditingController(text: c?['notes'] as String? ?? '');
    _kind = c?['kind'] as String? ?? 'assessment';
    _half = c?['period_half'] as int?;
    _due = c?['due_date'] == null
        ? null
        : DateTime.parse(c!['due_date'] as String);
    _paid =
        c?['paid_on'] == null ? null : DateTime.parse(c!['paid_on'] as String);
    _billId = c?['bill_document_id'] as String?;
    _billNo = (c?['purchase_documents'] as Map?)?['doc_no'] as String?;
  }

  @override
  void dispose() {
    for (final c in [
      _year,
      _amount,
      _authority,
      _accountNo,
      _reference,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Raise the supplier bill for the charge.
  ///
  /// Everything on it comes from the charge; the only thing this asks
  /// is who to bill it to, because the land office and the local
  /// council are contacts like any other and the books need to know
  /// which one it was.
  Future<void> _bill() async {
    final supplier = await showDialog<String>(
      context: context,
      builder: (_) => const _AuthorityPicker(),
    );
    if (supplier == null || !mounted) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.billStatutoryCharge(
            chargeId: widget.charge!['id'] as String,
            supplierId: supplier,
          ),
      successMessage: 'Billed',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(propertyStatutoryChargesProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final year = yearOf(_year.text);
    final amount = amountOf(_amount.text);
    if (year == null || amount == null || _due == null) return;

    setState(() => _saving = true);
    final values = statutoryChargeValues(
      siteId: widget.siteId,
      kind: _kind,
      periodYear: year,
      periodHalf: _half,
      amount: amount,
      dueDate: _due!,
      paidOn: _paid,
      billed: _billId != null,
      authority: _authority.text,
      accountNo: _accountNo.text,
      reference: _reference.text,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.savePropertyStatutoryCharge(
            values,
            id: widget.charge?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(propertyStatutoryChargesProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.charge == null
          ? 'Record a charge'
          : 'Amend the charge'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('statutory-kind'),
                  value: _kind,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Charge'),
                  items: [
                    for (final e in statutoryChargeNames.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _kind = v!),
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('statutory-year'),
                      controller: _year,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Year'),
                      validator: (v) =>
                          yearOf(v ?? '') == null ? 'A year' : null,
                    ),
                  ),
                  if (hasHalves(_kind)) ...[
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _half,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Half',
                          helperText: 'Assessment is half-yearly',
                        ),
                        items: const [
                          DropdownMenuItem(value: 1, child: Text('First')),
                          DropdownMenuItem(value: 2, child: Text('Second')),
                        ],
                        onChanged:
                            _saving ? null : (v) => setState(() => _half = v),
                      ),
                    ),
                  ],
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('statutory-amount'),
                      controller: _amount,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        helperText: 'From the bill',
                      ),
                      validator: (v) =>
                          amountOf(v ?? '') == null ? 'An amount' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Due',
                      value: _due,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _due = d),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _authority,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: 'Authority',
                        helperText: _kind == 'quit_rent'
                            ? 'The state land office'
                            : 'The local council',
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _accountNo,
                      enabled: !_saving,
                      decoration:
                          const InputDecoration(labelText: 'Account no'),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                if (_billId != null)
                  // Shown, not asked for. The bill is the record of the
                  // payment, and `0387` derives this from it.
                  InputDecorator(
                    key: const ValueKey('statutory-paid-by-bill'),
                    decoration: InputDecoration(
                      labelText: 'Paid on',
                      helperText: _billNo == null
                          ? 'From the bill this charge was raised on.'
                          : 'From bill $_billNo. Settle the bill and '
                              'this follows it.',
                    ),
                    child: Text(_paid == null
                        ? 'Billed, not yet paid'
                        : Fmt.date(_paid!)),
                  )
                else ...[
                  StatutoryDateField(
                    label: 'Paid on',
                    value: _paid,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _paid = d),
                  ),
                  if (_paid != null) ...[
                    const SizedBox(height: Space.md),
                    TextFormField(
                      key: const ValueKey('statutory-reference'),
                      controller: _reference,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Receipt number',
                        helperText: 'What the authority gave you for it.',
                      ),
                      // The same refusal the database makes, said where
                      // the person is typing rather than after a round
                      // trip. The database's is the one that counts.
                      validator: (v) => paidDateBlockedBecause(
                        hasBill: false,
                        paidOn: _paid,
                        reference: v,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (widget.charge != null)
          Tooltip(
            message: canBill(widget.charge!)
                ? 'Raise the supplier bill for it, so the charge is in '
                    'the ledger and its paid date comes from the bill.'
                : whyNotBillable(widget.charge!),
            child: TextButton(
              key: const ValueKey('statutory-bill'),
              onPressed: _saving || !canBill(widget.charge!) ? null : _bill,
              child: const Text('Bill it'),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('statutory-save'),
          onPressed: _saving || _due == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}


/// Who the charge is billed to.
///
/// A land office or a local council is a supplier contact like any
/// other. Nothing else is asked, because everything else on the bill
/// comes from the charge.
class _AuthorityPicker extends ConsumerStatefulWidget {
  const _AuthorityPicker();

  @override
  ConsumerState<_AuthorityPicker> createState() => _AuthorityPickerState();
}

class _AuthorityPickerState extends ConsumerState<_AuthorityPicker> {
  String? _id;

  @override
  Widget build(BuildContext context) {
    final suppliers = ref
            .watch(contactsProvider((type: 'supplier', search: '')))
            .valueOrNull ??
        const <Contact>[];

    return AlertDialog(
      title: const Text('Bill it to'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('statutory-authority'),
              value: _id,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Authority'),
              items: [
                for (final c in suppliers)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _id = v),
            ),
            const SizedBox(height: Space.md),
            Text(
              'The bill is made out of the charge: the same amount, the '
              'same due date, and the site, period and account number '
              'in the line. Nothing to retype.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('statutory-authority-ok'),
          onPressed: _id == null ? null : () => Navigator.of(context).pop(_id),
          child: const Text('Raise the bill'),
        ),
      ],
    );
  }
}
