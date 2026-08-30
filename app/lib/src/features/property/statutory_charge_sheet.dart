import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

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
    'paid_on': paidOn == null ? null : Fmt.iso(paidOn),
    'authority': trimmed(authority),
    'account_no': trimmed(accountNo),
    // A payment reference for a bill nobody has paid is a reference to
    // nothing.
    'reference': paidOn == null ? null : trimmed(reference),
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
                StatutoryDateField(
                  label: 'Paid on',
                  value: _paid,
                  enabled: !_saving,
                  onChanged: (d) => setState(() => _paid = d),
                ),
                if (_paid != null) ...[
                  const SizedBox(height: Space.md),
                  TextFormField(
                    controller: _reference,
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      labelText: 'Payment reference',
                    ),
                  ),
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
