import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../contacts/new_contact_dialog.dart';

/// What a unit can be, given what the site is.
///
/// `app.property_unit_matches_site` refuses the wrong pairing, and it is
/// right to: a strata scheme holds parcels, a row of shophouses does
/// not. Offering only the types the tenure allows means the refusal
/// never has to happen -- the alternative is a dropdown that lets
/// somebody pick 'shop' on a condominium and learn at Save that the
/// database disagrees.
const Map<String, String> unitTypeNames = {
  'parcel': 'Parcel',
  'accessory': 'Accessory parcel',
  'landed': 'Landed',
  'shop': 'Shop',
  'office': 'Office',
  'industrial': 'Industrial',
  'common': 'Common property',
};

List<String> unitTypesFor(String tenure) => tenure == 'strata'
    ? const ['parcel', 'accessory', 'common']
    : const ['landed', 'shop', 'office', 'industrial', 'common'];

/// Whether the Schedule of Parcels has to say what this parcel's share
/// is before it can be billed.
///
/// The Charges are levied in proportion to allocated share units, so a
/// chargeable parcel with none cannot be charged in proportion to
/// anything -- and billing it anyway means the other owners are paying
/// its share. The trigger raises on exactly this; asking here means the
/// secretary is told which parcel and why, in the form, rather than
/// reading it off a constraint violation.
bool needsShareUnits(String tenure, String unitType, bool isChargeable) =>
    tenure == 'strata' && unitType == 'parcel' && isChargeable;

/// Share units, as a number the schedule can actually allocate.
///
/// Numeric rather than integer because some schedules allocate
/// fractions, and rounding them moves money between neighbours.
double? shareUnitsOf(String text) {
  final v = double.tryParse(text.trim());
  if (v == null || v < 0) return null;
  return v;
}

/// The floor area of a parcel, as a number.
///
/// Nought is refused where [shareUnitsOf] allows it, and the two sitting
/// one character apart is deliberate rather than careless: a parcel can
/// carry no share units — common property does — and a parcel of no
/// area is not a parcel.
///
/// No empty-string guard. `double.tryParse('')` is already null, so one
/// would be a branch nothing could tell apart from its absence.
double? sqftOf(String text) {
  final v = double.tryParse(text.trim());
  if (v == null || v <= 0) return null;
  return v;
}

