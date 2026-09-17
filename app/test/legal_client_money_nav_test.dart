import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shell/app_shell.dart';

/// Client money has a door.
///
/// 0549 built both movements — money received to hold, money paid out
/// on a client's behalf — and the only way to reach either was the
/// matter screen, one matter at a time, behind a dialog headed "Type".
/// That is where you go when you already know which matter you want.
/// Somebody banking the morning's cheques does not: they have a cheque
/// and a client, and the matter is the thing they are looking up.
///
/// A page nobody can reach is the same as a page that does not exist,
/// which is what the chart-of-accounts importer taught a few commits
/// ago — fully built, and left off its own selector.
void main() {
  test('the legal module offers matters, receipts and payouts', () {
    expect(pathsForModule('legal'), containsAll(<String>[
      '/legal',
      '/legal/receipts',
      '/legal/payouts',
    ]));
  });

  test('and they belong to the legal module and no other', () {
    // A firm that has not bought it should see neither, and the server
    // refuses both RPCs without it (0549). The sidebar hiding them is
    // the courtesy that stops somebody meeting that refusal.
    for (final module in ['crm', 'accounting', 'hr', 'pos', 'inventory']) {
      expect(
        pathsForModule(module),
        isNot(anyElement(startsWith('/legal/'))),
        reason: '$module should not carry a client-money page',
      );
    }
  });

  test('the two are distinct destinations', () {
    // One path for both would be one sidebar row that highlights for
    // the other's page.
    expect(
      pathsForModule('legal').where((p) => p.startsWith('/legal/')).length,
      2,
    );
  });
}
