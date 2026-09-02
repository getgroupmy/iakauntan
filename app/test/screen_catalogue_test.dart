import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/feedback/screen_catalogue.dart';

/// The report form's module → area → screen picker.
///
/// A hand-written list of screens rots: somebody renames a route and the
/// picker goes on offering an address that no longer opens, which is
/// worse than the blank box it replaced, because now the report carries
/// a confident wrong answer instead of an empty field.
///
/// So the list is held against the router. Every route the picker offers
/// has to be a route the app declares.
void main() {
  final router = File('lib/src/core/router.dart');

  test('the router file is where this guard thinks it is', () {
    expect(
      router.existsSync(),
      isTrue,
      reason: 'router.dart moved; this guard has to move with it',
    );
  });

  final source = router.readAsStringSync();
  final declared = RegExp("path: '([^']+)'")
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  // The document lists are not written as literals: the router builds
  // them from `_documentRoutes('/sales', …)` as `/sales/:docType`. The
  // catalogue reads the same `docTypes` table, so what has to be checked
  // here is that those two prefixes are still the ones in use.
  final prefixes = RegExp(r"_documentRoutes\('([^']+)'")
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  // The helper writes the path by interpolation, so what the source
  // literally contains is `$prefix/:docType` — the guard reads text, and
  // this is the text.
  final buildsDocumentLists = declared.contains(r'$prefix/:docType');

  test('the router declares paths this guard can read', () {
    // The zero-proves-nothing check: if the regex ever stops matching,
    // every assertion below would pass against an empty set.
    expect(declared.length, greaterThan(50));
    expect(declared, contains('/dashboard'));
    expect(prefixes, containsAll(<String>['/sales', '/purchases']));
    expect(buildsDocumentLists, isTrue);
  });

  test('every screen the picker offers is a screen the app has', () {
    final missing = <String>[];
    for (final module in appScreenCatalogue) {
      for (final area in module.areas) {
        for (final screen in area.screens) {
          // Nested routes are declared by their last segment; the app
          // writes full paths at the top level and one-word paths under
          // a parent, so accept either shape.
          final last = screen.route.split('/').last;
          final prefix = '/${screen.route.split('/')[1]}';
          final isDocumentList =
              prefixes.contains(prefix) &&
              buildsDocumentLists &&
              screen.route.split('/').length == 3;
          if (!isDocumentList &&
              !declared.contains(screen.route) &&
              !declared.contains(last)) {
            missing.add('${module.label} › ${area.label} › $screen');
          }
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'these are offered by the report form and go nowhere:\n'
          '${missing.join('\n')}',
    );
  });

  test('nothing is offered twice, under two headings', () {
    final seen = <String, String>{};
    final twice = <String>[];
    for (final module in appScreenCatalogue) {
      for (final area in module.areas) {
        for (final screen in area.screens) {
          final where = '${module.label} › ${area.label}';
          if (seen.containsKey(screen.route)) {
            twice.add('${screen.route}: ${seen[screen.route]} and $where');
          }
          seen[screen.route] = where;
        }
      }
    }
    expect(twice, isEmpty, reason: twice.join('\n'));
  });

  test('every module and area has something under it', () {
    for (final module in appScreenCatalogue) {
      expect(module.areas, isNotEmpty, reason: module.label);
      for (final area in module.areas) {
        expect(area.screens, isNotEmpty, reason: '${module.label} › ${area.label}');
      }
    }
  });

  test('a screen prints as something a person can read and we can open', () {
    expect(
      const AppScreen('Payroll runs', '/hr/payroll').toString(),
      'Payroll runs (/hr/payroll)',
    );
  });
}
