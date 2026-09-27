import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/widgets.dart';

/// `SectionHeader` must not eat its own action on a phone.
///
/// The header is `Row(Expanded(title + subtitle), action)`. `Expanded`
/// takes what is left after the action, so the action always gets its
/// natural width and the title wraps -- which is right, and is why the
/// Fiscal years card's subtitle sits on two lines on a handset.
///
/// The failure this guards is the one after that. Where the action is
/// itself a Row of more than one control, its natural width can exceed
/// the whole card. `Expanded` is then handed a negative amount, clamps
/// to zero, and the action overflows the right edge. **In a release
/// build there is no yellow overflow stripe** -- `RenderFlex` paints
/// the stripe only in debug -- so the second control is simply not on
/// the screen, and the screen looks like a build that predates it.
///
/// That is an expensive thing to misread: the first guess is always a
/// stale build or a missing deploy, and both take a release cycle to
/// rule out. Asserted here at 360 logical pixels, narrower than any
/// handset this runs on, because the header is used by dozens of cards
/// and the next two-control action will be written by somebody who
/// never saw this file.
void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    // 360x800 is a small Android handset in logical pixels, and
    // narrower than the iPhone the report came from.
    view.physicalSize = const Size(360, 800);
    view.devicePixelRatio = 1.0;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .views
        .first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  /// The card around the header, at the padding the settings screen
  /// uses, so the width under test is the width a card really gives.
  Future<void> pumpHeader(WidgetTester tester, {Widget? action}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SectionHeader(
                    'Fiscal years',
                    subtitle:
                        'Nothing can be posted to a date no period covers',
                    action: action,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The Fiscal years card's action, copied in shape from
  /// `settings_screen.dart`: the plain forward button plus the menu
  /// that carries "Add previous year".
  Widget fiscalAction() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add next year'),
      ),
      PopupMenuButton<String>(
        key: const ValueKey('fiscal-year-more'),
        tooltip: 'More',
        onSelected: (_) {},
        itemBuilder: (_) =>
            const [PopupMenuItem(value: 'previous', child: Text('Add previous year'))],
      ),
    ],
  );

  testWidgets('the fiscal years menu is on the screen at phone width', (
    tester,
  ) async {
    await pumpHeader(tester, action: fiscalAction());

    final menu = find.byKey(const ValueKey('fiscal-year-more'));
    expect(menu, findsOneWidget);

    // Present in the tree is not the assertion. The assertion is that
    // it is inside the screen: an overflowing Row still builds its
    // children and still finds them, and they are painted off the
    // right edge where nobody can press them.
    final box = tester.getRect(menu);
    expect(
      box.right,
      lessThanOrEqualTo(tester.view.physicalSize.width),
      reason: 'the More menu is painted past the right edge of a '
          '360px screen, so "Add previous year" cannot be reached',
    );
    expect(box.width, greaterThan(0));
  });

  testWidgets('and the header reports no overflow', (tester) async {
    await pumpHeader(tester, action: fiscalAction());
    // A RenderFlex overflow is dumped to the exception handler rather
    // than thrown, so a test that only looked at widgets would pass
    // through one without noticing.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the forward button alone is unaffected', (tester) async {
    // The control. Before the menu was added this is what the card
    // had, and if THIS overflowed at 360px the test above would be
    // measuring the wrong thing.
    await pumpHeader(
      tester,
      action: TextButton.icon(
        onPressed: () {},
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add next year'),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Add next year'), findsOneWidget);
  });
}
