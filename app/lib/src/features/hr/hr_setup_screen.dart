import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Everything a company has to set up before payroll means anything.
/// All of this was SQL-only, which made the module unusable by the
/// people it was built for.
class HrSetupScreen extends ConsumerWidget {
  const HrSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('HR setup'),
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Payroll'),
              Tab(text: 'Structure'),
              Tab(text: 'Pay components'),
              Tab(text: 'Leave'),
              Tab(text: 'Claims'),
              Tab(text: 'Shifts'),
            ],
          ),
        ),
        body: const TabBarView(children: [
          _PayrollSettingsTab(),
          _StructureTab(),
          _ComponentsTab(),
          _LeaveTypesTab(),
          _ClaimTypesTab(),
          _ShiftsTab(),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Payroll settings
// ---------------------------------------------------------------------
class _PayrollSettingsTab extends ConsumerStatefulWidget {
  const _PayrollSettingsTab();

  @override
  ConsumerState<_PayrollSettingsTab> createState() =>
      _PayrollSettingsTabState();
}

class _PayrollSettingsTabState extends ConsumerState<_PayrollSettingsTab> {
  final _c = <String, TextEditingController>{};
  String? _hrdf;
  int _payDay = 25;
  bool _loaded = false;
  bool _saving = false;

  TextEditingController _ctl(String k) =>
      _c.putIfAbsent(k, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(payrollSettingsProvider);

    return AsyncView(
      value: settings,
      onRetry: () => ref.invalidate(payrollSettingsProvider),
      builder: (row) {
        if (!_loaded && row != null) {
          _loaded = true;
          _ctl('employer_epf_no').text = row['employer_epf_no']?.toString() ?? '';
          _ctl('employer_socso_no').text =
              row['employer_socso_no']?.toString() ?? '';
          _ctl('employer_tax_no').text = row['employer_tax_no']?.toString() ?? '';
          _ctl('hrdf_registration_no').text =
              row['hrdf_registration_no']?.toString() ?? '';
          _hrdf = row['hrdf_category']?.toString();
          _payDay = Fmt.toInt(row['pay_day']);
        }

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('Employer registrations',
                            subtitle:
                                'These appear on the statutory submissions'),
                        _field('employer_epf_no', 'EPF (KWSP) employer number'),
                        const SizedBox(height: Space.md),
                        _field('employer_socso_no', 'SOCSO employer code'),
                        const SizedBox(height: Space.md),
                        _field('employer_tax_no', 'LHDN employer file (E number)'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('HRD Corp levy',
                            subtitle:
                                'Leave this off if the company is not liable'),
                        DropdownButtonFormField<String?>(
                          value: _hrdf,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Liability'),
                          items: const [
                            DropdownMenuItem(
                                value: null, child: Text('Not liable')),
                            DropdownMenuItem(
                                value: 'mandatory_10plus',
                                child: Text('1% — ten or more employees')),
                            DropdownMenuItem(
                                value: 'optional_5to9',
                                child: Text(
                                    '0.5% — five to nine, opted in')),
                          ],
                          onChanged: (v) => setState(() => _hrdf = v),
                        ),
                        const SizedBox(height: Space.md),
                        _field('hrdf_registration_no', 'HRD Corp registration'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('Payday',
                            subtitle:
                                'Which day of the month salaries are paid'),
                        DropdownButtonFormField<int>(
                          value: _payDay,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Day of month'),
                          items: [
                            const DropdownMenuItem(
                                value: 0, child: Text('Last day of the month')),
                            for (var d = 1; d <= 28; d++)
                              DropdownMenuItem(value: d, child: Text('$d')),
                          ],
                          onChanged: (v) => setState(() => _payDay = v ?? 25),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.lg),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Save settings'),
                  ),
                ),
                const SizedBox(height: Space.xxl),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _field(String key, String label) => TextFormField(
        controller: _ctl(key),
        decoration: InputDecoration(labelText: label),
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.savePayrollSettings({
        'employer_epf_no': _blank('employer_epf_no'),
        'employer_socso_no': _blank('employer_socso_no'),
        'employer_tax_no': _blank('employer_tax_no'),
        'hrdf_registration_no': _blank('hrdf_registration_no'),
        'hrdf_category': _hrdf,
        'pay_day': _payDay,
      }),
      successMessage: 'Payroll settings saved',
    );
    if (mounted) setState(() => _saving = false);
    ref.invalidate(payrollSettingsProvider);
  }

  String? _blank(String k) {
    final v = _ctl(k).text.trim();
    return v.isEmpty ? null : v;
  }
}

// ---------------------------------------------------------------------
// A field in a setup dialog
// ---------------------------------------------------------------------
class SetupField {
  const SetupField(
    this.key,
    this.label, {
    this.required = false,
    this.number = false,
    this.boolean = false,
    this.helper,
  });

  final String key;
  final String label;
  final bool required;
  final bool number;
  final bool boolean;
  final String? helper;
}

/// The same list-plus-dialog for every configuration table. They differ
/// only in their columns, so they should not each get their own screen.
class _SetupList extends ConsumerWidget {
  const _SetupList({
    required this.table,
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.titleOf,
    required this.subtitleOf,
    this.orderBy = 'name',
    this.emptyMessage,
  });

  final String table;
  final String title;
  final String subtitle;
  final List<SetupField> fields;
  final String Function(Map<String, dynamic> row) titleOf;
  final String Function(Map<String, dynamic> row) subtitleOf;
  final String orderBy;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final arg = (table: table, orderBy: orderBy);
    final rows = ref.watch(setupRowsProvider(arg));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: AsyncView(
        value: rows,
        onRetry: () => ref.invalidate(setupRowsProvider(arg)),
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.tune,
                title: 'Nothing set up yet',
                message: emptyMessage,
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        Space.lg, Space.lg, Space.lg, Space.sm),
                    child: SectionHeader(title, subtitle: subtitle),
                  ),
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: Space.lg, vertical: Space.xs),
                      onTap: () => _edit(context, ref, list[i]),
                      title: Text(titleOf(list[i]),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(subtitleOf(list[i]),
                          style: const TextStyle(fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Future<void> _edit(
      BuildContext context, WidgetRef ref, Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _SetupDialog(
        table: table,
        title: title,
        fields: fields,
        row: row,
      ),
    );
    if (saved == true) {
      ref.invalidate(setupRowsProvider((table: table, orderBy: orderBy)));
    }
  }
}

class _SetupDialog extends ConsumerStatefulWidget {
  const _SetupDialog({
    required this.table,
    required this.title,
    required this.fields,
    this.row,
  });

  final String table;
  final String title;
  final List<SetupField> fields;
  final Map<String, dynamic>? row;

  @override
  ConsumerState<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends ConsumerState<_SetupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{};
  final _flags = <String, bool>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final value = widget.row?[f.key];
      if (f.boolean) {
        _flags[f.key] = value == null ? true : value == true;
      } else {
        _c[f.key] = TextEditingController(text: value?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.row == null ? 'Add' : 'Edit'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final f in widget.fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.md),
                    child: f.boolean
                        ? SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _flags[f.key] ?? true,
                            onChanged: (v) => setState(() => _flags[f.key] = v),
                            title: Text(f.label),
                            subtitle:
                                f.helper == null ? null : Text(f.helper!),
                          )
                        : TextFormField(
                            controller: _c[f.key],
                            keyboardType: f.number
                                ? const TextInputType.numberWithOptions(
                                    decimal: true)
                                : null,
                            decoration: InputDecoration(
                              labelText:
                                  f.required ? '${f.label} *' : f.label,
                              helperText: f.helper,
                            ),
                            validator: (v) {
                              final value = (v ?? '').trim();
                              if (f.required && value.isEmpty) {
                                return 'Required';
                              }
                              if (f.number &&
                                  value.isNotEmpty &&
                                  double.tryParse(value) == null) {
                                return 'Enter a number';
                              }
                              return null;
                            },
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final values = <String, dynamic>{};
    for (final f in widget.fields) {
      if (f.boolean) {
        values[f.key] = _flags[f.key] ?? true;
      } else {
        final raw = _c[f.key]!.text.trim();
        values[f.key] = raw.isEmpty
            ? null
            : (f.number ? double.tryParse(raw) ?? 0 : raw);
      }
    }

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveSetupRow(
            widget.table,
            values,
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

// ---------------------------------------------------------------------
// The tabs
// ---------------------------------------------------------------------
class _StructureTab extends StatelessWidget {
  const _StructureTab();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        const TabBar(tabs: [Tab(text: 'Departments'), Tab(text: 'Positions')]),
        Expanded(
          child: TabBarView(children: [
            _SetupList(
              table: 'departments',
              title: 'Departments',
              subtitle: 'Used to group people and to analyse payroll cost',
              emptyMessage: 'Add the departments people belong to.',
              fields: const [
                SetupField('code', 'Code', required: true),
                SetupField('name', 'Name', required: true),
                SetupField('cost_centre', 'Cost centre'),
                SetupField('is_active', 'Active', boolean: true),
              ],
              titleOf: (r) => r['name']?.toString() ?? '',
              subtitleOf: (r) => [
                r['code'],
                if (r['cost_centre'] != null) r['cost_centre'],
              ].whereType<Object>().join(' · '),
            ),
            _SetupList(
              table: 'positions',
              title: 'Positions',
              subtitle: 'Job titles and their salary bands',
              orderBy: 'title',
              emptyMessage: 'Add the roles people are hired into.',
              fields: const [
                SetupField('code', 'Code', required: true),
                SetupField('title', 'Title', required: true),
                SetupField('grade', 'Grade'),
                SetupField('min_salary', 'Minimum salary', number: true),
                SetupField('max_salary', 'Maximum salary', number: true),
                SetupField('is_active', 'Active', boolean: true),
              ],
              titleOf: (r) => r['title']?.toString() ?? '',
              subtitleOf: (r) => [
                r['code'],
                if (r['grade'] != null) 'grade ${r['grade']}',
                if (r['min_salary'] != null)
                  '${Fmt.money(Fmt.toDouble(r['min_salary']))} – '
                      '${Fmt.money(Fmt.toDouble(r['max_salary']))}',
              ].whereType<Object>().join(' · '),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _ComponentsTab extends StatelessWidget {
  const _ComponentsTab();

  @override
  Widget build(BuildContext context) {
    return _SetupList(
      table: 'salary_components',
      title: 'Allowances and deductions',
      subtitle: 'The liability flags are the point: overtime is charged to '
          'SOCSO but not to EPF, a travelling allowance usually to neither',
      emptyMessage: 'Add the recurring allowances and deductions you pay.',
      fields: const [
        SetupField('code', 'Code', required: true),
        SetupField('name', 'Name', required: true),
        SetupField('default_amount', 'Default amount', number: true),
        SetupField('percent_of_basic', 'Or a percentage of basic',
            number: true),
        SetupField('is_taxable', 'Taxable', boolean: true),
        SetupField('is_epf_liable', 'Charged to EPF', boolean: true),
        SetupField('is_socso_liable', 'Charged to SOCSO', boolean: true),
        SetupField('is_eis_liable', 'Charged to EIS', boolean: true),
        SetupField('is_active', 'Active', boolean: true),
      ],
      titleOf: (r) => r['name']?.toString() ?? '',
      subtitleOf: (r) => [
        r['code'],
        if (Fmt.toDouble(r['default_amount']) > 0)
          Fmt.money(Fmt.toDouble(r['default_amount'])),
        if (r['is_epf_liable'] == true) 'EPF',
        if (r['is_socso_liable'] == true) 'SOCSO',
        if (r['is_taxable'] != true) 'not taxable',
      ].whereType<Object>().join(' · '),
    );
  }
}

class _LeaveTypesTab extends StatelessWidget {
  const _LeaveTypesTab();

  @override
  Widget build(BuildContext context) {
    return _SetupList(
      table: 'leave_types',
      title: 'Leave types',
      subtitle: 'Unpaid leave drives a salary deduction; paid leave does not',
      emptyMessage: 'Add annual, sick and any other leave you grant.',
      fields: const [
        SetupField('code', 'Code', required: true),
        SetupField('name', 'Name', required: true),
        SetupField('default_days', 'Days a year', number: true),
        SetupField('max_carry_forward', 'Days that may carry forward',
            number: true),
        SetupField('notice_days', 'Notice required, in days', number: true),
        SetupField('is_paid', 'Paid', boolean: true,
            helper: 'Turn this off and the days are deducted from salary'),
        SetupField('requires_attachment', 'Needs a document', boolean: true),
        SetupField('is_active', 'Active', boolean: true),
      ],
      titleOf: (r) => r['name']?.toString() ?? '',
      subtitleOf: (r) => [
        r['code'],
        '${Fmt.days(Fmt.toDouble(r['default_days']))} days',
        if (r['is_paid'] != true) 'unpaid',
        if (Fmt.toDouble(r['max_carry_forward']) > 0)
          'carries ${Fmt.days(Fmt.toDouble(r['max_carry_forward']))}',
      ].whereType<Object>().join(' · '),
    );
  }
}

class _ClaimTypesTab extends StatelessWidget {
  const _ClaimTypesTab();

  @override
  Widget build(BuildContext context) {
    return _SetupList(
      table: 'claim_types',
      title: 'Claim categories',
      subtitle: 'Each one names the expense account its claims are posted to',
      emptyMessage: 'Add the categories people can claim under.',
      fields: const [
        SetupField('code', 'Code', required: true),
        SetupField('name', 'Name', required: true),
        SetupField('per_claim_cap', 'Cap per claim', number: true),
        SetupField('monthly_cap', 'Cap per month', number: true),
        SetupField('requires_receipt', 'Needs a receipt', boolean: true),
        SetupField('is_active', 'Active', boolean: true),
      ],
      titleOf: (r) => r['name']?.toString() ?? '',
      subtitleOf: (r) => [
        r['code'],
        if (r['expense_account_id'] == null)
          'no account set — posts to Other Expenses',
        if (Fmt.toDouble(r['per_claim_cap']) > 0)
          'up to ${Fmt.money(Fmt.toDouble(r['per_claim_cap']))}',
      ].whereType<Object>().join(' · '),
    );
  }
}

class _ShiftsTab extends StatelessWidget {
  const _ShiftsTab();

  @override
  Widget build(BuildContext context) {
    return _SetupList(
      table: 'work_shifts',
      title: 'Shifts',
      subtitle: 'Attendance is measured against these, and so is overtime',
      emptyMessage: 'Add the working patterns people are rostered onto.',
      fields: const [
        SetupField('code', 'Code', required: true),
        SetupField('name', 'Name', required: true),
        SetupField('start_time', 'Starts', required: true, helper: '09:00'),
        SetupField('end_time', 'Ends', required: true, helper: '18:00'),
        SetupField('break_minutes', 'Break, in minutes', number: true),
        SetupField('grace_minutes', 'Grace before counting late',
            number: true),
        SetupField('crosses_midnight', 'Ends the next day', boolean: true),
        SetupField('is_active', 'Active', boolean: true),
      ],
      titleOf: (r) => r['name']?.toString() ?? '',
      subtitleOf: (r) => [
        r['code'],
        '${r['start_time'] ?? ''} – ${r['end_time'] ?? ''}',
        '${Fmt.toInt(r['break_minutes'])} min break',
      ].whereType<Object>().join(' · '),
    );
  }
}
