import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'charge_run_sheet.dart';

/// One site, and the half of the module that applies to it.
///
/// The tabs differ by tenure because the two things genuinely differ. A
/// strata scheme has parcels with share units, a rate an AGM resolved,
/// charge runs and arrears carrying a late payment charge. A non-strata
/// site has units and tenancies. Nothing is shown greyed out on the
/// wrong kind of site — a management corporation has no tenancies to
/// see an empty tab for.
class PropertySiteScreen extends ConsumerWidget {
  const PropertySiteScreen({super.key, required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final site = ref.watch(propertySiteProvider(siteId));

    return AsyncView(
      value: site,
      onRetry: () => ref.invalidate(propertySiteProvider(siteId)),
      builder: (row) {
        final strata = row['tenure'] == 'strata';
        return DefaultTabController(
          // Three either way, but three different ones.
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(row['name'] as String? ?? 'Site'),
              bottom: TabBar(
                tabs: strata
                    ? const [
                        Tab(text: 'Parcels'),
                        Tab(text: 'Charges'),
                        Tab(text: 'Arrears'),
                      ]
                    : const [
                        Tab(text: 'Units'),
                        Tab(text: 'Tenancies'),
                        Tab(text: 'Quit rent & assessment'),
                      ],
              ),
            ),
            body: TabBarView(
              children: strata
                  ? [
                      _UnitList(siteId: siteId, strata: true),
                      _StrataCharges(siteId: siteId, site: row),
                      _Arrears(siteId: siteId),
                    ]
                  : [
                      _UnitList(siteId: siteId, strata: false),
                      _TenancyList(siteId: siteId),
                      _StatutoryList(siteId: siteId),
                    ],
            ),
          ),
        );
      },
    );
  }
}

class _UnitList extends ConsumerWidget {
  const _UnitList({required this.siteId, required this.strata});

  final String siteId;
  final bool strata;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = ref.watch(propertyUnitsProvider(siteId));

