import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';

/// Property, on the screen side.
///
/// The arithmetic is asserted in `supabase/tests/property.sql`, where it
/// belongs — share-unit apportionment, the ten per cent sinking fund and
/// the late payment charge are the database's job and are proved there.
///
/// What is asserted here is the one thing the screens have to get right
/// on their own: that the two modules stay two. A company that bought
/// only the strata module must not be shown a portfolio filtered to
/// include shoplots it cannot manage, and a company that bought only
/// non-strata must not be offered a strata scheme.
void main() {
  ProviderContainer harness({
    required Set<String> modules,
    Map<String?, List<Map<String, dynamic>>> sites = const {},
  }) {
    final c = ProviderContainer(
      overrides: [
        repoProvider.overrideWithValue(null),
        enabledModulesProvider.overrideWith((ref) async => modules),
        propertySitesProvider.overrideWith(
          (ref, tenure) async => sites[tenure] ?? const [],
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('which portfolio a company is shown', () {
    test('holding both modules asks for everything', () async {
      final c = harness(
        modules: {'property_strata', 'property_nonstrata'},
        sites: {
          null: const [
            {
              'id': '1',
              'code': 'PR1',
              'name': 'Probe Residency',
              'tenure': 'strata',
            },
            {
              'id': '2',
              'code': 'ROW1',
              'name': 'Jalan Probe',
              'tenure': 'non_strata',
            },
          ],
        },
      );

      // Null tenure is "the whole portfolio", which is what an agent
      // managing both kinds of property is looking at.
      final rows = await c.read(propertySitesProvider(null).future);
      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r['tenure']),
        containsAll(<String>['strata', 'non_strata']),
      );
    });

    test('holding only strata asks only for strata', () async {
      final c = harness(
        modules: {'property_strata'},
        sites: {
          'strata': const [
            {
              'id': '1',
              'code': 'PR1',
              'name': 'Probe Residency',
              'tenure': 'strata',
            },
          ],
          null: const [
            {'id': '1', 'tenure': 'strata'},
            {'id': '2', 'tenure': 'non_strata'},
          ],
        },
      );

      final rows = await c.read(propertySitesProvider('strata').future);
      expect(rows, hasLength(1));
      expect(rows.single['tenure'], 'strata');
    });

    test('and the modules are genuinely separate', () async {
      // Not a tautology worth skipping: the whole point of splitting the
      // module in two is that buying one does not buy the other, and the
      // cheapest way to break it is a single 'property' code somewhere.
      final c = harness(modules: {'property_nonstrata'});
      final modules = await c.read(enabledModulesProvider.future);
      expect(modules.contains('property_nonstrata'), isTrue);
      expect(modules.contains('property_strata'), isFalse);
    });
  });

  group('the statutory bill list', () {
    test('is asked for across the portfolio, not per site', () async {
      // Quit rent and assessment are missed by not opening the site they
      // belong to, so the provider takes no site argument at all. This
      // asserts the shape rather than the data: a future signature with
      // a siteId would fail to compile against this line.
      final c = ProviderContainer(
        overrides: [
          repoProvider.overrideWithValue(null),
          propertyStatutoryDueProvider.overrideWith(
            (ref) async => const [
              {
                'charge_id': 'a',
                'site_name': 'Probe Residency',
                'kind': 'quit_rent',
                'amount': 1250.0,
                'is_overdue': false,
              },
              {
                'charge_id': 'b',
                'site_name': 'Jalan Probe',
                'kind': 'assessment',
                'amount': 880.0,
                'is_overdue': true,
              },
            ],
          ),
        ],
      );
      addTearDown(c.dispose);

      final rows = await c.read(propertyStatutoryDueProvider.future);
      expect(rows, hasLength(2));

      // The banner counts the overdue ones separately, because "two
      // bills due" and "one of them is already late" are different
      // sentences to read on a Monday morning.
      expect(rows.where((r) => r['is_overdue'] == true), hasLength(1));
      expect(rows.fold<num>(0, (a, r) => a + (r['amount'] as num)), 2130.0);
    });
  });
}
