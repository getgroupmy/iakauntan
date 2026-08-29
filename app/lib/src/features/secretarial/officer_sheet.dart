import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';
import 'person_editor.dart';

/// The roles the register knows, in the words a secretary uses.
///
/// `app.corp_officer_role` is the authority on which exist; this only
/// decides how they read. A role missing from here would come out as
/// its own enum label, which is ugly rather than wrong.
const Map<String, String> officerRoles = {
  'director': 'Director',
  'alternate_director': 'Alternate director',
  'secretary': 'Secretary',
  'auditor': 'Auditor',
  'manager': 'Manager',
  'chairman': 'Chairman',
  'ceo': 'Chief executive',
  'cfo': 'Chief financial officer',
  'partner': 'Partner',
  'compliance_officer': 'Compliance officer',
};

String officerRoleName(String code) => officerRoles[code] ?? code;

/// What an appointment is, given what was filled in.
///
/// Pure, and apart from the sheet, because two of the rules it carries
/// are invisible when broken.
///
/// A licence belongs to a secretary and nobody else — s.20G of the
/// Companies Commission Act requires one of them and of no other
/// officer. So changing somebody's role away from secretary clears it:
/// a director carrying a licence number is a register asserting a
/// qualification about a role that does not have one, and
/// `CorpOfficer.licenceLapsed` would go on flagging its expiry at a
/// company that no longer needs it.
///
/// And a reason belongs to a cessation. Kept without a date it is a
/// note about a resignation that has not happened, sitting on somebody
/// still in office.
Map<String, dynamic> officerValues({
  required String entityId,
  required String personId,
  required String role,
  required DateTime appointedOn,
  DateTime? resignedOn,
  String? cessationReason,
  bool isAlternate = false,
  DateTime? consentReceivedOn,
  DateTime? declarationReceivedOn,
  String? licenceNo,
  String? licenceBody,
  DateTime? licenceExpiresOn,
  String? designation,
}) {
  final licensed = roleNeedsLicence(role);
  final ceased = resignedOn != null;
  return <String, dynamic>{
    'entity_id': entityId,
    'person_id': personId,
    'role': role,
    'appointed_on': Fmt.iso(appointedOn),
    'resigned_on': ceased ? Fmt.iso(resignedOn) : null,
    'cessation_reason': ceased ? cessationReason : null,
    'is_alternate': isAlternate,
    'consent_received_on':
        consentReceivedOn == null ? null : Fmt.iso(consentReceivedOn),
    'declaration_received_on':
        declarationReceivedOn == null ? null : Fmt.iso(declarationReceivedOn),
    'licence_no': licensed ? licenceNo : null,
    'licence_body': licensed ? licenceBody : null,
    'licence_expires_on':
        licensed && licenceExpiresOn != null ? Fmt.iso(licenceExpiresOn) : null,
    'designation': designation,
  };
}

/// s.20G of the Companies Commission Act: a secretary must be a member
/// of a prescribed body or hold a licence from the Registrar. Nobody
/// else needs one, so nobody else is asked.
bool roleNeedsLicence(String role) => role == 'secretary';

