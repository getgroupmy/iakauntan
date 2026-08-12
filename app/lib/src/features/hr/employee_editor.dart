import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'employee_records.dart';
import 'tax_year_section.dart';

/// Create or amend an employee. The statutory identifiers are not
/// optional extras — payroll cannot file a return without them, so they
/// get a section of their own rather than being buried in a notes field.
class EmployeeEditor extends ConsumerStatefulWidget {
  const EmployeeEditor({super.key, this.employeeId});

  final String? employeeId;

  bool get isNew => employeeId == null;

  @override
  ConsumerState<EmployeeEditor> createState() => _EmployeeEditorState();
}

class _EmployeeEditorState extends ConsumerState<EmployeeEditor> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};

  String _status = 'probation';
  String _type = 'full_time';
  String _marital = 'single';
  String _residency = 'citizen';
  String? _departmentId;
  String? _positionId;
  DateTime _hireDate = DateTime.now();
  DateTime? _birthDate;
  bool _spouseWorking = false;
  bool _epf = true, _socso = true, _eis = true, _pcb = true, _hrdf = true;
  bool _saving = false;
  bool _loaded = false;

  TextEditingController _ctl(String key, [String? initial]) =>
      _c.putIfAbsent(key, () => TextEditingController(text: initial));

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fills the form once, the first time the record arrives.
  void _hydrate(Employee e) {
    if (_loaded) return;
    _loaded = true;
    _ctl('full_name').text = e.fullName;
    _ctl('email').text = e.email ?? '';
    _ctl('phone').text = e.phone ?? '';
    _ctl('nric').text = e.nric ?? '';
    _ctl('basic_salary').text =
        e.basicSalary == 0 ? '' : e.basicSalary.toStringAsFixed(2);
    _ctl('epf_no').text = e.epfNo ?? '';
    _ctl('socso_no').text = e.socsoNo ?? '';
    _ctl('income_tax_no').text = e.incomeTaxNo ?? '';
    _ctl('bank_name').text = e.bankName ?? '';
    _ctl('bank_account_no').text = e.bankAccountNo ?? '';
    _status = e.employmentStatus;
    _type = e.employmentType;
    _marital = e.maritalStatus;
    _residency = e.residencyStatus;
    _hireDate = e.hireDate ?? DateTime.now();
    _birthDate = e.dateOfBirth;
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.isNew
        ? const AsyncValue<Employee?>.data(null)
        : ref.watch(employeeProvider(widget.employeeId!));
    final departments = ref.watch(departmentsProvider).valueOrNull ?? const [];
    final positions = ref.watch(positionsProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/hr/people'),
        ),
        title: Text(widget.isNew ? 'New employee' : 'Edit employee'),
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
        onRetry: () => ref.invalidate(employeeProvider),
        builder: (employee) {
          if (employee != null) _hydrate(employee);

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 900,
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Section(
                      title: 'Who they are',
                      children: [
                        _text('full_name', 'Full name *',
                            required: true,
                            helper: 'Exactly as it appears on the NRIC'),
                        _row([
                          _text('email', 'Email'),
                          _text('phone', 'Phone'),
                        ]),
                        _row([
                          _text('nric', 'NRIC',
                              helper: 'Digits only, no dashes'),
                          _DateField(
                            label: 'Date of birth',
                            value: _birthDate,
                            onChanged: (d) => setState(() => _birthDate = d),
                          ),
                        ]),
                        _row([
                          _dropdown<String>(
                            label: 'Marital status',
                            value: _marital,
                            items: const {
                              'single': 'Single',
                              'married': 'Married',
                              'divorced': 'Divorced',
                              'widowed': 'Widowed',
                            },
                            onChanged: (v) => setState(() => _marital = v!),
                          ),
                          _dropdown<String>(
                            label: 'Residency',
                            value: _residency,
                            items: const {
                              'citizen': 'Malaysian citizen',
                              'permanent_resident': 'Permanent resident',
                              'expatriate': 'Expatriate',
                              'foreign_worker': 'Foreign worker',
                            },
                            onChanged: (v) => setState(() => _residency = v!),
                          ),
                        ]),
                        if (_marital == 'married')
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _spouseWorking,
                            onChanged: (v) =>
                                setState(() => _spouseWorking = v),
                            title: const Text('Spouse is working'),
                            subtitle: const Text(
                                'A spouse with no income attracts a RM4,000 '
                                'relief, which lowers the monthly PCB'),
                          ),
                      ],
                    ),
                    _Section(
                      title: 'Their job',
                      children: [
                        _row([
                          _dropdown<String?>(
                            label: 'Department',
                            value: _departmentId,
                            items: {
                              for (final d in departments)
                                d['id'] as String: d['name']?.toString() ?? '',
                            },
                            onChanged: (v) =>
                                setState(() => _departmentId = v),
                          ),
                          _dropdown<String?>(
                            label: 'Position',
                            value: _positionId,
                            items: {
                              for (final p in positions)
                                p['id'] as String: p['title']?.toString() ?? '',
                            },
                            onChanged: (v) => setState(() => _positionId = v),
                          ),
                        ]),
                        _row([
                          _dropdown<String>(
                            label: 'Employment type',
                            value: _type,
                            items: const {
                              'full_time': 'Full time',
                              'part_time': 'Part time',
                              'contract': 'Contract',
                              'internship': 'Internship',
                              'temporary': 'Temporary',
                            },
                            onChanged: (v) => setState(() => _type = v!),
                          ),
                          _dropdown<String>(
                            label: 'Status',
                            value: _status,
                            items: const {
                              'probation': 'Probation',
                              'active': 'Confirmed',
                              'notice': 'Serving notice',
                              'resigned': 'Resigned',
                              'terminated': 'Terminated',
                              'retired': 'Retired',
                              'suspended': 'Suspended',
                            },
                            onChanged: (v) => setState(() => _status = v!),
                          ),
                        ]),
                        _DateField(
                          label: 'Joined on *',
                          value: _hireDate,
                          onChanged: (d) => setState(() => _hireDate = d),
                        ),
                      ],
                    ),
                    _Section(
                      title: 'What they are paid',
                      children: [
                        _text('basic_salary', 'Basic salary (RM) *',
                            required: true,
                            number: true,
                            helper: 'Monthly, before allowances'),
                        _row([
                          _text('bank_name', 'Bank'),
                          _text('bank_account_no', 'Account number'),
                        ]),
                      ],
                    ),
                    _Section(
                      title: 'Statutory',
                      subtitle: 'Payroll cannot file a return without these',
                      children: [
                        _row([
                          _text('epf_no', 'EPF (KWSP) number'),
                          _text('socso_no', 'SOCSO number',
                              helper: 'Usually the NRIC'),
                        ]),
                        _text('income_tax_no', 'LHDN income tax file',
                            helper: 'For example SG 10203040506'),
                        const SizedBox(height: Space.sm),
                        Text('Contributes to',
                            style: Theme.of(context).textTheme.labelMedium),
                        Wrap(spacing: Space.sm, children: [
                          _toggle('EPF', _epf, (v) => setState(() => _epf = v)),
                          _toggle('SOCSO', _socso,
                              (v) => setState(() => _socso = v)),
                          _toggle('EIS', _eis, (v) => setState(() => _eis = v)),
                          _toggle('PCB', _pcb, (v) => setState(() => _pcb = v)),
                          _toggle('HRD Corp', _hrdf,
                              (v) => setState(() => _hrdf = v)),
                        ]),
                      ],
                    ),
                    // Only once the employee exists: both of these hang
                    // off an employee id, and there is nothing sensible
                    // to attach them to before Save.
                    if (!widget.isNew) ...[
                      TaxYearSection(employeeId: widget.employeeId!),
                      EmployeeRecords(employeeId: widget.employeeId!),
                    ],
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
          builder: (context, box) => box.maxWidth < 560
              ? Column(
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const SizedBox(height: Space.md),
                      children[i],
                    ],
                  ],
                )
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
      {bool required = false, bool number = false, String? helper}) {
    return TextFormField(
      controller: _ctl(key),
      keyboardType:
          number ? const TextInputType.numberWithOptions(decimal: true) : null,
      decoration: InputDecoration(labelText: label, helperText: helper),
      validator: (v) {
        final value = (v ?? '').trim();
        if (required && value.isEmpty) return 'Required';
        if (number && value.isNotEmpty && double.tryParse(value) == null) {
          return 'Enter a number';
        }
        return null;
      },
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required Map<String, String> items,
    required ValueChanged<T?> onChanged,
  }) {
    return DropdownButtonFormField<T>(
      value: items.containsKey(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final e in items.entries)
          DropdownMenuItem(value: e.key as T, child: Text(e.value)),
      ],
      onChanged: onChanged,
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) =>
      FilterChip(
        label: Text(label),
        selected: value,
        onSelected: onChanged,
      );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final values = <String, dynamic>{
      'full_name': _ctl('full_name').text.trim(),
      'email': _nullIfBlank('email'),
      'phone': _nullIfBlank('phone'),
      'nric': _nullIfBlank('nric'),
      'date_of_birth': _birthDate == null ? null : Fmt.iso(_birthDate!),
      'marital_status': _marital,
      'spouse_is_working': _spouseWorking,
      'residency_status': _residency,
      'department_id': _departmentId,
      'position_id': _positionId,
      'employment_type': _type,
      'employment_status': _status,
      'hire_date': Fmt.iso(_hireDate),
      'basic_salary':
          double.tryParse(_ctl('basic_salary').text.trim()) ?? 0,
      'bank_name': _nullIfBlank('bank_name'),
      'bank_account_no': _nullIfBlank('bank_account_no'),
      'epf_no': _nullIfBlank('epf_no'),
      'socso_no': _nullIfBlank('socso_no'),
      'income_tax_no': _nullIfBlank('income_tax_no'),
      'epf_eligible': _epf,
      'socso_eligible': _socso,
      'eis_eligible': _eis,
      'pcb_eligible': _pcb,
      'hrdf_eligible': _hrdf,
    };

    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .saveEmployee(values, id: widget.employeeId),
      successMessage: widget.isNew ? 'Employee added' : 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(directoryProvider);
      ref.invalidate(employeesProvider);
      if (widget.employeeId != null) {
        ref.invalidate(employeeProvider(widget.employeeId!));
      }
      context.go('/hr/people');
    }
  }

  String? _nullIfBlank(String key) {
    final v = _ctl(key).text.trim();
    return v.isEmpty ? null : v;
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
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
            children: [
              SectionHeader(title, subtitle: subtitle),
              ...children,
            ],
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
          initialDate: value ?? DateTime(DateTime.now().year - 25),
          firstDate: DateTime(1940),
          lastDate: DateTime(DateTime.now().year + 2),
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
