import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/settings/company_group_card.dart';

/// Recording who owns whom, which is what a consolidation turns on.
///
/// 0148 refuses to produce a consolidated trial balance until every
/// company in the group except the one being looked at has a parent
/// recorded, and its error message says "Record it in Settings" — so
/// this is the screen that sentence points at. The rules are asserted in
/// `supabase/tests/group_consolidation.sql`; what is asserted here is
/// that the screen tells the truth about them.
///
/// The load-bearing one is the button's placement.
/// `set_group_ownership` asks for administrator rights on the company
/// being *owned*, not on its parent, so a card that put one button at
/// the bottom would offer an action the database refuses for every row
/// but one. It is per row, and only on the rows where pressing it would
/// work.
void main() {
  Map<String, dynamic> company(
    String id,
    String name, {
    bool current = false,
    bool canAdmin = true,
    String? parentId,
    String? parentName,
    double? percent,
  }) => {
    'org_id': id,
    'name': name,
    'registration_no': '2026$id-X',
    'is_current': current,
    'parent_org_id': parentId,
    'parent_name': parentName,
    'owned_percent': percent,
    'can_admin': canAdmin,
  };

  Widget harness(List<Map<String, dynamic>> group, {bool admin = true}) =>
      ProviderScope(
        overrides: [
          repoProvider.overrideWithValue(null),
          groupCompaniesProvider.overrideWith((ref) async => group),
          canAdminProvider.overrideWithValue(admin),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: SingleChildScrollView(child: CompanyGroupCard()),
          ),
        ),
      );

  /// What is actually on the chooser.
  ///
  /// `find.text` is no use for this: the card lists every company in the
  /// group behind the open dialog, so an assertion that a name is absent
  /// passes only when the company is missing from the *card* too, which
  /// is not the claim. `DropdownButton` builds all of its items into the
  /// tree whether the menu is open or shut, so this asks the precise
  /// question — is this company offered as a possible owner.
  // The owner is chosen from a `SearchablePicker`, whose rows are
  // `ListTile`s in an overlay rather than menu items.
  Finder menuItem(String label) => find.widgetWithText(ListTile, label);

  final unrecorded = [
    company('a', 'Kabeer Holdings Sdn Bhd', current: true),
    company('b', 'Kabeer Trading Sdn Bhd'),
  ];

  final recorded = [
    company('a', 'Kabeer Holdings Sdn Bhd', current: true),
    company(
      'b',
      'Kabeer Trading Sdn Bhd',
      parentId: 'a',
      parentName: 'Kabeer Holdings Sdn Bhd',
      percent: 100,
    ),
  ];

  testWidgets('a group with nothing recorded says so on every row', (
    tester,
  ) async {
    await tester.pumpWidget(harness(unrecorded));
    await tester.pumpAndSettle();

    expect(find.text('Ownership not recorded'), findsNWidgets(2));
    // And says why it matters, where somebody is looking at it.
    expect(find.textContaining('consolidated report'), findsWidgets);
  });

  testWidgets('and one that is recorded reads as a share, not a measurement', (
    tester,
  ) async {
    await tester.pumpWidget(harness(recorded));
    await tester.pumpAndSettle();

    // numeric(9,4) arrives as 100.0 and '100.0%' reads like a reading
    // off an instrument.
    expect(find.text('Owned 100% by Kabeer Holdings Sdn Bhd'), findsOneWidget);
    expect(find.text('Ownership not recorded'), findsOneWidget);
  });

  testWidgets('a part share keeps its decimals', (tester) async {
    await tester.pumpWidget(
      harness([
        company('a', 'Holdings', current: true),
        company(
          'b',
          'Trading',
          parentId: 'a',
          parentName: 'Holdings',
          percent: 60.5,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Owned 60.5% by Holdings'), findsOneWidget);
  });

  testWidgets('a company on its own is not asked who owns it', (tester) async {
    // A group of one has nothing above it, and the question would only
    // be noise on the screen somebody uses to start a group.
    await tester.pumpWidget(harness([company('a', 'Holdings', current: true)]));
    await tester.pumpAndSettle();

    expect(find.text('Ownership not recorded'), findsNothing);
    expect(find.byKey(const ValueKey('ownership-a')), findsNothing);
  });

  testWidgets('the button is on the rows the database would let through, and '
      'not the others', (tester) async {
    await tester.pumpWidget(
      harness([
        company('a', 'Holdings', current: true),
        company('b', 'Trading', canAdmin: false),
      ]),
    );
    await tester.pumpAndSettle();

    // The control matters more than the absence: 'no button anywhere'
    // would pass the second half of this on its own.
    expect(find.byKey(const ValueKey('ownership-a')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ownership-b')),
      findsNothing,
      reason:
          'set_group_ownership refuses somebody who does not administer '
          'the company being owned, so offering the button would only '
          'collect a refusal',
    );
  });

  testWidgets('the chooser will not offer the company itself', (tester) async {
    await tester.pumpWidget(harness(unrecorded));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ownership-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ownership-parent')));
    await tester.pumpAndSettle();

    // Holdings is on the menu; Trading is the company being owned and a
    // company cannot own itself.
    expect(menuItem('Kabeer Holdings Sdn Bhd'), findsOneWidget);
    expect(
      menuItem('Kabeer Trading Sdn Bhd'),
      findsNothing,
      reason: 'a company cannot own itself',
    );
  });

  testWidgets('nor one that is itself owned, because a chain is refused', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness([
        company('a', 'Ultimate Sdn Bhd', current: true),
        company(
          'b',
          'Middle Sdn Bhd',
          parentId: 'a',
          parentName: 'Ultimate Sdn Bhd',
          percent: 100,
        ),
        company('c', 'Bottom Sdn Bhd'),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ownership-c')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ownership-parent')));
    await tester.pumpAndSettle();

    expect(menuItem('Ultimate Sdn Bhd'), findsOneWidget);
    expect(
      menuItem('Middle Sdn Bhd'),
      findsNothing,
      reason:
          '0148 refuses A owns B owns C rather than consolidating two '
          'levels right and three wrong, so it is not on the menu',
    );
  });

  testWidgets('the percentage is asked for only once there is a parent to '
      'hold it', (tester) async {
    await tester.pumpWidget(harness(unrecorded));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ownership-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ownership-percent')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ownership-parent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kabeer Holdings Sdn Bhd').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ownership-percent')), findsOneWidget);
    // Defaulted, because wholly owned is the ordinary case and the one
    // the report can actually consolidate.
    expect(find.widgetWithText(TextField, '100'), findsOneWidget);
    expect(find.textContaining('under 100%'), findsOneWidget);
  });

  testWidgets('a parent this person cannot see is kept rather than silently '
      'cleared', (tester) async {
    // A group can have more than one administrator. If somebody else
    // recorded a parent in a company this person does not belong to, it
    // is not on the menu — and a chooser that fell back to "Nobody"
    // would turn opening the dialog and pressing Save into wiping it.
    await tester.pumpWidget(
      harness([
        company('a', 'Holdings', current: true),
        company(
          'b',
          'Trading',
          parentId: 'zz',
          parentName: 'Offshore Nominees Ltd',
          percent: 100,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ownership-b')));
    await tester.pumpAndSettle();

    // With the menu shut, the only place that exact string can come from
    // is the chooser's own selected value — the card's row reads
    // 'Owned 100% by Offshore Nominees Ltd' and does not match it.
    expect(find.text('Offshore Nominees Ltd'), findsOneWidget);
    expect(find.byKey(const ValueKey('ownership-percent')), findsOneWidget);
  });

  test(
    'a whole percentage loses its trailing zeros and a part one does not',
    () {
      expect(formatOwnedPercent(100), '100');
      expect(formatOwnedPercent(60.5), '60.5');
      expect(formatOwnedPercent(0.5), '0.5');
    },
  );
}
