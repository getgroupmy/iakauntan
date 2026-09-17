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
            const _Filters(),
            AsyncView(
              value: entries,
              onRetry: () => ref.invalidate(auditTrailProvider),
              loading: const LinearProgressIndicator(),
              builder: (list) => list.isEmpty
                  ? Text(
                      auditTrailEmptyLine(ref.watch(auditFilterProvider)),
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
    'number_sequences': 'Document numbering',
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


/// The two filters somebody actually arrives with: a person and a range
/// of days.
///
/// `0634`. The trail is capped at 500 rows newest first, so "who
/// changed the bank details in March" was unanswerable once five
/// hundred things had happened since.
///
/// Reading the trail WRITES a `sensitive_read`, so nothing here reads
/// on change: the dates are picked in a dialog that returns once, and
/// the person is a dropdown that closes. There is no free-text field to
/// re-read on every keystroke, which is the shape this had to avoid.
class _Filters extends ConsumerWidget {
  const _Filters();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(auditFilterProvider);
    final actors = ref.watch(auditTrailActorsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Only where there is more than one person to choose between:
          // a company where one person has changed everything does not
          // need a filter that can only say "that person".
          if (actors.length > 1)
            DropdownButton<String?>(
              key: const ValueKey('audit-actor'),
              value: filter.actorId,
              hint: const Text('Anyone'),
              underline: const SizedBox.shrink(),
              items: [
                const DropdownMenuItem(value: null, child: Text('Anyone')),
                for (final a in actors)
                  DropdownMenuItem(
                    value: a['user_id']?.toString(),
                    child: Text(a['name']?.toString() ?? ''),
                  ),
              ],
              onChanged: (v) => ref
                  .read(auditFilterProvider.notifier)
                  .update((f) => f.copyWith(actorId: v)),
            ),
          OutlinedButton.icon(
            key: const ValueKey('audit-dates'),
            icon: const Icon(Icons.date_range, size: 16),
            label: Text(auditRangeLabel(filter)),
            onPressed: () async {
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime.now(),
                initialDateRange: filter.from == null || filter.to == null
                    ? null
                    : DateTimeRange(start: filter.from!, end: filter.to!),
              );
              if (picked == null) return;
              ref.read(auditFilterProvider.notifier).update(
                    (f) => f.copyWith(from: picked.start, to: picked.end),
                  );
            },
          ),
          if (!filter.isEmpty)
            TextButton(
              key: const ValueKey('audit-clear'),
              onPressed: () => ref
                  .read(auditFilterProvider.notifier)
                  .update((_) => const AuditFilter()),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

/// What the date button says.
///
/// The RANGE when there is one, because "1 Mar – 31 Mar" is what
/// somebody needs to see to know the list in front of them is not
/// everything.
String auditRangeLabel(AuditFilter filter) {
  if (filter.from == null && filter.to == null) return 'Any date';
  if (filter.from != null && filter.to != null) {
    return '${Fmt.date(filter.from)} – ${Fmt.date(filter.to)}';
  }
  return filter.from != null
      ? 'From ${Fmt.date(filter.from)}'
      : 'To ${Fmt.date(filter.to)}';
}

/// What an empty list means, which depends on whether anything is
/// filtered.
///
/// "Nothing recorded yet" is wrong and discouraging when the truth is
/// "nothing in March by that person" — and somebody who believes the
/// first will stop looking.
String auditTrailEmptyLine(AuditFilter filter) => filter.isEmpty
    ? 'Nothing recorded yet. Entries appear as records are created, '
          'amended or removed.'
    : 'Nothing matches those filters. Widen the dates, or choose '
          'anyone.';
