import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The portfolio.
///
/// One list, not two, even though there are two modules behind it. A
/// managing agent holding both has a mixed portfolio and thinks of it as
/// one thing; the filter is there for the ones who do not. Which module
/// a site belongs to is a fact about the site — its tenure — rather than
/// a choice made on this screen.
class PropertyScreen extends ConsumerStatefulWidget {
  const PropertyScreen({super.key});

  @override
  ConsumerState<PropertyScreen> createState() => _PropertyScreenState();
}

class _PropertyScreenState extends ConsumerState<PropertyScreen> {
  String _filter = 'all';

  @override
  Widget build(BuildContext context) {
    final strata = moduleEnabled(ref, 'property_strata');
    final nonStrata = moduleEnabled(ref, 'property_nonstrata');

    // Holding one module means the filter has nothing to choose between,
    // so it is not offered and the list is narrowed to what they bought.
    final tenure = switch (_filter) {
      'strata' => 'strata',
      'non_strata' => 'non_strata',
      _ when strata && !nonStrata => 'strata',
      _ when nonStrata && !strata => 'non_strata',
      _ => null,
    };

    final sites = ref.watch(propertySitesProvider(tenure));
    final due = ref.watch(propertyStatutoryDueProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Property'),
        bottom: strata && nonStrata
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: FilterBar(
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('All')),
                      ButtonSegment(value: 'strata', label: Text('Strata')),
                      ButtonSegment(
                        value: 'non_strata',
                        label: Text('Non-strata'),
                      ),
                    ],
                    selected: {_filter},
                    onSelectionChanged: (s) =>
                        setState(() => _filter = s.first),
                  ),
                ),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/property/new'),
        icon: const Icon(Icons.add),
        label: const Text('New site'),
      ),
      body: Column(
        children: [
          // Quit rent and assessment across the whole portfolio, above
          // the list rather than inside a site. A bill is missed by not
          // opening the site it belongs to, so this never asks anyone to.
          due.maybeWhen(
            data: (rows) =>
                rows.isEmpty ? const SizedBox.shrink() : _StatutoryBanner(rows),
            orElse: () => const SizedBox.shrink(),
          ),
          Expanded(
            child: AsyncView(
              value: sites,
              onRetry: () => ref.invalidate(propertySitesProvider(tenure)),
              skeleton: const ListSkeleton(rows: 6),
              builder: (list) {
                if (list.isEmpty) {
                  return const EmptyState(
                    icon: Icons.apartment_outlined,
                    title: 'No properties yet',
                    message:
                        'Add a site to begin. A strata scheme carries parcels '
                        'and share units; anything else carries tenancies.',
                  );
                }
                return ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _SiteTile(site: list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatutoryBanner extends StatelessWidget {
  const _StatutoryBanner(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    final overdue = rows.where((r) => r['is_overdue'] == true).length;
    final total = rows.fold<num>(0, (a, r) => a + (r['amount'] as num? ?? 0));

    return Container(
      width: double.infinity,
      color: (overdue > 0 ? context.colors.danger : context.colors.warning)
          .withValues(alpha: 0.12),
      padding: const EdgeInsets.all(Space.lg),
      child: Row(
        children: [
          Icon(
            overdue > 0 ? Icons.error_outline : Icons.event_outlined,
            size: 20,
            color: overdue > 0 ? context.colors.danger : context.colors.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              overdue > 0
                  ? '$overdue quit rent or assessment bill(s) overdue, '
                        '${rows.length} outstanding, ${Fmt.money(total)} in all.'
                  : '${rows.length} quit rent or assessment bill(s) due soon, '
                        '${Fmt.money(total)} in all.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _SiteTile extends StatelessWidget {
  const _SiteTile({required this.site});

  final Map<String, dynamic> site;

  @override
  Widget build(BuildContext context) {
    final strata = site['tenure'] == 'strata';
    // PostgREST returns an aggregate embed as a one-element list.
    final counts = site['property_units'];
    final units = counts is List && counts.isNotEmpty
        ? (counts.first as Map)['count'] as int? ?? 0
        : 0;

    return ListTile(
      leading: Icon(
        strata ? Icons.apartment : Icons.storefront_outlined,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        site['name'] as String? ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${site['code']} · ${strata ? 'Strata' : 'Non-strata'} · '
        '$units unit${units == 1 ? '' : 's'}'
        '${site['city'] == null ? '' : ' · ${site['city']}'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go('/property/${site['id']}'),
    );
  }
}
