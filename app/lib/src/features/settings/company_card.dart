import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/address_field.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/places_repository.dart';
import '../../data/repository.dart';
import 'msic_picker.dart';

bool _present(String? s) => s != null && s.trim().isNotEmpty;

/// The parts of an address that exist, on one line. Empty is "Not set"
/// rather than a run of commas, because a company with no address needs
/// to be told so plainly — it is what LHDN will receive.
String _oneLine(List<String?> parts) {
  final kept = parts.where(_present).map((s) => s!.trim()).toList();
  return kept.isEmpty ? 'Not set' : kept.join(', ');
}

class CompanyCard extends ConsumerWidget {
  const CompanyCard({super.key, required this.org});

  final Organization org;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAdmin = ref.watch(canAdminProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Company',
              action: canAdmin
                  ? TextButton.icon(
                      key: const ValueKey('edit-company'),
                      onPressed: () async {
                        final saved = await showDialog<bool>(
                          context: context,
                          builder: (_) => _CompanyDialog(org: org),
                        );
                        if (saved == true) {
                          ref.invalidate(organizationsProvider);
                          refreshOrganization(ref);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    )
                  : null,
            ),
            _LogoRow(org: org),
            const SizedBox(height: Space.md),
            _StationeryRow(org: org),
            const Divider(height: Space.xl),
            FieldRow(label: 'Name', value: org.name),
            FieldRow(label: 'Entity type', value: Fmt.label(org.entityType)),
            FieldRow(
              label: 'SSM registration',
              value: org.registrationNo ?? 'Not set',
            ),
            FieldRow(label: 'LHDN TIN', value: org.tin ?? 'Not set'),
            FieldRow(
              label: 'SST',
              value: org.isSstRegistered
                  ? [
                      org.sstRegistrationNo ?? 'Registered',
                      if (org.sstRegisteredFrom != null)
                        'from ${Fmt.date(org.sstRegisteredFrom!)}',
                    ].join(' · ')
                  : 'Not registered',
            ),
            FieldRow(label: 'MSIC code', value: org.msicCode ?? 'Not set'),
            // Shown rather than only editable. An address that goes to
            // LHDN on every invoice is worth being able to check at a
            // glance, and "Not set" is the state that matters.
            FieldRow(
              label: 'Business address',
              value: _oneLine([
                org.addressLine1,
                org.addressLine2,
                org.addressLine3,
                [org.postcode, org.city].where(_present).join(' '),
                org.stateCode,
              ]),
            ),
            FieldRow(
              label: 'Registered office',
              value: org.hasSeparateRegisteredAddress
                  ? _oneLine([
                      org.registeredAddressLine1,
                      org.registeredAddressLine2,
                      org.registeredAddressLine3,
                      [
                        org.registeredPostcode,
                        org.registeredCity,
                      ].where(_present).join(' '),
                      org.registeredStateCode,
                    ])
                  : 'Same as the business address',
            ),
            FieldRow(label: 'Email', value: org.email ?? 'Not set'),
            FieldRow(label: 'Phone', value: org.phone ?? 'Not set'),
            FieldRow(label: 'Base currency', value: org.baseCurrency),
            FieldRow(label: 'Rounding', value: Fmt.label(org.roundingMethod)),
          ],
        ),
      ),
    );
  }
}

/// The company's own particulars.
///
/// These were read-only on screen and had been writable in the database
/// since 0010 — `organizations_update` has checked `can_admin` all along
/// — so nothing here widens a permission. There was simply never a form.
///
/// Base currency is the exception and is handled apart from the rest.
class _CompanyDialog extends ConsumerStatefulWidget {
  const _CompanyDialog({required this.org});

  final Organization org;

  @override
  ConsumerState<_CompanyDialog> createState() => _CompanyDialogState();
}

class _CompanyDialogState extends ConsumerState<_CompanyDialog> {
  final _name = TextEditingController();
  final _registrationNo = TextEditingController();
  final _tin = TextEditingController();
  final _msic = TextEditingController();
  final _currency = TextEditingController();
  final _line1 = TextEditingController();
  final _line2 = TextEditingController();
  final _line3 = TextEditingController();
  final _postcode = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _regLine1 = TextEditingController();
  final _regLine2 = TextEditingController();
  final _regLine3 = TextEditingController();
  final _regPostcode = TextEditingController();
  final _regCity = TextEditingController();
  final _regState = TextEditingController();

  /// Most companies file their trading address as their registered
  /// office, so that is the state the form opens in unless the company
  /// has said otherwise.
  late bool _registeredSameAsBusiness;

