import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The EPF, SOCSO, EIS, PCB and HRD Corp figures every payslip is
/// calculated from.
///
/// Read-only here, and that is the design rather than an omission.
/// `statutory_schedules` and `statutory_rates` carry no organization:
/// they are one set of tables shared by every company in the database,
/// so a rate edited by one would change everybody's payroll. Only a
/// platform administrator can publish them, from the platform console.
///
/// What this screen is for is the question `README.md` says has to be
/// answered before anybody files a real return: are these the gazetted
/// figures, or the seeded placeholders? Until now there was no way to
/// look.
class StatutoryRatesTab extends ConsumerWidget {
  const StatutoryRatesTab({super.key});

  static const _bodies = <String, String>{
    'epf': 'EPF (KWSP)',
    'socso': 'SOCSO (PERKESO)',
    'eis': 'EIS',
    'pcb': 'PCB / MTD',
    'hrdf': 'HRD Corp levy',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedules = ref.watch(statutorySchedulesProvider);

    return AsyncView(
      value: schedules,
      onRetry: () => ref.invalidate(statutorySchedulesProvider),
      builder: (list) {
        final unverified = list.where((s) => s['is_verified'] != true).length;

        return ListView(
          padding: const EdgeInsets.only(bottom: Space.xxl),
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    'Statutory rates',
                    subtitle: 'Shared by every organization — only the '
                        'platform can change them',
                  ),
                  if (unverified > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: WarningPanel(
                        text: '$unverified of ${list.length} rate '
                            'table${list.length == 1 ? '' : 's'} '
                            '${unverified == 1 ? 'has' : 'have'} not been '
                            'checked against the gazette. Payroll will '
                            'calculate with them; do not file a return on '
                            'them until somebody has confirmed the figures '
                            'against the KWSP and PERKESO tables.',
                      ),
                    ),
                ],
              ),
            ),
            for (final s in list)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    Space.lg, 0, Space.lg, Space.md),
                child: _ScheduleCard(
                  schedule: s,
                  bodyName: _bodies[s['body']?.toString()] ??
                      Fmt.label(s['body']?.toString() ?? ''),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A warning that is part of the page rather than a snackbar, because
/// this one is true until somebody does something about it.
class WarningPanel extends StatelessWidget {
  const WarningPanel({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: context.colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.warning_amber_rounded,
            size: 18, color: context.colors.warning),
        const SizedBox(width: Space.sm),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.schedule, required this.bodyName});

  final Map<String, dynamic> schedule;
  final String bodyName;

  @override
  Widget build(BuildContext context) {
    final rates = (schedule['statutory_rates'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    rates.sort((a, b) => Fmt.toInt(a['sort_order'])
        .compareTo(Fmt.toInt(b['sort_order'])));

    final from = Fmt.parseDate(schedule['effective_from']);
    final to = Fmt.parseDate(schedule['effective_to']);
    final verified = schedule['is_verified'] == true;

    return Card(
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: Space.lg),
        childrenPadding:
            const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        title: Row(children: [
          Flexible(
            child: Text(bodyName,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: Space.sm),
          StatusChip(verified ? 'verified' : 'unverified', compact: true),
        ]),
        subtitle: Text(
          [
            schedule['name']?.toString() ?? '',
            to == null
                ? 'from ${Fmt.date(from)}'
                : '${Fmt.date(from)} to ${Fmt.date(to)}',
            '${rates.length} band${rates.length == 1 ? '' : 's'}',
          ].join(' · '),
          style: const TextStyle(fontSize: 12),
        ),
        children: [
          if (schedule['source'] != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: Text('Source: ${schedule['source']}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              headingRowHeight: 36,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 40,
              columns: const [
                DataColumn(label: Text('Category')),
                DataColumn(label: Text('Wage from'), numeric: true),
                DataColumn(label: Text('Wage to'), numeric: true),
                DataColumn(label: Text('Employee'), numeric: true),
                DataColumn(label: Text('Employer'), numeric: true),
              ],
              rows: [
                for (final r in rates)
                  DataRow(cells: [
                    DataCell(Text(r['category']?.toString() ?? 'default')),
                    DataCell(Text(Fmt.money(Fmt.toDouble(r['wage_from'])))),
                    DataCell(Text(r['wage_to'] == null
                        ? 'and over'
                        : Fmt.money(Fmt.toDouble(r['wage_to'])))),
                    DataCell(Text(_share(r, 'employee'))),
                    DataCell(Text(_share(r, 'employer'))),
                  ]),
              ],
            ),
          ),
          if (schedule['notes'] != null)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(schedule['notes'].toString(),
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  /// A band is either a percentage or a flat amount. Showing both
  /// columns for every schedule would fill half the table with zeros.
  static String _share(Map<String, dynamic> rate, String side) {
    final amount = rate['${side}_amount'];
    if (amount != null) return Fmt.money(Fmt.toDouble(amount));
    final percent = Fmt.toDouble(rate['${side}_rate']);
    return percent == 0 ? '—' : '${Fmt.qty(percent)}%';
  }
}
