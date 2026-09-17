import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/searchable_picker.dart';
import 'package:iakauntan/src/features/dashboard/dashboard_screen.dart';

/// What the dashboard offers to look at.
///
/// The screen used to open on a strip of tabs, one per module, that
/// scrolled sideways off the edge of a phone: a company holding seven
/// modules got seven tabs and no way to see the last three without
/// dragging. Worse, the first tab was whichever module happened to sort
/// first, so two people at the same company landed somewhere different
/// and neither landed anywhere general.
///
/// So the landing page is the same for everybody — the Overview — and a
/// module dashboard is something you go and ask for by name. The rule
/// for what can be asked for lives here, away from the widget, because
/// what is worth getting wrong is not the box: it is WHICH views are on
/// offer, in what order, and whether somebody can find one by typing.
void main() {
  const platform = ['accounting', 'pos', 'ticketing'];

  String nameOf(String code) => switch (code) {
        'accounting' => 'Accounting',
        'pos' => 'Point of sale',
        'ticketing' => 'Service desk',
        _ => code,
      };

  List<String> valuesFor(List<String> codes) =>
      dashboardViews(codes, nameOf).map((o) => o.value).toList();

  group('what is on offer', () {
    test('the Overview is first, and it is not a module', () {
      // First because it is where the screen lands. Not a module
      // because no module owns it: it is the figures everybody sees.
      final views = dashboardViews(platform, nameOf);
      expect(views.first.value, dashboardOverview);
      expect(views.first.label, 'Overview');
      expect(platform, isNot(contains(dashboardOverview)));
    });

    test('a company holding nothing still gets the Overview', () {
      // The failure this rules out is a picker with one row, or none:
      // the landing page has to be reachable even when there is no
      // module dashboard to switch to. (The screen hides the picker
      // entirely in that case, which is only safe because the Overview
      // is what it would have been showing anyway.)
      expect(valuesFor(const []), [dashboardOverview]);
    });

    test('then a view for each module, in the order it was given', () {
      // Which is platform order, because `dashboardTabs` hands it over
      // in `sort_order` — see dashboard_tabs_test.dart. Granting POS
      // first must not float POS above the ledger.
      expect(valuesFor(platform), ['', 'accounting', 'pos', 'ticketing']);
    });

    test('a module this person cannot reach is not on offer', () {
      // `dashboardTabs` has already dropped it. This asserts that the
      // picker adds nothing back: offering a module whose panel the
      // server will refuse is how you hand somebody a blank screen.
      expect(valuesFor(const ['pos']), ['', 'pos']);
    });

    test('the module is named, not coded', () {
      final views = dashboardViews(platform, nameOf);
      expect(views.map((o) => o.label),
          ['Overview', 'Accounting', 'Point of sale', 'Service desk']);
    });
  });

  group('finding one by typing', () {
    List<String> search(String query) =>
        matchingOptions(dashboardViews(platform, nameOf), query)
            .map((o) => o.value)
            .toList();

    test('by name', () {
      expect(search('service'), ['ticketing']);
      expect(search('point of sale'), ['pos']);
    });

    test('and by code, which is what somebody who knows it types', () {
      // "pos" is the word in the URL, in support tickets and in every
      // conversation about the product. Nobody types "Point of sale".
      expect(search('pos'), ['pos']);
      expect(search('ticketing'), ['ticketing']);
    });

    test('the Overview is findable by the words people call it', () {
      // Somebody looking for the general figures does not know the
      // screen calls them "Overview".
      for (final word in ['general', 'summary', 'home', 'everything']) {
        expect(search(word), [dashboardOverview], reason: word);
      }
    });

    test('an empty box offers every view rather than none', () {
      expect(search(''), ['', 'accounting', 'pos', 'ticketing']);
    });

    test('a word matching nothing comes back empty', () {
      // Rather than unfiltered, which is the failure that looks like a
      // working picker.
      expect(search('payroll'), isEmpty);
    });
  });
}
