import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/landing_settings.dart';

/// Where somebody lands when they sign in, and what they see when they
/// get there. 0527.
///
/// The fallback is the assertion that matters. A landing page is the one
/// screen a person cannot navigate away from if it fails to draw: a
/// route written by a newer build, or pointing at a module the company
/// has since given up, would leave them staring at nothing every
/// morning with no way past it.
void main() {
  bool everything(String _) => true;
  bool nothing(String _) => false;
  bool Function(String) only(Set<String> held) => held.contains;

  group('what may be offered', () {
    test('a company that holds everything is offered everything', () {
      expect(
        landingChoicesFor(everything).length,
        landingChoices.length,
      );
    });

    test('a company without the till is not offered the till', () {
      final routes = landingChoicesFor(nothing).map((c) => c.route).toSet();
      expect(routes.contains('/pos'), isFalse);
      expect(routes.contains('/purchases/bill'), isFalse);
    });

    test('but the pages every company has are always offered', () {
      final routes = landingChoicesFor(nothing).map((c) => c.route).toSet();
      // Whatever a company has bought, it has books and a to-do list.
      expect(routes, contains('/dashboard'));
      expect(routes, contains('/todos'));
      expect(routes, contains('/sales/invoice'));
    });

    test('a shop that holds the till alone is offered it and no bills', () {
      final routes =
          landingChoicesFor(only({'pos'})).map((c) => c.route).toSet();
      expect(routes, contains('/pos'));
      expect(routes.contains('/purchases/bill'), isFalse);
    });
  });

  group('where somebody actually lands', () {
    test('the default is the dashboard', () {
      expect(landingRouteFor(const UserPreferences(), everything), '/dashboard');
    });

    test('a page they chose is where they go', () {
      expect(
        landingRouteFor(
          const UserPreferences(landingRoute: '/todos'),
          everything,
        ),
        '/todos',
      );
    });

    test('a page this build does not know falls back to the dashboard', () {
      // The shape passes the database check, so it is a value that can
      // really be stored — written by a newer build, or by a screen
      // withdrawn since.
      expect(
        landingRouteFor(
          const UserPreferences(landingRoute: '/some-screen-we-removed'),
          everything,
        ),
        '/dashboard',
      );
    });

    test('and so does a page the company no longer holds', () {
      // The one that bites in practice: somebody set the till as their
      // landing page, and then the company gave up the POS module.
      expect(
        landingRouteFor(
          const UserPreferences(landingRoute: '/pos'),
          nothing,
        ),
        '/dashboard',
      );
      // The control: with the module, the same preference stands.
      expect(
        landingRouteFor(
          const UserPreferences(landingRoute: '/pos'),
          only({'pos'}),
        ),
        '/pos',
      );
    });
  });

  group('what is on the dashboard', () {
    test('somebody who has never chosen gets the five defaults', () {
      const prefs = UserPreferences();
      expect(prefs.dashboardCards.length, 5);
      for (final code in ['todos', 'ticker', 'metrics', 'trend',
          'receivables']) {
        expect(prefs.shows(code), isTrue, reason: code);
      }
    });

    test('the defaults are exactly the panels that can be chosen', () {
      // If a panel is added to the catalogue and not to the defaults,
      // nobody sees it until they open the settings screen — which is a
      // release that ships a feature switched off for everybody.
      expect(
        UserPreferences.defaultDashboardCards.toSet(),
        dashboardCardChoices.map((c) => c.code).toSet(),
      );
    });

    test('turning everything off is a choice, and is kept', () {
      const prefs = UserPreferences(dashboardCards: []);
      expect(prefs.shows('todos'), isFalse);
      expect(prefs.shows('metrics'), isFalse);
    });

    test('what comes back from the database is what was stored', () {
      final prefs = UserPreferences.fromJson({
        'landing_route': '/todos',
        'dashboard_cards': ['ticker', 'todos'],
      });
      expect(prefs.landingRoute, '/todos');
      expect(prefs.dashboardCards, ['ticker', 'todos']);
      expect(prefs.shows('metrics'), isFalse);
    });

    test('a row with nothing in it still reads as the defaults', () {
      // A partial row — or one written before a column existed — must
      // not empty somebody's dashboard.
      final prefs = UserPreferences.fromJson({});
      expect(prefs.landingRoute, '/dashboard');
      expect(prefs.dashboardCards, isEmpty);
    });
  });
}
