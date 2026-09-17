import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/imports/import_screen.dart';

/// Every importer that exists is reachable.
///
/// 0550 added the chart of accounts to `ImportKind` with its aliases,
/// its required columns, its RPC and its section heading all wired up —
/// and no button, because the segmented control beside the enum was a
/// hand-typed list of six. Everything behind it worked and none of it
/// could be reached.
///
/// The control is built from `ImportKind.values` now, so this asserts
/// the other half: that every kind has a name to put on it, and that
/// the names are distinct enough to tell apart.
void main() {
  test('every kind has a label', () {
    for (final kind in ImportKind.values) {
      expect(importKindLabel(kind).trim(), isNotEmpty,
          reason: '$kind has no label, so its button would be blank');
    }
  });

  test('the labels are distinct', () {
    final labels = ImportKind.values.map(importKindLabel).toList();
    expect(labels.toSet().length, labels.length,
        reason: 'two importers with the same label are two buttons '
            'nobody can tell apart');
  });

  test('the chart of accounts is one of them', () {
    // The one that was missing. Named rather than counted, so deleting
    // it fails by name.
    expect(ImportKind.values, contains(ImportKind.accounts));
    expect(importKindLabel(ImportKind.accounts), 'Chart of accounts');
  });

  test('the chart comes before the opening balances', () {
    // Opening balances name account numbers, so a company bringing its
    // own chart has to bring it first. The buttons are in enum order,
    // which is why the enum order is the thing asserted.
    expect(
      ImportKind.values.indexOf(ImportKind.accounts),
      lessThan(ImportKind.values.indexOf(ImportKind.openingBalances)),
    );
  });

  test('the master files come before the documents that name them', () {
    for (final master in [ImportKind.contacts, ImportKind.items]) {
      expect(
        ImportKind.values.indexOf(master),
        lessThan(ImportKind.values.indexOf(ImportKind.openInvoices)),
      );
    }
  });

  test('importing a chart needs the posting permission', () {
    // `import_accounts` asks for `can_post`: a chart decides what every
    // future posting lands on. A screen that asked for write access
    // would offer an enabled button to somebody the server refuses.
    expect(importNeedsPosting(ImportKind.accounts), isTrue);
    expect(importNeedsPosting(ImportKind.contacts), isFalse);
  });
}
