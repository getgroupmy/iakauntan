import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import '../../data/places_repository.dart';

/// Put somebody on file, or amend what is on file about them.
///
/// `corp_persons` is one record used as officer, member and beneficial
/// owner alike — the schema says so and gives the reason: an NRIC kept
/// in three places is an NRIC that will disagree with itself. So this
/// is the only place a person is typed, and every register points at
/// the row it makes.
///
/// The form asks different questions of a person and of a body
/// corporate, because they are different questions: a company has no
/// NRIC and no date of birth, and a director who is a company is
/// perfectly ordinary in a group structure. Asking a company for its
/// gender is how a form tells you it was written for somebody else.
///
/// Returns the person's id, so a caller that opened this to appoint an
/// officer can carry straight on with the appointment.
Future<String?> showPersonEditor(
  BuildContext context, {
  CorpPerson? person,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _PersonEditor(person: person),
    );

/// What a person record is, given what was typed.
///
/// Pure, and apart from the form, because the rule it carries is silent
/// when broken: every field belonging to the kind *not* chosen is
/// cleared rather than left behind. A party recorded as a body
/// corporate that keeps the NRIC somebody typed before switching the
/// toggle is a register holding two identifiers for one party — the
/// exact disagreement `corp_persons` exists to prevent by being one
/// table.
Map<String, dynamic> personValues({
  required String kind,
  required String fullName,
  String? formerName,
  String? nric,
  String? passportNo,
  String? passportCountry,
  String? nationality,
  DateTime? dateOfBirth,
  String? gender,
  bool isResident = true,
  String? registrationNo,
  String? incorporatedIn,
  String? email,
  String? phone,
  String? line1,
  String? line2,
  String? postcode,
  String? city,
  String? stateCode,
  String? country,
  bool isPep = false,
  String? kycNotes,
}) {
  final corporate = kind == 'corporate';
  return <String, dynamic>{
    'kind': kind,
    'full_name': fullName.trim(),
    'former_name': formerName,
    'nric': corporate ? null : nric,
    'passport_no': corporate ? null : passportNo,
    'passport_country': corporate ? null : passportCountry,
    'nationality': corporate ? null : nationality,
    'date_of_birth':
        corporate || dateOfBirth == null ? null : Fmt.iso(dateOfBirth),
    'gender': corporate ? null : gender,
    // A body corporate is not "ordinarily resident"; the column is not
    // null-able, so it takes the value that means the question does not
    // apply rather than one that reads as an answer.
    'is_resident_in_malaysia': corporate ? true : isResident,
    'registration_no': corporate ? registrationNo : null,
    'incorporated_in': corporate ? incorporatedIn : null,
    'email': email,
    'phone': phone,
    'address_line1': line1,
    'address_line2': line2,
    'postcode': postcode,
    'city': city,
    'state_code': stateCode,
    'country': country,
    // Neither the document nor the day it was seen is written here.
    // `0380` made customer due diligence a record of an act by a
    // person — this document, seen by this individual, on this day —
    // and `verify_person_identity` is what writes all three together.
    // A form that could type the date on its own could assert a check
    // nobody carried out.
    'is_pep': isPep,
    'kyc_notes': kycNotes,
  };
}

class _PersonEditor extends ConsumerStatefulWidget {
  const _PersonEditor({this.person});

  final CorpPerson? person;

  @override
  ConsumerState<_PersonEditor> createState() => _PersonEditorState();
}

class _PersonEditorState extends ConsumerState<_PersonEditor> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};

  late String _kind = widget.person?.kind ?? 'individual';
  late bool _resident = widget.person?.isResident ?? true;
  late bool _pep = widget.person?.isPep ?? false;
  late String? _stateCode = widget.person?.stateCode;
  late String? _gender = _genders.contains(widget.person?.gender)
      ? widget.person!.gender
      : null;
  late DateTime? _dob = widget.person?.dateOfBirth;
  bool _saving = false;

  static const _genders = ['female', 'male'];

  bool get _isNew => widget.person == null;
  bool get _corporate => _kind == 'corporate';

  TextEditingController _ctl(String key, [String? initial]) =>
      _c.putIfAbsent(key, () => TextEditingController(text: initial ?? ''));

  @override
  void initState() {
    super.initState();
    final p = widget.person;
    _ctl('full_name', p?.fullName);
    _ctl('former_name', p?.formerName);
    _ctl('nric', p?.nric);
    _ctl('passport_no', p?.passportNo);
    _ctl('passport_country', p?.passportCountry);
    _ctl('nationality', p?.nationality ?? 'Malaysian');
    _ctl('registration_no', p?.registrationNo);
    _ctl('incorporated_in', p?.incorporatedIn);
    _ctl('email', p?.email);
    _ctl('phone', p?.phone);
    _ctl('address_line1', p?.line1);
    _ctl('address_line2', p?.line2);
    _ctl('postcode', p?.postcode);
    _ctl('city', p?.city);
    _ctl('country', p?.country ?? 'Malaysia');
    _ctl('kyc_notes', p?.kycNotes);
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _blank(String key) {
    final v = _ctl(key).text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    // Every field of the kind not chosen is cleared rather than left.
    // A person recorded as a company keeping the NRIC they had when
    // somebody picked the wrong kind is a register with two identifiers
    // for one party, which is the thing `corp_persons` exists to stop.
    final values = personValues(
      kind: _kind,
      fullName: _ctl('full_name').text,
      formerName: _blank('former_name'),
      nric: _blank('nric'),
      passportNo: _blank('passport_no'),
      passportCountry: _blank('passport_country'),
      nationality: _blank('nationality'),
      dateOfBirth: _dob,
      gender: _gender,
      isResident: _resident,
      registrationNo: _blank('registration_no'),
      incorporatedIn: _blank('incorporated_in'),
      email: _blank('email'),
      phone: _blank('phone'),
      line1: _blank('address_line1'),
      line2: _blank('address_line2'),
      postcode: _blank('postcode'),
      city: _blank('city'),
      stateCode: _stateCode,
      country: _blank('country'),
      isPep: _pep,
      kycNotes: _blank('kyc_notes'),
    );

    String? id;
    final ok = await runWithFeedback(
      context,
      action: () async {
        id = await ref
            .read(repoProvider)!
            .saveCorpPerson(values, id: widget.person?.id);
      },
      successMessage: _isNew ? 'Added to the file' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpPersonsProvider);
      Navigator.of(context).pop(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final states = ref.watch(refStatesProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(_isNew ? 'Add a person' : widget.person!.fullName),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'individual',
                      label: Text('A person'),
                      icon: Icon(Icons.person_outline, size: 18),
                    ),
                    ButtonSegment(
                      value: 'corporate',
                      label: Text('A body corporate'),
                      icon: Icon(Icons.apartment_outlined, size: 18),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: _saving
                      ? null
                      : (v) => setState(() => _kind = v.first),
                ),
                const SizedBox(height: Space.lg),
                TextFormField(
                  key: const ValueKey('person-full-name'),
                  controller: _ctl('full_name'),
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: _corporate ? 'Name' : 'Full name',
                    helperText: _corporate
                        ? null
                        : 'As it appears on the identity document',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'A name is required' : null,
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _ctl('former_name'),
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Former name',
                    helperText: 'Only if they have one on the register',
                  ),
                ),

                const Divider(height: Space.xl),
                if (_corporate) ...[
                  TextFormField(
                    key: const ValueKey('person-registration-no'),
                    controller: _ctl('registration_no'),
                    enabled: !_saving,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Registration no.',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  TextFormField(
                    controller: _ctl('incorporated_in'),
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      labelText: 'Incorporated in',
                      hintText: 'Malaysia',
                    ),
                  ),
                ] else ...[
                  TextFormField(
                    key: const ValueKey('person-nric'),
                    controller: _ctl('nric'),
                    enabled: !_saving,
                    decoration: const InputDecoration(
                      labelText: 'NRIC',
                      hintText: '900101015555',
                      helperText: 'Digits only, no dashes',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _ctl('passport_no'),
                        enabled: !_saving,
                        textCapitalization: TextCapitalization.characters,
                        decoration:
                            const InputDecoration(labelText: 'Passport no.'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextFormField(
                        controller: _ctl('passport_country'),
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'Issued by',
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Space.md),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _ctl('nationality'),
                        enabled: !_saving,
                        decoration:
                            const InputDecoration(labelText: 'Nationality'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: DropdownButtonFormField<String?>(
                        value: _gender,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Gender'),
                        items: const [
                          DropdownMenuItem(value: null, child: Text('—')),
                          DropdownMenuItem(
                              value: 'female', child: Text('Female')),
                          DropdownMenuItem(value: 'male', child: Text('Male')),
                        ],
                        onChanged: _saving
                            ? null
                            : (v) => setState(() => _gender = v),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Space.md),
                  StatutoryDateField(
                    label: 'Date of birth',
                    value: _dob,
                    enabled: !_saving,
                    // Nobody appointable was born after today, and a
                    // typo of 2026 for 1926 is a register that is wrong
                    // in a way no screen ever mentions again.
                    lastDate: DateTime.now(),
                    onChanged: (d) => setState(() => _dob = d),
                  ),
                  const SizedBox(height: Space.sm),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _resident,
                    onChanged: _saving
                        ? null
                        : (v) => setState(() => _resident = v ?? true),
                    title: const Text('Ordinarily resident in Malaysia'),
                    // s.196(4)(a): a company must have at least one
                    // director who ordinarily resides here. The register
                    // is where that gets checked, so it is asked here.
                    subtitle: const Text(
                      'Section 196 requires at least one resident director',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],

                const Divider(height: Space.xl),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _ctl('email'),
                      enabled: !_saving,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _ctl('phone'),
                      enabled: !_saving,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Phone'),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                AddressField(
                  fieldKey: const ValueKey('person-address1'),
                  controller: _ctl('address_line1'),
                  enabled: !_saving,
                  label: 'Address line 1',
                  country: ref.watch(orgCountryAlpha2Provider),
                  onChosen: (a) {
                    fillAddressBoxes(
                      a,
                      states,
                      postcode: _ctl('postcode'),
                      city: _ctl('city'),
                    );
                    final code = stateCodeFor(states, a.state);
                    if (code != null) setState(() => _stateCode = code);
                  },
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _ctl('address_line2'),
                  enabled: !_saving,
                  decoration:
                      const InputDecoration(labelText: 'Address line 2'),
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  SizedBox(
                    width: 110,
                    child: TextFormField(
                      controller: _ctl('postcode'),
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Postcode'),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _ctl('city'),
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String?>(
                  value: _stateCode,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'State'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('—')),
                    for (final s in states)
                      DropdownMenuItem(
                        value: s['code'] as String,
                        child: Text(s['name']?.toString() ?? '',
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _stateCode = v),
                ),
                const SizedBox(height: Space.md),
                TextFormField(
                  controller: _ctl('country'),
                  enabled: !_saving,
                  decoration: const InputDecoration(labelText: 'Country'),
                ),

                const Divider(height: Space.xl),
                // A secretary is a reporting institution under the AMLA
                // for some engagements, and in every case has to know
                // who they are filing for. The schema says so; this is
                // where it gets recorded.
                const SectionHeader(
                  'Know your client',
                  subtitle: 'What the firm holds to say who this is',
                ),
                _VerificationTile(person: widget.person, enabled: !_saving),
                const SizedBox(height: Space.sm),
                CheckboxListTile(
                  key: const ValueKey('person-pep'),
                  contentPadding: EdgeInsets.zero,
                  value: _pep,
                  onChanged:
                      _saving ? null : (v) => setState(() => _pep = v ?? false),
                  title: const Text('Politically exposed person'),
                  subtitle: const Text(
                    'Triggers enhanced due diligence under the AMLA',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: Space.sm),
                TextFormField(
                  controller: _ctl('kyc_notes'),
                  enabled: !_saving,
                  maxLines: 3,
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
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('person-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}

/// A date, or nothing, chosen from a picker rather than typed.
///
/// Every date on these registers is a statutory one — an appointment,
/// a consent, a verification — and a typed date is a date that can be
/// the thirty-first of February.
///
/// Shared with the officer sheet, which asks for four of them.
class StatutoryDateField extends StatelessWidget {
  const StatutoryDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.helperText,
    this.firstDate,
    this.lastDate,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool enabled;
  final String? helperText;
  final DateTime? firstDate;
  final DateTime? lastDate;

  @override
  Widget build(BuildContext context) => InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          suffixIcon: value == null || !enabled
              ? const Icon(Icons.event_outlined, size: 18)
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: InkWell(
          onTap: enabled
              ? () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: value ?? now,
                    firstDate: firstDate ?? DateTime(now.year - 100),
                    lastDate: lastDate ?? DateTime(now.year + 10),
                  );
                  if (picked != null) onChanged(picked);
                }
              : null,
          child: Text(value == null ? 'Not set' : Fmt.date(value)),
        ),
      );
}

/// The identity check, as a record of who did it.
///
/// It used to be two form fields — a document name and a date — saved
/// with everything else, which meant the register could say a check had
/// been made without saying by whom. `corp_persons.id_verified_by` was
/// a column nothing wrote. Since `0380` the date and the verifier are
/// written together by `verify_person_identity`, so this is an action
/// rather than a field.
class _VerificationTile extends ConsumerStatefulWidget {
  const _VerificationTile({required this.person, required this.enabled});

  final CorpPerson? person;
  final bool enabled;

  @override
  ConsumerState<_VerificationTile> createState() => _VerificationTileState();
}

class _VerificationTileState extends ConsumerState<_VerificationTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.person;
    if (p == null) {
      // A person who does not exist yet cannot have been verified, and
      // saying so is better than a disabled control with no explanation.
      return Text(
        'Save this person first, then record the identity check against '
        'them.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    final verified = p.idVerifiedOn != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          verified
              ? '${p.idDocumentType ?? 'Document'} sighted '
                  '${Fmt.date(p.idVerifiedOn)}'
              : 'No identity check recorded.',
          style: TextStyle(
            fontWeight: verified ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        const SizedBox(height: Space.xs),
        Row(children: [
          TextButton(
            onPressed: widget.enabled && !_busy ? () => _record(p) : null,
            child: Text(verified ? 'Record another check' : 'Record a check'),
          ),
          if (verified)
            TextButton(
              onPressed: widget.enabled && !_busy ? () => _withdraw(p) : null,
              child: const Text('Withdraw'),
            ),
        ]),
      ],
    );
  }

  Future<void> _record(CorpPerson p) async {
    final document = await promptForText(
      context,
      title: 'What was sighted?',
      label: 'Identity document',
      confirmLabel: 'Record it',
      suggestions: const [
        'NRIC',
        'Passport',
        'Certificate of incorporation',
      ],
    );
    if (document == null || !mounted) return;

    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .verifyPersonIdentity(p.id, documentType: document),
      // Says who, because that is the whole of what changed about this.
      successMessage: 'Recorded against you, today.',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(corpPersonsProvider);
  }

  Future<void> _withdraw(CorpPerson p) async {
    final go = await confirm(
      context,
      title: 'Withdraw the check?',
      message: 'The register will show no identity check for '
          '${p.fullName}. Do this when it was recorded against the wrong '
          'person or the document turned out not to be theirs.',
      confirmLabel: 'Withdraw',
      destructive: true,
    );
    if (!go || !mounted) return;

    setState(() => _busy = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.unverifyPersonIdentity(p.id),
      successMessage: 'Withdrawn',
    );
    if (mounted) setState(() => _busy = false);
    ref.invalidate(corpPersonsProvider);
  }
}
