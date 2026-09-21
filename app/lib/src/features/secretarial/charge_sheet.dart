import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart';

/// The kinds of charge the register sees, in the words a secretary uses.
///
/// `charge_type` is free text in the schema, deliberately — the list is
/// not statutory and a security nobody anticipated is still a charge.
/// These are the common ones, offered rather than enforced.
const List<String> chargeTypes = [
  'Debenture',
  'Fixed charge',
  'Floating charge',
  'Fixed and floating',
  'Lien',
  'Pledge',
  'Assignment',
  'Guarantee',
];

/// When s.352 requires the charge to be lodged.
///
/// Thirty days from creation. Asserted rather than eyeballed, because
/// missing it does not produce a late fee: an unregistered charge is
/// **void against the liquidator**, so the security a bank thinks it
/// holds is not there at the only moment it matters.
DateTime registrationDeadline(DateTime createdOn) =>
    createdOn.add(const Duration(days: 30));

/// Whether the thirty days have run out with nothing lodged.
bool registrationOverdue(
  DateTime createdOn, {
  DateTime? registeredOn,
  required DateTime asAt,
}) =>
    registeredOn == null && asAt.isAfter(registrationDeadline(createdOn));

/// An amount as typed, or null.
///
/// Blank is null rather than zero, for the reason the shareholding box
/// has: a charge securing an amount nobody recorded is not a charge
/// securing nothing.
double? amountOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v < 0) return null;
  return v;
}

