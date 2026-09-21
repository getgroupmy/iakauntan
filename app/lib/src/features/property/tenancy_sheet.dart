import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../contacts/new_contact_dialog.dart';
import '../secretarial/person_editor.dart' show StatutoryDateField;

/// Where a tenancy is in its life.
///
/// Draft and active both hold the unit against the overlap constraint,
/// which is the point: a draft tenancy is one the landlord has agreed
/// and has not commenced, and letting the same unit to somebody else
/// over the same days would be the double booking `tenancies_no_overlap`
/// exists to prevent.
const Map<String, String> tenancyStatusNames = {
  'draft': 'Draft',
  'active': 'Active',
  'expired': 'Expired',
  'terminated': 'Terminated',
};

/// Whether the tenancy still holds the unit.
bool tenancyHoldsUnit(String status) => status == 'draft' || status == 'active';

/// What is actually held today, when a tenancy is first written.
///
/// The agreed deposits and the sum held are separate columns because a
/// deposit can be partly forfeited, topped up or refunded on exit, and
/// the agreement does not change when it is. On the day the tenancy is
/// entered they are the same thing, so this saves asking twice -- and
/// asking twice is how they come to disagree.
double depositHeldFor(double security, double utility) =>
    double.parse((security + utility).toStringAsFixed(2));

double? moneyOf(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', ''));
  if (v == null || v < 0) return null;
  return v;
}

/// Which day of the month rent falls due.
///
/// Capped at 28 by the column, and rightly: a tenancy that falls due on
/// the 31st has no due date in February, and the one that matters is the
/// month the tenant is chased for.
int? rentDueDayOf(String text) {
  final v = int.tryParse(text.trim());
  if (v == null || v < 1 || v > 28) return null;
  return v;
}

/// A tenancy has to end on or after it starts.
bool datesRun(DateTime? start, DateTime? end) =>
    start != null && end != null && !end.isBefore(start);

/// What a tenancy is, given what was entered.
Map<String, dynamic> tenancyValues({
  required String unitId,
  required String tenantContactId,
  required String tenancyNo,
  required DateTime startDate,
  required DateTime endDate,
  required double monthlyRent,
  required int rentDueDay,
  double securityDeposit = 0,
  double utilityDeposit = 0,
  double? depositHeld,
  String status = 'draft',
  DateTime? terminatedOn,
  String? notes,
}) {
  String? trimmed(String? v) =>
      (v == null || v.trim().isEmpty) ? null : v.trim();

  return <String, dynamic>{
    'unit_id': unitId,
    'tenant_contact_id': tenantContactId,
    'tenancy_no': tenancyNo.trim(),
    'start_date': Fmt.iso(startDate),
    'end_date': Fmt.iso(endDate),
    'monthly_rent': monthlyRent,
    'rent_due_day': rentDueDay,
    'security_deposit': securityDeposit,
    'utility_deposit': utilityDeposit,
    'deposit_held': depositHeld ?? depositHeldFor(securityDeposit, utilityDeposit),
    'status': status,
    // A date without a termination is a date for something that did not
    // happen. Only a terminated tenancy carries one.
    'terminated_on':
        status == 'terminated' && terminatedOn != null ? Fmt.iso(terminatedOn) : null,
    'notes': trimmed(notes),
  };
}

