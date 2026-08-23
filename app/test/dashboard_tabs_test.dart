import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';

/// Which modules get a dashboard tab.
///
/// The rule is small and the screen is not testable without a Flutter
/// binding and a live Supabase, so the rule lives on its own where it
/// can be checked — the same split `groupByModule` has in the shell.
///
/// What is being protected is two things. First, that two people at the
/// same company see different tabs: the server already refuses figures
/// for a module somebody's access type shuts them out of, and if this
/// let the tab through anyway they would get a tab with an empty panel
/// under it and no explanation, which looks exactly like the product
/// being broken.
///
/// Second, that a slow read cannot empty the screen. The catalogue and
/// the entitlements are two round trips that land at different times,
/// and the first version of this function took the catalogue for both —
/// so a company whose entitlements had arrived but whose catalogue had
/// not was told every module was switched off. The tests below name
/// which list is allowed to do what.
void main() {
  // Platform order, as `moduleLabelsProvider` reads it: by sort_order.
  const platform = ['sales', 'accounting', 'contacts', 'einvoice', 'pos',
                    'ticketing', 'payroll'];

  // Everything the company holds, for the cases that are about order
  // and access rather than about entitlement.
  final all = platform.toSet();

  test('a tab for each module this person reaches, in platform order', () {
    const mine = {'accounting', 'pos', 'ticketing'};
    expect(
      dashboardTabs(platform, all, mine.contains),
      ['accounting', 'pos', 'ticketing'],
    );
  });

  test('the order is the platform\'s, not the order they were granted', () {
    // A set iterates in insertion order, so granting POS before the
    // ledger must not put the POS tab first: the menu is built from
    // sort_order and the two are read side by side.
    final granted = <String>{'ticketing', 'pos', 'accounting'};
    expect(
      dashboardTabs(platform, granted, (_) => true),
      ['accounting', 'pos', 'ticketing'],
    );
  });

  test('a module shut off for this person gets no tab', () {
    // The warehouse clerk and the bookkeeper at one company.
    expect(dashboardTabs(platform, all, {'pos'}.contains), ['pos']);
    expect(
      dashboardTabs(platform, all, {'accounting'}.contains),
      ['accounting'],
    );
  });

  test('a module the company never bought gets no tab either', () {
    // Entitlement and access are separate refusals and both are final.
    expect(dashboardTabs(platform, {'pos'}, (_) => true), ['pos']);
  });

  test('nobody with nothing gets no tabs at all', () {
    // Not one empty tab — none, so the screen can say why instead.
    expect(dashboardTabs(platform, all, (_) => false), isEmpty);
    expect(dashboardTabs(platform, <String>{}, (_) => true), isEmpty);
  });

  test('everything reachable gets a tab, and nothing is invented', () {
    expect(dashboardTabs(platform, all, (_) => true), platform);
  });

  test('a module the platform has retired cannot reorder the rest', () {
    // The codes the catalogue still lists set the order. A retired one
    // is simply not in it, so it sorts after — asserted because the
    // alternative was hiding something the company is still paying for.
    const retired = ['sales', 'accounting'];
    expect(
      dashboardTabs(retired, {'sales', 'accounting'}, (_) => true),
      ['sales', 'accounting'],
    );
  });

  test('nothing is duplicated', () {
    final out = dashboardTabs(platform, all, (_) => true);
    expect(out.toSet().length, out.length);
  });

  // ---- what the catalogue is and is not allowed to decide ----

  test('a catalogue that has not arrived does not empty the dashboard', () {
    // The defect this replaced. Entitlements in hand, catalogue still in
    // flight: the company holds three modules and must get three tabs,
    // in whatever order we can manage, rather than "every module is
    // switched off".
    expect(
      dashboardTabs(const [], {'pos', 'accounting', 'ticketing'}, (_) => true),
      ['accounting', 'pos', 'ticketing'],
    );
  });

  test('and the order it does not supply is at least stable', () {
    // Code order, so two builds of the same company agree. Not the set's
    // insertion order, which is whatever the server sent.
    final a = dashboardTabs(const [], {'ticketing', 'pos'}, (_) => true);
    final b = dashboardTabs(const [], {'pos', 'ticketing'}, (_) => true);
    expect(a, b);
    expect(a, ['pos', 'ticketing']);
  });

  test('a module the catalogue never listed still gets a tab, last', () {
    // A company that bought something before the catalogue row shipped.
    // Better an unnamed tab than a module they pay for and cannot see.
    expect(
      dashboardTabs(platform, {'accounting', 'zzz_new'}, (_) => true),
      ['accounting', 'zzz_new'],
    );
  });

  test('and access still refuses it', () {
    expect(
      dashboardTabs(platform, {'accounting', 'zzz_new'},
          (c) => c != 'zzz_new'),
      ['accounting'],
    );
  });

  test('entitlements not known yet fall back to the whole catalogue', () {
    // Null is "we do not know", and the answer to not knowing is the
    // same one `moduleEnabled` gives while loading: show it. A tab for a
    // module they turn out not to hold costs an empty panel for a moment;
    // hiding one they do hold costs them the product.
    expect(dashboardTabs(platform, null, (_) => true), platform);
  });

  test('and access is still asked, even then', () {
    // Permissive about entitlement is not permissive about everything.
    expect(
      dashboardTabs(platform, null, {'pos', 'payroll'}.contains),
      ['pos', 'payroll'],
    );
  });

  test('knowing nothing at all is still no tabs', () {
    // Both reads outstanding. The screen shows a spinner, not the
    // "switched off" message, and that decision needs this to be empty.
    expect(dashboardTabs(const [], null, (_) => true), isEmpty);
  });
}
