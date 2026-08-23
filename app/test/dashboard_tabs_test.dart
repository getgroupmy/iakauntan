import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';

/// Which modules get a dashboard tab.
///
/// The rule is small and the screen is not testable without a Flutter
/// binding and a live Supabase, so the rule lives on its own where it
/// can be checked — the same split `groupByModule` has in the shell.
///
/// What is being protected is that two people at the same company see
/// different tabs. The server already refuses figures for a module
/// somebody's access type shuts them out of; if this let the tab through
/// anyway they would get a tab with an empty panel under it and no
/// explanation, which looks exactly like the product being broken.
void main() {
  // Platform order, as `moduleLabelsProvider` reads it: by sort_order.
  const platform = ['sales', 'accounting', 'contacts', 'einvoice', 'pos',
                    'ticketing', 'payroll'];

  test('a tab for each module this person reaches, in platform order', () {
    const mine = {'accounting', 'pos', 'ticketing'};
    expect(
      dashboardTabs(platform, mine.contains),
      ['accounting', 'pos', 'ticketing'],
    );
  });

  test('the order is the platform\'s, not the order they were granted', () {
    // A set iterates in insertion order, so granting POS before the
    // ledger must not put the POS tab first: the menu is built from
    // sort_order and the two are read side by side.
    final granted = <String>{'ticketing', 'pos', 'accounting'};
    expect(
      dashboardTabs(platform, granted.contains),
      ['accounting', 'pos', 'ticketing'],
    );
  });

  test('a module shut off for this person gets no tab', () {
    // The warehouse clerk and the bookkeeper at one company.
    expect(dashboardTabs(platform, {'pos'}.contains), ['pos']);
    expect(dashboardTabs(platform, {'accounting'}.contains), ['accounting']);
  });

  test('nobody with nothing gets no tabs at all', () {
    // Not one empty tab — none, so the screen can say why instead.
    expect(dashboardTabs(platform, (_) => false), isEmpty);
  });

  test('everything reachable gets a tab, and nothing is invented', () {
    expect(dashboardTabs(platform, (_) => true), platform);
  });

  test('a module the platform has retired cannot appear', () {
    // The codes come from the platform catalogue, so a module nobody
    // sells any more is simply not in the list to begin with — asserted
    // because the alternative is a tab for something with no screens.
    const retired = ['sales', 'accounting'];
    expect(dashboardTabs(retired, (_) => true), ['sales', 'accounting']);
    expect(dashboardTabs(retired, (_) => true), isNot(contains('pos')));
  });

  test('nothing is duplicated', () {
    final out = dashboardTabs(platform, (_) => true);
    expect(out.toSet().length, out.length);
  });
}