    return AsyncView(
      value: units,
      onRetry: () => ref.invalidate(propertyUnitsProvider(siteId)),
      builder: (list) {
        if (list.isEmpty) {
          return EmptyState(
            icon: Icons.meeting_room_outlined,
            title: strata ? 'No parcels yet' : 'No units yet',
            message: strata
                ? 'Enter the Schedule of Parcels. Each parcel needs its '
                      'allocated share units before it can be charged.'
                : 'Add the units at this site, then let them.',
          );
        }

        // The denominator, shown because a Schedule of Parcels that has
        // been half entered looks exactly like one that is complete
        // until somebody adds up the share units.
        final totalShare = list.fold<num>(
          0,
          (a, u) => a + ((u['share_units'] as num?) ?? 0),
        );

        return Column(
          children: [
            if (strata)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Space.lg),
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                child: Text(
                  '${list.length} parcels, $totalShare share units allocated',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Expanded(
              child: ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final u = list[i];
                  final owner = u['contacts'] as Map<String, dynamic>?;
                  return ListTile(
                    title: Text(
                      u['unit_no'] as String? ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      [
                        if (strata && u['share_units'] != null)
                          '${u['share_units']} share units',
                        if (u['built_up_sqft'] != null)
                          '${u['built_up_sqft']} sq ft',
                        owner?['name'] as String? ?? 'No owner on record',
                      ].join(' · '),
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: u['is_chargeable'] == false
                        ? const StatusChip('not charged', compact: true)
                        : null,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StrataCharges extends ConsumerWidget {
  const _StrataCharges({required this.siteId, required this.site});

  final String siteId;
  final Map<String, dynamic> site;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = ref.watch(strataSchemeProvider(siteId));

    return AsyncView(
      value: scheme,
      onRetry: () => ref.invalidate(strataSchemeProvider(siteId)),
      builder: (s) {
        if (s == null) {
          return const EmptyState(
            icon: Icons.gavel_outlined,
            title: 'No management body recorded',
            message:
                'Say whether the scheme is run by the developer, a joint '
                'management body or a management corporation, and what the '
                'AGM resolved the rate per share unit to be.',
          );
        }

        final rates =
            (s['strata_charge_rates'] as List? ?? [])
                .cast<Map<String, dynamic>>()
                .toList()
              ..sort(
                (a, b) => (b['effective_from'] as String).compareTo(
                  a['effective_from'] as String,
                ),
              );
        final current = rates.isEmpty ? null : rates.first;
        final runs = ref.watch(strataChargeRunsProvider(s['id'] as String));

        return ListView(
          padding: const EdgeInsets.all(Space.lg),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (s['stage']) {
                      'mc' => 'Management corporation',
                      'jmb' => 'Joint management body',
                      _ => 'Developer-managed',
                    }, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    if (current == null)
                      Text(
                        'No rate in force. The Charges are levied in '
                        'proportion to allocated share units, so an AGM has '
                        'to resolve the rate per share unit before anything '
                        'can be raised.',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    else
                      Text(
                        '${Fmt.money(current['rate_per_share_unit'] as num?)} '
                        'per share unit per month, sinking fund at '
                        '${current['sinking_fund_percent']}%, late payment '
                        'charge ${current['late_interest_percent']}% a year.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: current == null
                          ? null
                          : () => showChargeRunSheet(
                              context,
                              ref,
                              strata: true,
                              id: s['id'] as String,
                            ),
                      icon: const Icon(Icons.receipt_long, size: 18),
                      label: const Text('Raise charges'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Text('Past runs', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            runs.maybeWhen(
              data: (list) => list.isEmpty
                  ? Text(
                      'Nothing raised yet.',
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  : Column(
                      children: [
                        for (final r in list)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              '${Fmt.date(DateTime.parse(r['period_from'] as String))}'
                              ' – '
                              '${Fmt.date(DateTime.parse(r['period_to'] as String))}',
                            ),
                            subtitle: Text(
                              '${r['parcels']} parcels · charges '
                              '${Fmt.money(r['total_maintenance'] as num?)} · '
                              'sinking fund '
                              '${Fmt.money(r['total_sinking'] as num?)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Money(
                              (r['total_maintenance'] as num? ?? 0) +
                                  (r['total_sinking'] as num? ?? 0),
                              bold: true,
                            ),
                          ),
                      ],
                    ),
              orElse: () => const LinearProgressIndicator(),
            ),
          ],
        );
      },
    );
  }
}

class _Arrears extends ConsumerWidget {
  const _Arrears({required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = ref.watch(strataSchemeProvider(siteId));

    return scheme.maybeWhen(
      data: (s) {
        if (s == null) {
          return const EmptyState(
            icon: Icons.gavel_outlined,
            title: 'No management body recorded',
            message: 'Arrears are per scheme, and there is no scheme yet.',
          );
        }
        final arrears = ref.watch(strataArrearsProvider(s['id'] as String));
        return AsyncView(
          value: arrears,
          onRetry: () =>
              ref.invalidate(strataArrearsProvider(s['id'] as String)),
          builder: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.check_circle_outline,
                title: 'Nothing outstanding',
                message: 'Every charge raised has been paid.',
              );
            }
            final total = list.fold<num>(
              0,
              (a, r) => a + (r['total_due'] as num? ?? 0),
            );
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Space.lg),
                  color: context.colors.danger.withValues(alpha: 0.10),
                  child: Text(
                    '${list.length} unpaid, ${Fmt.money(total)} including the '
                    'late payment charge.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final r = list[i];
                      return ListTile(
                        title: Text(
                          '${r['unit_no']} · ${r['owner_name'] ?? '—'}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          '${r['doc_no']} · ${r['days_overdue']} days overdue '
                          '· charge ${Fmt.money(r['late_interest'] as num?)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Money(r['total_due'] as num?, bold: true),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
      orElse: () => const Center(child: CircularProgressIndicator()),
    );
  }
}

class _TenancyList extends ConsumerWidget {
  const _TenancyList({required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tenancies = ref.watch(tenanciesProvider(siteId));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () =>
            showChargeRunSheet(context, ref, strata: false, id: siteId),
        icon: const Icon(Icons.receipt_long),
        label: const Text('Raise rent'),
      ),
      body: AsyncView(
        value: tenancies,
        onRetry: () => ref.invalidate(tenanciesProvider(siteId)),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.assignment_outlined,
              title: 'No tenancies yet',
              message: 'Let a unit, and the rent can be invoiced from here.',
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final t = list[i];
              final unit = t['property_units'] as Map<String, dynamic>?;
              final tenant = t['contacts'] as Map<String, dynamic>?;
              return ListTile(
                title: Row(
                  children: [
                    Text(
                      '${unit?['unit_no'] ?? '—'} · ${tenant?['name'] ?? '—'}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(t['status'] as String? ?? '', compact: true),
                  ],
                ),
                subtitle: Text(
                  '${t['tenancy_no']} · '
                  '${Fmt.date(DateTime.parse(t['start_date'] as String))} to '
                  '${Fmt.date(DateTime.parse(t['end_date'] as String))} · '
                  'deposit held ${Fmt.money(t['deposit_held'] as num?)}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Money(t['monthly_rent'] as num?, bold: true),
              );
            },
          );
        },
      ),
    );
  }
}

class _StatutoryList extends ConsumerWidget {
  const _StatutoryList({required this.siteId});

  final String siteId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charges = ref.watch(propertyStatutoryChargesProvider(siteId));

    return AsyncView(
      value: charges,
      onRetry: () => ref.invalidate(propertyStatutoryChargesProvider(siteId)),
      builder: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.receipt_outlined,
            title: 'No quit rent or assessment recorded',
            message:
                'Cukai tanah is set by the state and cukai pintu by the local '
                'authority, so the amounts are entered from the bill rather '
                'than worked out here. What this keeps is the due date.',
          );
        }
        return ListView.separated(
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final c = list[i];
            final paid = c['paid_on'] != null;
            final due = DateTime.parse(c['due_date'] as String);
            final overdue = !paid && due.isBefore(DateTime.now());
            return ListTile(
              leading: Icon(
                c['kind'] == 'quit_rent'
                    ? Icons.landscape_outlined
                    : Icons.location_city_outlined,
                color: overdue ? context.colors.danger : null,
              ),
              title: Text(
                c['kind'] == 'quit_rent'
                    ? 'Quit rent (cukai tanah)'
                    : 'Assessment (cukai pintu)',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${c['period_year']}'
                '${c['period_half'] == null ? '' : ' H${c['period_half']}'} · '
                '${c['authority'] ?? '—'} · '
                '${paid ? 'paid ${Fmt.date(DateTime.parse(c['paid_on'] as String))}' : 'due ${Fmt.date(due)}'}',
                style: TextStyle(
                  fontSize: 12,
                  color: overdue ? context.colors.danger : null,
                ),
              ),
              trailing: Money(c['amount'] as num?, bold: true),
            );
          },
        );
      },
    );
  }
}