/// What a charge is, given what was entered.
///
/// Pure, and apart from the sheet, because three of its rules are
/// silent when broken.
Map<String, dynamic> chargeValues({
  required String entityId,
  required String chargeeName,
  required DateTime createdOn,
  String? chargeNo,
  String? chargeType,
  DateTime? registeredOn,
  double? amountSecured,
  String currency = 'MYR',
  String? propertyCharged,
  String? ranking,
  DateTime? satisfiedOn,
  DateTime? satisfactionFiledOn,
  String? notes,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  final satisfied = satisfiedOn != null;
  return <String, dynamic>{
    'entity_id': entityId,
    'chargee_name': chargeeName.trim(),
    'created_on': Fmt.iso(createdOn),
    'charge_no': trimmed(chargeNo),
    'charge_type': trimmed(chargeType),
    'registered_on': registeredOn == null ? null : Fmt.iso(registeredOn),
    'amount_secured': amountSecured,
    'currency': currency,
    'property_charged': trimmed(propertyCharged),
    'ranking': trimmed(ranking),
    'satisfied_on': satisfied ? Fmt.iso(satisfiedOn) : null,
    // A satisfaction cannot be filed for a charge that has not been
    // satisfied. Kept without its date it is a memorandum of
    // satisfaction for a charge still outstanding, which is the one
    // thing on this register a chargee would litigate about.
    'satisfaction_filed_on': satisfied && satisfactionFiledOn != null
        ? Fmt.iso(satisfactionFiledOn)
        : null,
    'notes': trimmed(notes),
  };
}

/// Register a charge, amend it, or record its satisfaction.
Future<bool> showChargeSheet(
  BuildContext context, {
  required String entityId,
  CorpCharge? charge,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _ChargeSheet(entityId: entityId, charge: charge),
    ) ??
    false;

class _ChargeSheet extends ConsumerStatefulWidget {
  const _ChargeSheet({required this.entityId, this.charge});

  final String entityId;
  final CorpCharge? charge;

  @override
  ConsumerState<_ChargeSheet> createState() => _ChargeSheetState();
}

class _ChargeSheetState extends ConsumerState<_ChargeSheet> {
  final _formKey = GlobalKey<FormState>();
  final _chargee = TextEditingController();
  final _chargeNo = TextEditingController();
  final _amount = TextEditingController();
  final _property = TextEditingController();
  final _ranking = TextEditingController();
  final _notes = TextEditingController();

  late String? _type = widget.charge?.chargeType;
  // Read-only for now: `currency` is on the row and every charge on
  // the register so far is in ringgit. The box shows it rather than
  // pretending the column does not exist.
  late final String _currency = widget.charge?.currency ?? 'MYR';
  late DateTime? _createdOn = widget.charge?.createdOn;
  late DateTime? _registeredOn = widget.charge?.registeredOn;
  late DateTime? _satisfiedOn = widget.charge?.satisfiedOn;
  late DateTime? _satisfactionFiledOn = widget.charge?.satisfactionFiledOn;
  bool _saving = false;

  bool get _isNew => widget.charge == null;

  @override
  void initState() {
    super.initState();
    final c = widget.charge;
    _chargee.text = c?.chargeeName ?? '';
    _chargeNo.text = c?.chargeNo ?? '';
    final a = c?.amountSecured;
    _amount.text = a == null ? '' : a.toStringAsFixed(2);
    _property.text = c?.propertyCharged ?? '';
    _ranking.text = c?.ranking ?? '';
    _notes.text = c?.notes ?? '';
    if (_isNew) _createdOn = DateTime.now();
  }

  @override
  void dispose() {
    for (final c in [
      _chargee,
      _chargeNo,
      _amount,
      _property,
      _ranking,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_createdOn == null) return;

    setState(() => _saving = true);
    final values = chargeValues(
      entityId: widget.entityId,
      chargeeName: _chargee.text,
      createdOn: _createdOn!,
      chargeNo: _chargeNo.text,
      chargeType: _type,
      registeredOn: _registeredOn,
      amountSecured: amountOf(_amount.text),
      currency: _currency,
      propertyCharged: _property.text,
      ranking: _ranking.text,
      satisfiedOn: _satisfiedOn,
      satisfactionFiledOn: _satisfactionFiledOn,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveCorpCharge(values, id: widget.charge?.id),
      successMessage: _isNew ? 'Charge registered' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpChargesProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  /// What the thirty days say right now, in a sentence.
  Widget? _deadlineNote(BuildContext context) {
    final created = _createdOn;
    if (created == null || _satisfiedOn != null) return null;

    final due = registrationDeadline(created);
    final overdue = registrationOverdue(
      created,
      registeredOn: _registeredOn,
      asAt: DateTime.now(),
    );

    final (text, colour) = overdue
        ? (
            'Thirty days ran out on ${Fmt.date(due)}. An unregistered '
            'charge is void against the liquidator.',
            context.colors.danger,
          )
        : _registeredOn != null
            ? (
                'Lodged. The thirty days closed on ${Fmt.date(due)}.',
                context.colors.success,
              )
            : (
                'Must be lodged by ${Fmt.date(due)} — thirty days from '
                'creation (s.352).',
                context.colors.warning,
              );

    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(overdue ? Icons.error_outline : Icons.schedule,
            size: 14, color: colour),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colour)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = _deadlineNote(context);

    return AlertDialog(
      title: Text(_isNew ? 'Register a charge' : 'Amend the charge'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('charge-chargee'),
                  controller: _chargee,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Chargee',
                    helperText: 'Who holds the security',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'A charge is held by somebody'
                      : null,
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: chargeTypes.contains(_type) ? _type : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Kind'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('—')),
                        for (final t in chargeTypes)
                          DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged:
                          _saving ? null : (v) => setState(() => _type = v),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _chargeNo,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        labelText: 'Charge no.',
                        helperText: 'From SSM, once lodged',
                      ),
                    ),
                  ),
                ]),

                const SizedBox(height: Space.md),
                Row(children: [
                  SizedBox(
                    width: 90,
                    child: TextFormField(
                      controller: TextEditingController(text: _currency),
                      enabled: false,
                      decoration: const InputDecoration(labelText: 'Currency'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('charge-amount'),
                      controller: _amount,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Amount secured',
                        helperText: 'Leave empty if the charge is unlimited',
                      ),
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return null;
                        final n = double.tryParse(t.replaceAll(',', ''));
                        if (n == null) return 'A number, or nothing';
                        if (n < 0) return 'Not less than nothing';
                        return null;
                      },
                    ),
                  ),
                ]),

                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Created on',
                  value: _createdOn,
                  enabled: !_saving,
                  lastDate: DateTime.now(),
                  helperText: 'The date of the instrument — the clock starts '
                      'here',
                  onChanged: (d) => setState(() => _createdOn = d),
                ),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Lodged with SSM',
                  value: _registeredOn,
                  enabled: !_saving,
                  // Not before the instrument existed. A charge lodged
                  // before it was created is a date nobody would notice
                  // and a register that cannot be right.
                  firstDate: _createdOn,
                  lastDate: DateTime.now(),
                  onChanged: (d) => setState(() => _registeredOn = d),
                ),
                if (note != null) note,

                const Divider(height: Space.xl),
                TextFormField(
                  controller: _property,
                  enabled: !_saving,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Property charged',
                    alignLabelWithHint: true,
                    hintText: 'The land, the book debts, the whole undertaking',
                  ),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _ranking,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Ranking',
                    hintText: 'First, second, pari passu',
                  ),
                ),

                if (!_isNew) ...[
                  const Divider(height: Space.xl),
                  const SectionHeader(
                    'Satisfaction',
                    subtitle: 'Leave empty while the charge is outstanding',
                  ),
                  StatutoryDateField(
                    label: 'Satisfied on',
                    value: _satisfiedOn,
                    enabled: !_saving,
                    firstDate: _createdOn,
                    lastDate: DateTime.now(),
                    onChanged: (d) => setState(() {
                      _satisfiedOn = d;
                      if (d == null) _satisfactionFiledOn = null;
                    }),
                  ),
                  if (_satisfiedOn != null) ...[
                    const SizedBox(height: Space.md),
                    StatutoryDateField(
                      label: 'Memorandum filed',
                      value: _satisfactionFiledOn,
                      enabled: !_saving,
                      firstDate: _satisfiedOn,
                      lastDate: DateTime.now(),
                      helperText: 'When SSM was told',
                      onChanged: (d) =>
                          setState(() => _satisfactionFiledOn = d),
                    ),
                  ],
                ],

                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _notes,
                  enabled: !_saving,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Notes',
                    alignLabelWithHint: true,
                  ),
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
          key: const ValueKey('charge-save'),
          onPressed: _saving || _createdOn == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Register' : 'Save'),
        ),
      ],
    );
  }
}