/// Let a unit, or amend the letting.
Future<bool> showTenancySheet(
  BuildContext context, {
  required String siteId,
  Map<String, dynamic>? tenancy,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _TenancySheet(siteId: siteId, tenancy: tenancy),
    ) ??
    false;

class _TenancySheet extends ConsumerStatefulWidget {
  const _TenancySheet({required this.siteId, this.tenancy});

  final String siteId;
  final Map<String, dynamic>? tenancy;

  @override
  ConsumerState<_TenancySheet> createState() => _TenancySheetState();
}

class _TenancySheetState extends ConsumerState<_TenancySheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _no;
  late final TextEditingController _rent;
  late final TextEditingController _dueDay;
  late final TextEditingController _security;
  late final TextEditingController _utility;
  late final TextEditingController _held;
  late final TextEditingController _notes;

  String? _unitId;
  String? _tenantId;
  late String _status;
  DateTime? _start;
  DateTime? _end;
  DateTime? _terminated;
  bool _saving = false;

  bool get _isNew => widget.tenancy == null;

  @override
  void initState() {
    super.initState();
    final t = widget.tenancy;
    _no = TextEditingController(text: t?['tenancy_no'] as String? ?? '');
    _rent = TextEditingController(
      text: t?['monthly_rent'] == null ? '' : '${t!['monthly_rent']}',
    );
    _dueDay = TextEditingController(text: '${t?['rent_due_day'] ?? 1}');
    _security = TextEditingController(text: '${t?['security_deposit'] ?? 0}');
    _utility = TextEditingController(text: '${t?['utility_deposit'] ?? 0}');
    _held = TextEditingController(
      text: t?['deposit_held'] == null ? '' : '${t!['deposit_held']}',
    );
    _notes = TextEditingController(text: t?['notes'] as String? ?? '');
    _unitId = t?['unit_id'] as String?;
    _tenantId = t?['tenant_contact_id'] as String?;
    _status = t?['status'] as String? ?? 'draft';
    _start = t?['start_date'] == null
        ? null
        : DateTime.parse(t!['start_date'] as String);
    _end =
        t?['end_date'] == null ? null : DateTime.parse(t!['end_date'] as String);
    _terminated = t?['terminated_on'] == null
        ? null
        : DateTime.parse(t!['terminated_on'] as String);
  }

  @override
  void dispose() {
    for (final c in [
      _no,
      _rent,
      _dueDay,
      _security,
      _utility,
      _held,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_unitId == null || _tenantId == null) return;
    if (!datesRun(_start, _end)) return;

    final rent = moneyOf(_rent.text);
    final day = rentDueDayOf(_dueDay.text);
    if (rent == null || day == null) return;

    setState(() => _saving = true);
    final values = tenancyValues(
      unitId: _unitId!,
      tenantContactId: _tenantId!,
      tenancyNo: _no.text,
      startDate: _start!,
      endDate: _end!,
      monthlyRent: rent,
      rentDueDay: day,
      securityDeposit: moneyOf(_security.text) ?? 0,
      utilityDeposit: moneyOf(_utility.text) ?? 0,
      // On a new tenancy the held figure follows the agreement; on an
      // amendment it is whatever the box says, because by then it is a
      // fact about the account and not about the agreement.
      depositHeld: _isNew ? null : moneyOf(_held.text),
      status: _status,
      terminatedOn: _terminated,
      notes: _notes.text,
    );

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveTenancy(values, id: widget.tenancy?['id'] as String?),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(tenanciesProvider(widget.siteId));
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final units =
        ref.watch(propertyUnitsProvider(widget.siteId)).valueOrNull ??
            const <Map<String, dynamic>>[];
    final contacts =
        ref.watch(contactsProvider((type: 'customer', search: ''))).valueOrNull ??
            const <Contact>[];

    // Common property is not let.
    final lettable = units.where((u) => u['unit_type'] != 'common');

    return AlertDialog(
      title: Text(_isNew ? 'Let a unit' : 'Amend the tenancy'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SearchablePicker<String>(
                  key: const ValueKey('tenancy-unit'),
                  options: [
                    for (final u in lettable)
                      PickerOption<String>(
                        value: u['id'] as String,
                        label: '${u['unit_no']}',
                      ),
                  ],
                  value: _unitId,
                  label: 'Unit',
                  // A block of two hundred parcels is two hundred rows,
                  // and the one somebody wants is the one on the lease
                  // in front of them.
                  hint: 'Type a unit number',
                  enabled: !_saving,
                  onChanged: (v) => setState(() => _unitId = v),
                  validator: (v) => v == null ? 'Required' : null,
                ),
                const SizedBox(height: Space.md),
                SearchablePicker<String>(
                  key: const ValueKey('tenancy-tenant'),
                  options: contactPickerOptions(contacts),
                  value: _tenantId,
                  label: 'Tenant',
                  hint: 'Type a name or a code',
                  enabled: !_saving,
                  createLabel: 'Add tenant',
                  // A new tenancy is usually a new tenant, so this is
                  // the box where somebody is least likely to be on
                  // file already.
                  onCreate: (typed) => createContactFromPicker(
                    context,
                    contactType: 'customer',
                    typed: typed,
                  ),
                  onChanged: (v) => setState(() => _tenantId = v),
                  validator: (v) => v == null ? 'Required' : null,
                ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('tenancy-no'),
                      controller: _no,
                      enabled: !_saving,
                      textCapitalization: TextCapitalization.characters,
                      decoration:
                          const InputDecoration(labelText: 'Tenancy no'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        for (final e in tenancyStatusNames.entries)
                          DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                      ],
                      onChanged:
                          _saving ? null : (v) => setState(() => _status = v!),
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Commences',
                      value: _start,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _start = d),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: StatutoryDateField(
                      label: 'Expires',
                      value: _end,
                      enabled: !_saving,
                      onChanged: (d) => setState(() => _end = d),
                    ),
                  ),
                ]),
                if (_start != null && _end != null && !datesRun(_start, _end))
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'A tenancy cannot expire before it commences.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.colors.danger),
                    ),
                  ),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      key: const ValueKey('tenancy-rent'),
                      controller: _rent,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Monthly rent'),
                      validator: (v) =>
                          moneyOf(v ?? '') == null ? 'An amount' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _dueDay,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Due on the',
                        helperText: '1 to 28',
                      ),
                      validator: (v) =>
                          rentDueDayOf(v ?? '') == null ? '1 to 28' : null,
                    ),
                  ),
                ]),
                const SizedBox(height: Space.md),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _security,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Security deposit'),
                      validator: (v) =>
                          moneyOf(v ?? '') == null ? 'An amount' : null,
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: TextFormField(
                      controller: _utility,
                      enabled: !_saving,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration:
                          const InputDecoration(labelText: 'Utility deposit'),
                      validator: (v) =>
                          moneyOf(v ?? '') == null ? 'An amount' : null,
                    ),
                  ),
                ]),
                if (!_isNew) ...[
                  const SizedBox(height: Space.md),
                  TextFormField(
                    controller: _held,
                    enabled: !_saving,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Deposit held',
                      helperText: 'What is actually held today. It parts from '
                          'the agreed figures when a deposit is forfeited, '
                          'topped up or refunded.',
                    ),
                    validator: (v) =>
                        moneyOf(v ?? '') == null ? 'An amount' : null,
                  ),
                ],
                if (_status == 'terminated') ...[
                  const SizedBox(height: Space.md),
                  StatutoryDateField(
                    label: 'Terminated on',
                    value: _terminated,
                    enabled: !_saving,
                    onChanged: (d) => setState(() => _terminated = d),
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
          key: const ValueKey('tenancy-save'),
          onPressed: _saving || !datesRun(_start, _end) ? null : _save,
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
