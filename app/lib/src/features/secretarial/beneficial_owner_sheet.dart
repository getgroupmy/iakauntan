import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart';

/// Whether anything makes this person a beneficial owner.
///
/// s.60B does not let you simply nominate somebody. A person is a
/// beneficial owner *because* a criterion applies to them, and the
/// register records which. An entry with no ground ticked and nothing
/// written in `other_control` asserts that somebody controls the
/// company for no reason anybody wrote down — which is not a register
/// entry, it is a name.
bool hasGround({
  required bool shares,
  required bool voting,
  required bool directors,
  required bool influence,
  String? other,
}) =>
    shares ||
    voting ||
    directors ||
    influence ||
    (other != null && other.trim().isNotEmpty);

/// What an entry on the register is, given what was declared.
///
/// Pure, and apart from the sheet, because two of its rules are silent
/// when broken.
///
/// A percentage that was not recorded stays null rather than becoming
/// zero. Zero is a claim — "holds none" — and an unrecorded holding
/// that reads as a recorded nought is the kind of thing an inspection
/// finds and the company cannot explain.
///
/// And a cessation reason belongs to a cessation, for the same reason
/// it does on the officer register: kept without a date it is a note
/// about somebody who has not ceased.
Map<String, dynamic> beneficialOwnerValues({
  required String entityId,
  required String personId,
  bool holds20pcShares = false,
  bool holds20pcVoting = false,
  bool appointsDirectors = false,
  bool significantInfluence = false,
  String? otherControl,
  double? shareholdingPercent,
  DateTime? notifiedOn,
  DateTime? enteredOn,
  DateTime? ceasedOn,
  String? cessationReason,
}) {
  final ceased = ceasedOn != null;
  return <String, dynamic>{
    'entity_id': entityId,
    'person_id': personId,
    'holds_20pc_shares': holds20pcShares,
    'holds_20pc_voting': holds20pcVoting,
    'appoints_majority_directors': appointsDirectors,
    'has_significant_influence': significantInfluence,
    'other_control':
        (otherControl == null || otherControl.trim().isEmpty)
            ? null
            : otherControl.trim(),
    'shareholding_percent': shareholdingPercent,
    'notified_on': notifiedOn == null ? null : Fmt.iso(notifiedOn),
    if (enteredOn != null) 'entered_on': Fmt.iso(enteredOn),
    'ceased_on': ceased ? Fmt.iso(ceasedOn) : null,
    'cessation_reason': ceased ? cessationReason : null,
  };
}

/// A percentage as typed, or null.
///
/// Blank is null rather than zero — see above. Anything outside 0–100
/// is null too: `numeric(7,4)` would happily store 2000, and a register
/// saying somebody holds two thousand per cent of a company is a typo
/// that the column will never catch.
double? percentOf(String text) {
  final v = double.tryParse(text.trim());
  if (v == null || v < 0 || v > 100) return null;
  return v;
}

