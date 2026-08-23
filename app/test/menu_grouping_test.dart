import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shell/app_shell.dart';

/// How the side menu is arranged.
///
/// Which doors a company is shown at all is decided elsewhere and
/// asserted in SQL — `module_surface.sql` covers entitlement. What is
/// asserted here is the arrangement, which the shell decides on its own
/// and which decides whether somebody can find anything.
typedef _Entry = ({String label, String? module});

void main() {
  const entries = <_Entry>[
    (label: 'Invoices', module: 'sales'),
    (label: 'Quotes', module: 'sales'),
    (label: 'Bills', module: 'purchases'),
    (label: 'Settings', module: null),
    (label: 'Payroll', module: 'hr'),
  ];

  const names = {
    'sales': 'Sell',
    'purchases': 'Buy',
    'hr': 'People',
  };

  List<MenuSection<_Entry>> group(bool grouped) =>
      groupByModule<_Entry>(entries, (e) => e.module, names, grouped);

  test('ungrouped is one list with no headings', () {
    final out = group(false);
    expect(out, hasLength(1));
    expect(out.single.heading, isNull);
    expect(out.single.items, hasLength(entries.length));
  });

  test('grouped gathers a module together', () {
    final out = group(true);
    final sell = out.firstWhere((s) => s.heading == 'Sell');
    expect(sell.items.map((e) => e.label), ['Invoices', 'Quotes']);
  });

  test('headings follow the order the entries arrive in', () {
    // Not alphabetical: the destination list is what decides what comes
    // first, and re-sorting here would silently override it.
    expect(
      group(true).map((s) => s.heading).toList(),
      ['Sell', 'Buy', 'People', null],
    );
  });

  test('what belongs to no module gathers at the end, unheaded', () {
    // Settings, Team and Import are the workspace rather than the
    // product. Inventing a heading for them would be inventing a module.
    final last = group(true).last;
    expect(last.heading, isNull);
    expect(last.items.map((e) => e.label), ['Settings']);
  });

  test('a module with no name of its own is headed by its code', () {
    final out = groupByModule<_Entry>(
      entries,
      (e) => e.module,
      const {'sales': 'Sell'},
      true,
    );
    expect(out.map((s) => s.heading), ['Sell', 'purchases', 'hr', null]);
  });

  test('nothing is lost or duplicated either way', () {
    for (final grouped in [true, false]) {
      final flat = group(grouped).expand((s) => s.items).toList();
      expect(flat, hasLength(entries.length));
      expect(flat.toSet(), entries.toSet());
    }
  });

  test('an empty menu stays empty rather than growing a heading', () {
    expect(groupByModule<_Entry>(const [], (e) => e.module, names, true),
        isEmpty);
  });
}
