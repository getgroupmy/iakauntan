import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import '../../data/corp_repository.dart';

/// Add or amend a company the firm acts for.
///
/// The incorporation date and the financial year end are the two fields
/// that matter most: every statutory deadline in the module is computed
/// from one or the other, so a blank here is a deadline that never
/// appears.
class CorpEntityEditor extends ConsumerStatefulWidget {
  const CorpEntityEditor({super.key, this.entityId});

  final String? entityId;

  bool get isNew => entityId == null;

  @override
  ConsumerState<CorpEntityEditor> createState() => _CorpEntityEditorState();
}

class _CorpEntityEditorState extends ConsumerState<CorpEntityEditor> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};

  String _type = 'sdn_bhd';
  String _status = 'incorporated';
  DateTime? _incorporated;
  int? _fyeDay;
  int? _fyeMonth;
  bool _auditExempt = false;
  bool _hasConstitution = false;
  bool _saving = false;
  bool _loaded = false;

  TextEditingController _ctl(String key) =>
      _c.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _hydrate(CorpEntity e) {
    if (_loaded) return;
    _loaded = true;
    _ctl('name').text = e.name;
    _ctl('registration_no').text = e.registrationNo ?? '';
    _ctl('old_registration_no').text = e.oldRegistrationNo ?? '';
    _ctl('registered_office').text = e.registeredOffice ?? '';
    _ctl('business_address').text = e.businessAddress ?? '';
    _ctl('nature_of_business').text = e.natureOfBusiness ?? '';
    _ctl('client_ref').text = e.clientRef ?? '';
    _ctl('notes').text = e.notes ?? '';
    _type = e.entityType;
    _status = e.status;
    _incorporated = e.incorporatedOn;
    _fyeDay = e.fyeDay;
    _fyeMonth = e.fyeMonth;
    _auditExempt = e.isAuditExempt;
    _hasConstitution = e.hasConstitution;
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.isNew
        ? const AsyncValue<CorpEntity?>.data(null)
        : ref.watch(corpEntityProvider(widget.entityId!));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/secretarial'),
        ),
        title: Text(widget.isNew ? 'Add company' : 'Edit company'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: existing,
        onRetry: () => ref.invalidate(corpEntityProvider),
        builder: (e) {
          if (e != null) _hydrate(e);
          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 820,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section('The company', [
                      // Name and registered office are not fields here
                      // any more on an existing company. Changing either
                      // is an event SSM has to be told about within
                      // fourteen days, and a rename loses the former
                      // name the Act requires on documents for twelve
                      // months — see `0377`, which refuses both from a
                      // plain update. The entity screen offers the
                      // actions that do it properly.
                      if (widget.entityId == null)
                        _text('name', 'Registered name *', required: true)
                      else
                        _ReadOnlyField(
                          label: 'Registered name',
                          value: _ctl('name').text,
                          note: 'Changed from the company page, where the '
                              'date and the former name are recorded with '
                              'it',
                        ),
                      _row([
                        _text('registration_no', 'Registration number',
                            helper: 'The twelve-digit SSM number'),
                        _text('old_registration_no', 'Former number',
                            helper: 'The pre-2019 format, still quoted'),
                      ]),
                      _row([
                        _dropdown<String>(
                          label: 'Type',
                          value: _type,
                          items: const {
                            'sdn_bhd': 'Private limited (Sdn Bhd)',
                            'berhad': 'Public (Berhad)',
                            'llp': 'LLP (PLT)',
                            'clbg': 'Limited by guarantee',
                            'sole_prop': 'Sole proprietor',
                            'partnership': 'Partnership',
                            'foreign': 'Foreign company',
                          },
                          onChanged: (v) => setState(() => _type = v ?? _type),
                        ),
                        _dropdown<String>(
                          label: 'Status',
                          value: _status,
                          items: const {
                            'incorporated': 'Incorporated',
                            'dormant': 'Dormant',
                            'winding_up': 'Winding up',
                            'struck_off': 'Struck off',
                            'dissolved': 'Dissolved',
                            'resigned': 'We have resigned',
                          },
                          onChanged: (v) =>
                              setState(() => _status = v ?? _status),
                        ),
                      ]),
                    ]),
                    _Section(
                      'Dates that drive the deadlines',
                      [
                        Text(
                          'The Annual Return is due within thirty days of the '
                          'anniversary of incorporation (s.68) — not from the '
                          'year end, which is the single most common reason a '
                          'company is late. Financial statements run from the '
                          'year end instead.',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: context.scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: Space.md),
                        _row([
                          _DateField(
                            label: 'Incorporated on',
                            value: _incorporated,
                            onChanged: (d) => setState(() => _incorporated = d),
                          ),
                          _row([
                            _dropdown<int>(
                              label: 'Year end day',
                              value: _fyeDay ?? 31,
                              items: {
                                for (var d = 1; d <= 31; d++) d: '$d',
                              },
                              onChanged: (v) => setState(() => _fyeDay = v),
                            ),
                            _dropdown<int>(
                              label: 'Month',
                              value: _fyeMonth ?? 12,
                              items: {
                                for (var m = 1; m <= 12; m++)
                                  m: Fmt.monthName(m),
                              },
                              onChanged: (v) => setState(() => _fyeMonth = v),
                            ),
                          ]),
                        ]),
                      ],
                    ),
                    _Section('Addresses', [
                      if (widget.entityId == null)
                        _text('registered_office', 'Registered office',
                            helper: 'Where the statutory registers are kept')
                      else
                        _ReadOnlyField(
                          label: 'Registered office',
                          value: _ctl('registered_office').text,
                          note: 'Moving it is lodged under s.46(3) within '
                              'fourteen days; change it from the company '
                              'page',
                        ),
                      _text('business_address', 'Business address'),
                      _text('nature_of_business', 'Nature of business'),
                    ]),
                    _Section('The file', [
                      _text('client_ref', 'Our reference'),
                      const SizedBox(height: Space.sm),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Constitution adopted'),
                        subtitle: const Text(
                            'A company under the 2016 Act need not have one'),
                        value: _hasConstitution,
                        onChanged: (v) => setState(() => _hasConstitution = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Exempt from audit'),
                        subtitle: const Text(
                            'Under the Registrar’s practice directive. '
                            'Unaudited accounts are still lodged.'),
                        value: _auditExempt,
                        onChanged: (v) => setState(() => _auditExempt = v),
                      ),
                      _text('notes', 'Notes'),
                    ]),
                    const SizedBox(height: Space.xxl),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: Space.md),
        child: LayoutBuilder(
          builder: (context, box) => box.maxWidth < 520
              ? Column(children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0) const SizedBox(height: Space.md),
                    children[i],
                  ],
                ])
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const SizedBox(width: Space.md),
                      Expanded(child: children[i]),
                    ],
                  ],
                ),
        ),
      );

  Widget _text(String key, String label,
          {bool required = false, String? helper}) =>
      TextFormField(
        controller: _ctl(key),
        decoration: InputDecoration(labelText: label, helperText: helper),
        validator: (v) =>
            required && (v ?? '').trim().isEmpty ? 'Required' : null,
      );

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
  }) =>
      DropdownButtonFormField<T>(
        value: items.containsKey(value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged,
      );

  String? _blank(String key) {
    final v = _ctl(key).text.trim();
    return v.isEmpty ? null : v;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final values = <String, dynamic>{
      // Omitted on an existing company: `0377` refuses a bare rename,
      // and sending the unchanged value would be a no-op that only ever
      // risks tripping the guard.
      if (widget.entityId == null) 'name': _ctl('name').text.trim(),
      'registration_no': _blank('registration_no'),
      'old_registration_no': _blank('old_registration_no'),
      'entity_type': _type,
      'status': _status,
      'incorporated_on':
          _incorporated == null ? null : Fmt.iso(_incorporated!),
      'financial_year_end_day': _fyeDay,
      'financial_year_end_month': _fyeMonth,
      if (widget.entityId == null)
        'registered_office': _blank('registered_office'),
      'business_address': _blank('business_address'),
      'nature_of_business': _blank('nature_of_business'),
      'client_ref': _blank('client_ref'),
      'is_audit_exempt': _auditExempt,
      'has_constitution': _hasConstitution,
      'notes': _blank('notes'),
    };

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveCorpEntity(values, id: widget.entityId),
      successMessage: widget.isNew ? 'Company added' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(corpEntitiesProvider);
      ref.invalidate(corpFilingsProvider);
      if (widget.entityId != null) {
        ref.invalidate(corpEntityProvider(widget.entityId!));
      }
      context.go('/secretarial');
    }
  }
}

/// A particular that is not edited here.
///
/// Shown rather than hidden: somebody opening the editor to check the
/// registered name should see it. The note says where the change lives,
/// because a greyed field with no explanation reads as broken.
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({
    required this.label,
    required this.value,
    required this.note,
  });

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        helperText: note,
        helperMaxLines: 3,
        enabled: false,
      ),
      child: Text(value.isEmpty ? '—' : value),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.lg),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [SectionHeader(title), ...children],
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(1950),
          lastDate: DateTime(DateTime.now().year + 1),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(value == null ? '—' : Fmt.date(value)),
      ),
    );
  }
}