  late String _entityType;
  late String _rounding;
  bool _saving = false;

  static const _entityTypes = {
    'sdn_bhd': 'Private limited (Sdn Bhd)',
    'bhd': 'Public limited (Berhad)',
    'llp': 'Limited liability partnership (PLT)',
    'enterprise': 'Enterprise',
    'sole_proprietor': 'Sole proprietor',
    'partnership': 'Partnership',
    'association': 'Association',
    'government': 'Government',
    'individual': 'Individual',
    'other': 'Other',
  };

  static const _roundings = {
    'none': 'None',
    'nearest_5cent': 'Nearest 5 sen',
    'nearest_10cent': 'Nearest 10 sen',
  };

  @override
  void initState() {
    super.initState();
    final o = widget.org;
    _name.text = o.name;
    _registrationNo.text = o.registrationNo ?? '';
    _tin.text = o.tin ?? '';
    _msic.text = o.msicCode ?? '';
    _currency.text = o.baseCurrency;
    _entityType = _entityTypes.containsKey(o.entityType)
        ? o.entityType
        : 'other';
    _rounding = _roundings.containsKey(o.roundingMethod)
        ? o.roundingMethod
        : 'none';

    _line1.text = o.addressLine1 ?? '';
    _line2.text = o.addressLine2 ?? '';
    _line3.text = o.addressLine3 ?? '';
    _postcode.text = o.postcode ?? '';
    _city.text = o.city ?? '';
    _state.text = o.stateCode ?? '';
    _email.text = o.email ?? '';
    _phone.text = o.phone ?? '';

    _registeredSameAsBusiness = !o.hasSeparateRegisteredAddress;
    _regLine1.text = o.registeredAddressLine1 ?? '';
    _regLine2.text = o.registeredAddressLine2 ?? '';
    _regLine3.text = o.registeredAddressLine3 ?? '';
    _regPostcode.text = o.registeredPostcode ?? '';
    _regCity.text = o.registeredCity ?? '';
    _regState.text = o.registeredStateCode ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _registrationNo.dispose();
    _tin.dispose();
    _msic.dispose();
    _currency.dispose();
    for (final c in [
      _line1,
      _line2,
      _line3,
      _postcode,
      _city,
      _state,
      _email,
      _phone,
      _regLine1,
      _regLine2,
      _regLine3,
      _regPostcode,
      _regCity,
      _regState,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final repo = ref.read(repoProvider)!;

    final ok = await runWithFeedback(
      context,
      action: () async {
        await repo.updateCompanyDetails(
          name: _name.text.trim(),
          entityType: _entityType,
          roundingMethod: _rounding,
          registrationNo: _registrationNo.text,
          tin: _tin.text,
          msicCode: _msic.text,
          addressLine1: _line1.text,
          addressLine2: _line2.text,
          addressLine3: _line3.text,
          postcode: _postcode.text,
          city: _city.text,
          stateCode: _state.text,
          email: _email.text,
          phone: _phone.text,
          // Sending nulls when it is the same address is the whole
          // point: one address in one place, rather than two that drift.
          registeredAddressLine1: _registeredSameAsBusiness
              ? null
              : _regLine1.text,
          registeredAddressLine2: _registeredSameAsBusiness
              ? null
              : _regLine2.text,
          registeredAddressLine3: _registeredSameAsBusiness
              ? null
              : _regLine3.text,
          registeredPostcode: _registeredSameAsBusiness
              ? null
              : _regPostcode.text,
          registeredCity: _registeredSameAsBusiness ? null : _regCity.text,
          registeredStateCode: _registeredSameAsBusiness
              ? null
              : _regState.text,
        );

        // Separately, and only when it actually changed, so a company
        // that has posted nothing does not get a second write every
        // time somebody corrects a phone number.
        final code = _currency.text.trim().toUpperCase();
        if (code.isNotEmpty && code != widget.org.baseCurrency) {
          await repo.setBaseCurrency(code);
        }
      },
      successMessage: 'Company details saved',
    );

    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // Anything in the ledger and the base currency stops being editable.
    // Loading counts as posted: guessing "probably empty" the one time
    // it is wrong relabels every figure the company has.
    final posted = ref.watch(hasPostingsProvider).value ?? true;

    // Watched rather than read, so the reference list is on its way
    // before anybody picks a suggestion. A state arriving after the
    // pick would leave the box empty with no way to tell why.
    final states = ref.watch(refStatesProvider).valueOrNull ?? const [];
    final country = ref.watch(orgCountryAlpha2Provider);

    return AlertDialog(
      title: const Text('Company details'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('company-name'),
                controller: _name,
                enabled: !_saving,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _entityType,
                decoration: const InputDecoration(labelText: 'Entity type'),
                items: [
                  for (final e in _entityTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _entityType = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('company-registration'),
                controller: _registrationNo,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'SSM registration',
                  hintText: '202401234567',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('company-tin'),
                controller: _tin,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'LHDN TIN',
                  helperText: 'Required before anything goes to MyInvois',
                ),
              ),
              const SizedBox(height: 12),
              // Picked, not typed. A wrong MSIC code is a misstatement
              // on the incorporation and on every annual return after
              // it, and it is not a thing anybody types correctly from
              // memory.
              Consumer(
                builder: (context, ref, _) {
                  final all =
                      ref.watch(msicCodesProvider).valueOrNull ??
                      const <Map<String, dynamic>>[];
                  return ListTile(
                    key: const ValueKey('company-msic'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('What the business does'),
                    subtitle: Text(msicSummary(all, _msic.text)),
                    trailing: const Icon(Icons.search, size: 18),
                    onTap: _saving
                        ? null
                        : () async {
                            final picked = await pickMsicCode(
                              context,
                              current: _msic.text.trim().isEmpty
                                  ? null
                                  : _msic.text.trim(),
                            );
                            if (picked != null) {
                              setState(() => _msic.text = picked);
                            }
                          },
                  );
                },
              ),
              const Divider(height: Space.xl),
              Text(
                'Business address',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Text(
                'What goes on the invoice, and what LHDN receives as the '
                'supplier address when an e-Invoice is submitted.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: Space.sm),
              AddressField(
                fieldKey: const ValueKey('company-address1'),
                controller: _line1,
                enabled: !_saving,
                label: 'Address line 1',
                country: country,
                onChosen: (a) => fillAddressBoxes(
                  a,
                  states,
                  postcode: _postcode,
                  city: _city,
                  stateCode: _state,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _line2,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Address line 2'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _line3,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: 'Address line 3'),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: TextField(
                      controller: _postcode,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'Postcode'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _city,
                      enabled: !_saving,
                      decoration: const InputDecoration(labelText: 'City'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _state,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'State',
                        hintText: '14',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _email,
                      enabled: !_saving,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      enabled: !_saving,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(labelText: 'Phone'),
                    ),
                  ),
                ],
              ),
              const Divider(height: Space.xl),
              Text(
                'Registered office',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Text(
                'The address filed with SSM, which for many companies is '
                'their secretary\'s office rather than anywhere they trade.',
                style: TextStyle(fontSize: 12),
              ),
              CheckboxListTile(
                key: const ValueKey('company-registered-same'),
                contentPadding: EdgeInsets.zero,
                value: _registeredSameAsBusiness,
                onChanged: _saving
                    ? null
                    : (v) =>
                          setState(() => _registeredSameAsBusiness = v ?? true),
                title: const Text('Same as the business address'),
              ),
              if (!_registeredSameAsBusiness) ...[
                AddressField(
                  fieldKey: const ValueKey('company-registered-address1'),
                  controller: _regLine1,
                  enabled: !_saving,
                  label: 'Address line 1',
                  country: country,
                  onChosen: (a) => fillAddressBoxes(
                    a,
                    states,
                    postcode: _regPostcode,
                    city: _regCity,
                    stateCode: _regState,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _regLine2,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Address line 2',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _regLine3,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Address line 3',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _regPostcode,
                        enabled: !_saving,
                        decoration: const InputDecoration(
                          labelText: 'Postcode',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _regCity,
                        enabled: !_saving,
                        decoration: const InputDecoration(labelText: 'City'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _regState,
                        enabled: !_saving,
                        decoration: const InputDecoration(labelText: 'State'),
                      ),
                    ),
                  ],
                ),
              ],
              // SST is not edited here. It is four facts that have to
              // move together and it has its own card below, because a
              // registration saved halfway is a company charging tax it
              // is not registered for, or not charging tax it owes.
              const Divider(height: Space.xl),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _rounding,
                decoration: const InputDecoration(
                  labelText: 'Rounding',
                  helperText: 'Applied to the cash total on a document',
                ),
                items: [
                  for (final e in _roundings.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _rounding = v!),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('company-currency'),
                controller: _currency,
                enabled: !_saving && !posted,
                textCapitalization: TextCapitalization.characters,
                maxLength: 3,
                decoration: InputDecoration(
                  labelText: 'Base currency',
                  counterText: '',
                  // The whole reason this field is locked, said where
                  // somebody would otherwise go looking for a bug.
                  helperText: posted
                      ? 'Fixed once anything is posted — every amount in '
                            'the ledger is a number in this currency, and '
                            'changing it would re-label them all rather '
                            'than convert them.'
                      : 'Can still be changed: nothing has been posted yet.',
                  helperMaxLines: 4,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _name.text.trim().isEmpty || _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _LogoRow extends ConsumerStatefulWidget {
  const _LogoRow({required this.org});

  final Organization org;

  @override
  ConsumerState<_LogoRow> createState() => _LogoRowState();
}

class _LogoRowState extends ConsumerState<_LogoRow> {
  bool _busy = false;

  Future<void> _pick() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Image', extensions: ['png', 'jpg', 'jpeg', 'webp']),
      ],
    );
    if (file == null) return;

    final bytes = await file.readAsBytes();
    // The bucket caps at 5 MB; refusing here says why, rather than
    // letting storage return a bare 413.
    if (bytes.length > 5 * 1024 * 1024) {
      if (mounted) _say('That image is over 5 MB. Try a smaller one.');
      return;
    }

    setState(() => _busy = true);
    try {
      await repo.uploadOrgLogo(bytes, file.mimeType ?? 'image/png');
      refreshOrganization(ref);
      ref.invalidate(orgLogoProvider);
      if (mounted) _say('Logo updated');
    } catch (e) {
      if (mounted) _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      await repo.removeOrgLogo();
      refreshOrganization(ref);
      ref.invalidate(orgLogoProvider);
      if (mounted) _say('Logo removed');
    } catch (e) {
      if (mounted) _say('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final canAdmin = ref.watch(canAdminProvider);
    final url = widget.org.logoUrl;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(
            'Logo',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 64,
                width: 128,
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  border: Border.all(color: context.scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                padding: const EdgeInsets.all(6),
                child: url == null
                    ? Center(
                        child: Text(
                          'None',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    : Image.network(
                        url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                          child: Text(
                            'Could not load',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: Space.sm),
              if (canAdmin)
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _pick,
                      icon: _busy
                          ? const SizedBox(
                              height: 14,
                              width: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.upload_outlined, size: 18),
                      label: Text(url == null ? 'Upload' : 'Replace'),
                    ),
                    if (url != null) ...[
                      const SizedBox(width: Space.sm),
                      TextButton(
                        onPressed: _busy ? null : _remove,
                        child: const Text('Remove'),
                      ),
                    ],
                  ],
                )
              else
                Text(
                  'Ask an administrator to change this.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: Space.xs),
              Text(
                'PNG or JPEG, up to 5 MB. Printed at the top left of every '
                'invoice, payslip and generated document.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Companies that print onto their own letterhead paper.
///
/// Whether a business owns pre-printed stationery is a fact about the
/// business rather than about one invoice, so it lives here instead of in
/// a menu on every download. Off means the PDF is complete on its own,
/// which is the only safe default for a file that gets e-mailed.

class _StationeryRow extends ConsumerStatefulWidget {
  const _StationeryRow({required this.org});

  final Organization org;

  @override
  ConsumerState<_StationeryRow> createState() => _StationeryRowState();
}

class _StationeryRowState extends ConsumerState<_StationeryRow> {
  bool _busy = false;

  Future<void> _set(bool value) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      await repo.setPreprintedLetterhead(value);
      refreshOrganization(ref);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              value
                  ? 'Invoices and payslips will leave room for your letterhead'
                  : 'Invoices and payslips will print their own letterhead',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canAdmin = ref.watch(canAdminProvider);
    final on = widget.org.usesPreprintedLetterhead;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(
            'Printed stationery',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Switch(
                    value: on,
                    onChanged: canAdmin && !_busy ? _set : null,
                  ),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Text(
                      on
                          ? 'Leaving room for your letterhead'
                          : 'Printing our own letterhead',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.xs),
              Text(
                on
                    ? 'Invoices and payslips start 42 mm down the first page, '
                          'so nothing lands on top of your printed header. Your '
                          'registration and SST numbers are still printed, '
                          'smaller, because a tax invoice has to carry them and '
                          'stationery usually does not.'
                    : 'Turn this on only if you print onto paper that already '
                          'carries your header. A PDF you e-mail should keep its '
                          'own letterhead — nothing outside the file supplies '
                          'your address.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