/// Declare a beneficial owner, amend the grounds, or record a cessation.
Future<bool> showBeneficialOwnerSheet(
  BuildContext context, {
  required String entityId,
  CorpBeneficialOwner? owner,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _OwnerSheet(entityId: entityId, owner: owner),
    ) ??
    false;

class _OwnerSheet extends ConsumerStatefulWidget {
  const _OwnerSheet({required this.entityId, this.owner});

  final String entityId;
  final CorpBeneficialOwner? owner;

  @override
  ConsumerState<_OwnerSheet> createState() => _OwnerSheetState();
}

class _OwnerSheetState extends ConsumerState<_OwnerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _other = TextEditingController();
  final _percent = TextEditingController();
  final _cessationReason = TextEditingController();

  late String? _personId = widget.owner?.personId;
  late bool _shares = widget.owner?.holds20pcShares ?? false;
  late bool _voting = widget.owner?.holds20pcVoting ?? false;
  late bool _directors = widget.owner?.appointsDirectors ?? false;
  late bool _influence = widget.owner?.significantInfluence ?? false;
  late DateTime? _notifiedOn = widget.owner?.notifiedOn;
  late DateTime? _ceasedOn = widget.owner?.ceasedOn;
  bool _saving = false;

  bool get _isNew => widget.owner == null;

  bool get _grounded => hasGround(
        shares: _shares,
        voting: _voting,
        directors: _directors,
        influence: _influence,
        other: _other.text,
      );

  @override
  void initState() {
    super.initState();
    _other.text = widget.owner?.otherControl ?? '';
    final p = widget.owner?.percent;
    // The stored value, not a formatted one: this box is typed back
    // into, and `Fmt.percent` would put a % sign in the field that
    // `percentOf` then refuses to parse.
    _percent.text = p == null
        ? ''
        : (p == p.roundToDouble() ? p.toStringAsFixed(0) : '$p');
  }

  @override
  void dispose() {
    _other.dispose();
    _percent.dispose();
    _cessationReason.dispose();
    super.dispose();
  }

  Future<void> _addPerson() async {
    final id = await showPersonEditor(context);
    if (id != null && mounted) setState(() => _personId = id);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_personId == null || !_grounded) return;

    setState(() => _saving = true);
    final values = beneficialOwnerValues(
      entityId: widget.entityId,
      personId: _personId!,
      holds20pcShares: _shares,
      holds20pcVoting: _voting,
      appointsDirectors: _directors,
      significantInfluence: _influence,
      otherControl: _other.text,
      shareholdingPercent: percentOf(_percent.text),
      notifiedOn: _notifiedOn,
      enteredOn: _isNew ? DateTime.now() : null,
      ceasedOn: _ceasedOn,
      cessationReason: _cessationReason.text.trim().isEmpty
          ? null
          : _cessationReason.text.trim(),
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveCorpBeneficialOwner(values, id: widget.owner?.id),
      successMessage: _isNew ? 'Entered on the register' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpBeneficialOwnersProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(corpPersonsProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(_isNew ? 'Declare a beneficial owner' : 'Amend the entry'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SearchablePicker<String>(
                  key: const ValueKey('owner-person'),
                  options: corpPersonPickerOptions(people),
                  value: _personId,
                  label: 'Who',
                  hint: 'Type a name or an NRIC',
                  enabled: !_saving,
                  createLabel: 'Add person',
                  // `showPersonEditor` returns the id it wrote, which
                  // is exactly what a picker needs — somebody being
                  // put on a register is very often somebody who is
                  // not on file yet.
                  onCreate: (typed) =>
                      showPersonEditor(context, seedName: typed),
                  onChanged: (v) => setState(() => _personId = v),
                  validator: (v) => v == null ? 'Choose who this is' : null,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _addPerson,
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    label: const Text('Somebody not on the file'),
                  ),
                ),

                const Divider(height: Space.xl),
                // The criteria are the Act's, in the Act's order. More
                // than one may apply to the same person, which is why
                // they are checkboxes rather than a choice.
                const SectionHeader(
                  'On what ground',
                  subtitle: 'Section 60B. More than one may apply.',
                ),
                CheckboxListTile(
                  key: const ValueKey('ground-shares'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _shares,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _shares = v ?? false),
                  title: const Text('Holds more than 20% of the shares'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _voting,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _voting = v ?? false),
                  title: const Text('Holds more than 20% of the voting shares'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _directors,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _directors = v ?? false),
                  title: const Text(
                      'Can appoint or remove a majority of directors'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _influence,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _influence = v ?? false),
                  title: const Text('Has significant control or influence'),
                ),
                TextFormField(
                  controller: _other,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Some other ground',
                    hintText: 'Control exercised through an arrangement',
                  ),
                ),
                if (!_grounded)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(
                      'A beneficial owner is one because a ground applies. '
                      'Tick one, or say what the other ground is.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.colors.warning),
                    ),
                  ),

                const Divider(height: Space.xl),
                TextFormField(
                  key: const ValueKey('owner-percent'),
                  controller: _percent,
                  enabled: !_saving,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Shareholding',
                    suffixText: '%',
                    helperText: 'Leave empty if it is not a shareholding',
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return null;
                    final n = double.tryParse(t);
                    if (n == null) return 'A number, or nothing';
                    if (n < 0 || n > 100) return 'Between 0 and 100';
                    return null;
                  },
                ),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Notified on',
                  value: _notifiedOn,
                  enabled: !_saving,
                  lastDate: DateTime.now(),
                  // s.60B(4): the company notifies the Registrar within
                  // fourteen days of obtaining the information, and the
                  // clock starts from this date rather than from the day
                  // somebody typed it in.
                  helperText: 'When the company obtained the information',
                  onChanged: (d) => setState(() => _notifiedOn = d),
                ),

                if (!_isNew) ...[
                  const Divider(height: Space.xl),
                  const SectionHeader(
                    'Cessation',
                    subtitle: 'Leave empty while the ground still applies',
                  ),
                  StatutoryDateField(
                    label: 'Ceased on',
                    value: _ceasedOn,
                    enabled: !_saving,
                    lastDate: DateTime.now(),
                    onChanged: (d) => setState(() => _ceasedOn = d),
                  ),
                  if (_ceasedOn != null) ...[
                    const SizedBox(height: Space.md),
                    TextFormField(
                      controller: _cessationReason,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Reason',
                        hintText: 'Shares transferred, arrangement ended',
                      ),
                    ),
                  ],
                ],
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
          key: const ValueKey('owner-save'),
          onPressed: _saving || !_grounded ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Enter' : 'Save'),
        ),
      ],
    );
  }
}