/// Appoint somebody to a company's register, or amend an appointment.
Future<bool> showOfficerSheet(
  BuildContext context, {
  required String entityId,
  CorpOfficer? officer,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _OfficerSheet(entityId: entityId, officer: officer),
    ) ??
    false;

class _OfficerSheet extends ConsumerStatefulWidget {
  const _OfficerSheet({required this.entityId, this.officer});

  final String entityId;
  final CorpOfficer? officer;

  @override
  ConsumerState<_OfficerSheet> createState() => _OfficerSheetState();
}

class _OfficerSheetState extends ConsumerState<_OfficerSheet> {
  final _formKey = GlobalKey<FormState>();
  final _licenceNo = TextEditingController();
  final _licenceBody = TextEditingController();
  final _designation = TextEditingController();
  final _cessationReason = TextEditingController();

  late String? _personId = widget.officer?.personId;
  late String _role = widget.officer?.role ?? 'director';
  late bool _isAlternate = widget.officer?.isAlternate ?? false;
  late DateTime? _appointedOn = widget.officer?.appointedOn;
  late DateTime? _resignedOn = widget.officer?.resignedOn;
  late DateTime? _consentOn = widget.officer?.consentReceivedOn;
  late DateTime? _declarationOn = widget.officer?.declarationReceivedOn;
  late DateTime? _licenceExpires = widget.officer?.licenceExpiresOn;
  bool _saving = false;

  bool get _isNew => widget.officer == null;

  bool get _needsLicence => roleNeedsLicence(_role);

  @override
  void initState() {
    super.initState();
    final o = widget.officer;
    _licenceNo.text = o?.licenceNo ?? '';
    _licenceBody.text = o?.licenceBody ?? '';
    if (_isNew) _appointedOn = DateTime.now();
  }

  @override
  void dispose() {
    _licenceNo.dispose();
    _licenceBody.dispose();
    _designation.dispose();
    _cessationReason.dispose();
    super.dispose();
  }

  Future<void> _addPerson() async {
    final id = await showPersonEditor(context);
    if (id != null && mounted) setState(() => _personId = id);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_personId == null || _appointedOn == null) return;

    setState(() => _saving = true);
    final values = officerValues(
      entityId: widget.entityId,
      personId: _personId!,
      role: _role,
      appointedOn: _appointedOn!,
      resignedOn: _resignedOn,
      cessationReason: _cessationReason.text.trim().isEmpty
          ? null
          : _cessationReason.text.trim(),
      isAlternate: _isAlternate,
      consentReceivedOn: _consentOn,
      declarationReceivedOn: _declarationOn,
      licenceNo:
          _licenceNo.text.trim().isEmpty ? null : _licenceNo.text.trim(),
      licenceBody:
          _licenceBody.text.trim().isEmpty ? null : _licenceBody.text.trim(),
      licenceExpiresOn: _licenceExpires,
      designation: _designation.text.trim().isEmpty
          ? null
          : _designation.text.trim(),
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveCorpOfficer(values, id: widget.officer?.id),
      successMessage: _isNew ? 'Appointed' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpOfficersProvider(widget.entityId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(corpPersonsProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(_isNew ? 'Appoint an officer' : 'Amend the appointment'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const ValueKey('officer-person'),
                  value: _personId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Who'),
                  items: [
                    for (final p in people)
                      DropdownMenuItem(
                        value: p.id,
                        child: Text(
                          p.identifier == null
                              ? p.fullName
                              : '${p.fullName} (${p.identifier})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _personId = v),
                  validator: (v) => v == null ? 'Choose who this is' : null,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('officer-add-person'),
                    onPressed: _saving ? null : _addPerson,
                    icon: const Icon(Icons.person_add_outlined, size: 18),
                    label: const Text('Somebody not on the file'),
                  ),
                ),

                const SizedBox(height: Space.sm),
                DropdownButtonFormField<String>(
                  key: const ValueKey('officer-role'),
                  value: _role,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: [
                    for (final e in officerRoles.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _role = v ?? 'director'),
                ),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Appointed on',
                  value: _appointedOn,
                  enabled: !_saving,
                  lastDate: DateTime.now(),
                  helperText: 'The date on the s.58 notification',
                  onChanged: (d) => setState(() => _appointedOn = d),
                ),
                if (_appointedOn == null)
                  const Padding(
                    padding: EdgeInsets.only(top: Space.xs),
                    child: Text(
                      'An appointment needs a date.',
                      style: TextStyle(fontSize: 12, color: Colors.redAccent),
                    ),
                  ),

                const SizedBox(height: Space.sm),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isAlternate,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _isAlternate = v ?? false),
                  title: const Text('Acting as an alternate'),
                ),
                TextFormField(
                  controller: _designation,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Designation',
                    hintText: 'Executive, non-executive, independent',
                  ),
                ),

                const Divider(height: Space.xl),
                // s.201 consent to act and the s.198 declaration that
                // the person is not disqualified. A secretary who
                // cannot produce these has a problem, so the register
                // records whether they are held rather than assuming.
                const SectionHeader(
                  'Paperwork',
                  subtitle: 'Consent to act, and the s.198 declaration',
                ),
                StatutoryDateField(
                  label: 'Consent received',
                  value: _consentOn,
                  enabled: !_saving,
                  lastDate: DateTime.now(),
                  onChanged: (d) => setState(() => _consentOn = d),
                ),
                const SizedBox(height: Space.md),
                StatutoryDateField(
                  label: 'Declaration received',
                  value: _declarationOn,
                  enabled: !_saving,
                  lastDate: DateTime.now(),
                  onChanged: (d) => setState(() => _declarationOn = d),
                ),

                if (_needsLicence) ...[
                  const Divider(height: Space.xl),
                  const SectionHeader(
                    'Licence',
                    subtitle: 'Companies Commission Act, section 20G',
                  ),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _licenceNo,
                        enabled: !_saving,
                        decoration:
                            const InputDecoration(labelText: 'Licence no.'),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: TextFormField(
                        controller: _licenceBody,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'Body',
                          hintText: 'MAICSA, SSM',
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: Space.md),
                  StatutoryDateField(
                    label: 'Licence expires',
                    value: _licenceExpires,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _licenceExpires = d),
                  ),
                ],

                if (!_isNew) ...[
                  const Divider(height: Space.xl),
                  const SectionHeader(
                    'Cessation',
                    subtitle: 'Leave empty while they are still in office',
                  ),
                  StatutoryDateField(
                    label: 'Ceased on',
                    value: _resignedOn,
                    enabled: !_saving,
                    // Not before they were appointed: an officer who
                    // resigned before they started is a register that
                    // reads as nonsense and files as a rejection.
                    firstDate: _appointedOn,
                    lastDate: DateTime.now(),
                    onChanged: (d) => setState(() => _resignedOn = d),
                  ),
                  if (_resignedOn != null) ...[
                    const SizedBox(height: Space.md),
                    TextFormField(
                      controller: _cessationReason,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Reason',
                        hintText: 'Resigned, retired by rotation, removed',
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
          key: const ValueKey('officer-save'),
          onPressed: _saving || _appointedOn == null ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isNew ? 'Appoint' : 'Save'),
        ),
      ],
    );
  }
}