/// What a unit is, given what was entered.
///
/// Pure, and apart from the sheet, because the tenure rules are a
/// trigger: share units on a shophouse are refused outright, and an
/// accessory parcel's principal belongs to a strata scheme alone.
Map<String, dynamic> unitValues({
  required String siteId,
  required String tenure,
  required String unitNo,
  required String unitType,
  String? floor,
  double? builtUpSqft,
  double? shareUnits,
  String? principalUnitId,
  String? ownerContactId,
  bool isChargeable = true,
  String? notes,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  final strata = tenure == 'strata';
  // Common property is never billed, so it never carries an owner to
  // bill or a chargeable flag to set.
  final common = unitType == 'common';

  return <String, dynamic>{
    'site_id': siteId,
    'unit_no': unitNo.trim(),
    'unit_type': unitType,
    'floor': trimmed(floor),
    'built_up_sqft': builtUpSqft,
    // 'Share units belong to a strata scheme' -- the trigger's words.
    // A figure typed before the tenure was understood is dropped rather
    // than sent to be refused.
    'share_units': strata && !common ? shareUnits : null,
    // An accessory parcel is charged through its principal, so only it
    // points at one.
    'principal_unit_id': unitType == 'accessory' ? principalUnitId : null,
    'owner_contact_id': common ? null : ownerContactId,
    'is_chargeable': common ? false : isChargeable,
    'notes': trimmed(notes),
  };
}

/// Add or amend a unit.
Future<bool> showUnitSheet(
  BuildContext context, {
  required String siteId,
  required String tenure,
  Map<String, dynamic>? unit,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) =>
          _UnitSheet(siteId: siteId, tenure: tenure, unit: unit),
    ) ??
    false;

class _UnitSheet extends ConsumerStatefulWidget {
  const _UnitSheet({
    required this.siteId,
    required this.tenure,
    this.unit,
  });

  final String siteId;
  final String tenure;
  final Map<String, dynamic>? unit;

  @override
  ConsumerState<_UnitSheet> createState() => _UnitSheetState();
}

class _UnitSheetState extends ConsumerState<_UnitSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _unitNo;
  late final TextEditingController _floor;
  late final TextEditingController _sqft;
  late final TextEditingController _shareUnits;
  late final TextEditingController _notes;

  late String _type;
  String? _principalId;
  String? _ownerId;
  late bool _chargeable;
  bool _saving = false;

  bool get _strata => widget.tenure == 'strata';
  bool get _isNew => widget.unit == null;

  @override
  void initState() {
    super.initState();
    final u = widget.unit;
    _unitNo = TextEditingController(text: u?['unit_no'] as String? ?? '');
    _floor = TextEditingController(text: u?['floor'] as String? ?? '');
    _sqft = TextEditingController(
      text: u?['built_up_sqft'] == null ? '' : '${u!['built_up_sqft']}',
    );
    _shareUnits = TextEditingController(
      text: u?['share_units'] == null ? '' : '${u!['share_units']}',
    );
    _notes = TextEditingController(text: u?['notes'] as String? ?? '');
    _type = u?['unit_type'] as String? ??
        (_strata ? 'parcel' : 'shop');
    _principalId = u?['principal_unit_id'] as String?;
    _ownerId = u?['owner_contact_id'] as String?;
    _chargeable = u?['is_chargeable'] as bool? ?? true;
  }

  @override
  void dispose() {
    for (final c in [_unitNo, _floor, _sqft, _shareUnits, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);
    final values = unitValues(
      siteId: widget.siteId,
      tenure: widget.tenure,
      unitNo: _unitNo.text,
      unitType: _type,
      floor: _floor.text,
      builtUpSqft: sqftOf(_sqft.text),
      shareUnits: shareUnitsOf(_shareUnits.text),
      principalUnitId: _principalId,
      ownerContactId: _ownerId,
      isChargeable: _chargeable,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .savePropertyUnit(values, id: widget.unit?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(propertyUnitsProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // An owner is billed, so the list is the customer list.
    final contacts =
        ref.watch(contactsProvider((type: 'customer', search: ''))).valueOrNull ??
            const <Contact>[];
    final units =
        ref.watch(propertyUnitsProvider(widget.siteId)).valueOrNull ??
            const [];
    final types = unitTypesFor(widget.tenure);
    final common = _type == 'common';
    final wantsShare = needsShareUnits(widget.tenure, _type, _chargeable);

    // Only a principal parcel can be one: an accessory cannot hang off
    // another accessory, and it cannot hang off itself.
    final principals = units.where((u) =>
        u['unit_type'] == 'parcel' && u['id'] != widget.unit?['id']);

    return AlertDialog(
      title: Text(_isNew
          ? (_strata ? 'Add a parcel' : 'Add a unit')
          : (_strata ? 'Amend the parcel' : 'Amend the unit')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('unit-no'),
                      controller: _unitNo,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: _strata ? 'Parcel no' : 'Unit no',
                        helperText: 'A-12-03',
                      ),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('unit-type'),
                      initialValue: types.contains(_type) ? _type : types.first,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: [
                        for (final t in types)
                          DropdownMenuItem(
                            value: t,
                            child: Text(unitTypeNames[t] ?? t),
                          ),
                      ],
                      onChanged:
                          _saving ? null : (v) => setState(() => _type = v!),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _floor,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'Floor'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _sqft,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Built up (sq ft)'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty || sqftOf(v) != null)
                              ? null
                              : 'A positive number',
                    ),
                  ),
                ]),
                if (_strata && !common) ...[
                  const SizedBox(height: Space.md),
                  TextFormField(
                    key: const ValueKey('share-units'),
                    controller: _shareUnits,
                    enabled: !_saving,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Allocated share units',
                      helperText: wantsShare
                          ? 'From the Schedule of Parcels. The Charges are '
                              'levied in proportion to this.'
                          : 'From the Schedule of Parcels.',
                    ),
                    validator: (v) {
                      final parsed = shareUnitsOf(v ?? '');
                      if (wantsShare && (parsed == null || parsed <= 0)) {
                        return 'A chargeable parcel needs its share';
                      }
                      if ((v ?? '').trim().isNotEmpty && parsed == null) {
                        return 'A number, not less than zero';
                      }
                      return null;
                    },
                  ),
                ],
                if (_type == 'accessory') ...[
                  const SizedBox(height: Space.md),
                  SearchablePicker<String>(
                    options: [
                      for (final u in principals)
                        PickerOption<String>(
                          value: u['id'] as String,
                          label: '${u['unit_no']}',
                        ),
                    ],
                    value: _principalId,
                    label: 'Principal parcel',
                    helperText: 'An accessory parcel is charged through '
                        'the parcel it belongs to.',
                    hint: 'Type a unit number',
                    allowEmpty: true,
                    enabled: !_saving,
                    onChanged: (v) => setState(() => _principalId = v),
                  ),
                ],
                if (!common) ...[
                  const SizedBox(height: Space.md),
                  SearchablePicker<String>(
                    key: const ValueKey('unit-owner'),
                    options: contactPickerOptions(contacts),
                    value: _ownerId,
                    label: 'Owner',
                    helperText: 'Who is billed. A contact, because an '
                        'owner is invoiced, pays, and ages.',
                    hint: 'Type a name or a code',
                    enabled: !_saving,
                    createLabel: 'Add owner',
                    onCreate: (typed) => createContactFromPicker(
                      context,
                      contactType: 'customer',
                      typed: typed,
                    ),
                    onChanged: (v) => setState(() => _ownerId = v),
                  ),
                  const SizedBox(height: Space.sm),
                  SwitchListTile(
                    key: const ValueKey('unit-chargeable'),
                    contentPadding: EdgeInsets.zero,
                    value: _chargeable,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _chargeable = v),
                    title: const Text('Charged'),
                    subtitle: const Text(
                        'Off for a unit the scheme does not levy on.'),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.only(top: Space.md),
                    child: Text(
                      'Common property is never billed and has no owner to '
                      'bill, so it carries neither.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    ),
                  ),
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
          key: const ValueKey('unit-save'),
          onPressed: _saving ? null : _save,
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
