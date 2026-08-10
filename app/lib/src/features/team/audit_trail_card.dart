import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// Who changed what.
///
/// Filed next to the payslip access log, because they answer the same
/// question from opposite ends: that one records who *read* something,
/// this one records who *changed* it. Owners and admins only — the diffs
/// carry salaries and bank account numbers, which is exactly what the
/// payslip access rules keep away from an auditor.
class AuditTrailCard extends ConsumerWidget {
  const AuditTrailCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(auditTrailProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Change history',
              subtitle: 'Salaries, bank accounts, access and the chart of '
                  'accounts. Written by the database and not editable.',
              action: IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh',
                onPressed: () => ref.invalidate(auditTrailProvider),
              ),
            ),
            AsyncView(
              value: entries,
              onRetry: () => ref.invalidate(auditTrailProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? Text(
                      'Nothing recorded yet. Entries appear as records are '
                      'created, amended or removed.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: context.scheme.onSurfaceVariant),
                    )
                  : Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _EntryTile(entry: list[i]),
                      ],
                    ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final AuditEntry entry;

  static const _tableNames = <String, String>{
    'employees': 'Employee',
    'employee_salary_components': 'Salary component',
    'employee_ytd_opening': 'Opening year to date',
    'employee_tax_reliefs': 'Declared relief',
    'salary_components': 'Pay component',
    'payroll_settings': 'Payroll settings',
    'bank_accounts': 'Bank account',
    'accounts': 'Ledger account',
    'tax_codes': 'Tax code',
    'fiscal_periods': 'Fiscal period',
    'org_members': 'Team member',
    'org_modules': 'Module',
    'organizations': 'Company',
  };

  Color _colour(BuildContext context) => switch (entry.action) {
        'insert' => context.colors.success,
        'delete' => context.colors.danger,
        _ => context.colors.info,
      };

  String get _verb => switch (entry.action) {
        'insert' => 'added',
        'delete' => 'removed',
        _ => 'changed',
      };

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 6, right: Space.md),
            decoration: BoxDecoration(
              color: _colour(context),
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: entry.actor,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(text: ' $_verb '),
                    TextSpan(
                      text: (_tableNames[entry.tableName] ??
                              Fmt.label(entry.tableName))
                          .toLowerCase(),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
                const SizedBox(height: 2),
                Text(Fmt.dateTime(entry.at), style: muted),
                if (entry.action == 'update') ...[
                  const SizedBox(height: Space.sm),
                  for (final field in entry.fields)
                    _FieldChange(
                      field: field,
                      before: entry.before[field],
                      after: entry.after[field],
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One field, before and after. Inserts and deletes deliberately do not
/// get this treatment: the whole row is not a change anyone reads, and
/// spelling it out here would put a new employee's NRIC on screen for no
/// reason.
class _FieldChange extends StatelessWidget {
  const _FieldChange({
    required this.field,
    required this.before,
    required this.after,
  });

  final String field;
  final dynamic before;
  final dynamic after;

  /// Database enums read badly raw ("accounts_clerk"), but tidying every
  /// value would mangle the ones that are not enums — Fmt.label would
  /// turn the bank "CIMB" into "Cimb". So only the fields known to hold
  /// one get the treatment.
  static const _enumFields = {'role', 'status', 'employment_status',
      'employment_type', 'marital_status', 'residency_status'};

  String _show(dynamic v) {
    if (v == null) return '—';
    final s = v.toString();
    if (s.isEmpty) return '—';
    return _enumFields.contains(field) ? Fmt.label(s) : s;
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: context.scheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('${Fmt.label(field)}: ', style: muted),
          Text(
            _show(before),
            style: muted?.copyWith(decoration: TextDecoration.lineThrough),
          ),
          Text('  →  ', style: muted),
          Text(
            _show(after),
            style: small?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
