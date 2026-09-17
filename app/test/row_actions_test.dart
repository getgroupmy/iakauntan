import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/row_actions.dart';

/// A row's actions: buttons on a wide screen, one menu on a phone.
///
/// `ListTile` hands its `trailing` the width it asks for and gives the
/// title and subtitle whatever is left. Nothing warns when that is
/// nothing — the text is not overflowing, it has been GIVEN a box two
/// pixels wide, and it wraps one letter per line. That shipped on the
/// items list. This is the shape that stops it, and
/// `scripts/check_narrow_rows.py` fails a build that grows a wide
/// trailing without it.
void main() {
  Future<void> pump(
    WidgetTester tester,
    double width, {
    required List<RowAction> actions,
    Widget? leading,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            ListTile(
              title: const Text('Ramli Enterprise Sdn Bhd'),
              subtitle: const Text('C-0001 · Kuala Lumpur · on hold'),
              trailing: RowActions(
                menuKey: 'row-menu',
                leading: leading,
                actions: actions,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  List<RowAction> three(List<String> pressed) => [
    RowAction(
      actionKey: 'one',
      label: 'Interviews',
      onTap: () => pressed.add('one'),
    ),
    RowAction(
      actionKey: 'two',
      label: 'Move to Shortlisted',
      emphasis: RowActionEmphasis.outlined,
      onTap: () => pressed.add('two'),
    ),
    RowAction(
      actionKey: 'three',
      label: 'It came to nothing',
      icon: Icons.do_not_disturb_on_outlined,
      iconOnly: true,
      onTap: () => pressed.add('three'),
    ),
  ];

  group('on a phone', () {
    testWidgets('the actions are behind one menu', (tester) async {
      await pump(tester, 360, actions: three([]));
      expect(find.text('Interviews'), findsNothing);
      expect(find.text('Move to Shortlisted'), findsNothing);
      expect(find.byKey(const ValueKey('row-menu')), findsOneWidget);
    });

    testWidgets('and the title keeps room for its own words',
        (tester) async {
      await pump(tester, 360, actions: three([]));
      final subtitle =
          tester.getSize(find.text('C-0001 · Kuala Lumpur · on hold'));
      // The failure this exists to stop rendered it about one character
      // wide and hundreds tall.
      expect(subtitle.width, greaterThan(subtitle.height));
      expect(subtitle.width, greaterThan(150));
    });

    testWidgets('opening the menu shows all of them, with their words',
        (tester) async {
      // Including the icon-only one: a menu of unlabelled icons is a
      // menu nobody can read.
      await pump(tester, 360, actions: three([]));
      await tester.tap(find.byKey(const ValueKey('row-menu')));
      await tester.pumpAndSettle();

      expect(find.text('Interviews'), findsOneWidget);
      expect(find.text('Move to Shortlisted'), findsOneWidget);
      expect(find.text('It came to nothing'), findsOneWidget);
    });

    testWidgets('and choosing one runs it', (tester) async {
      final pressed = <String>[];
      await pump(tester, 360, actions: three(pressed));
      await tester.tap(find.byKey(const ValueKey('row-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move to Shortlisted'));
      await tester.pumpAndSettle();

      expect(pressed, ['two']);
    });

    testWidgets('the leading stays put — it is not an action',
        (tester) async {
      // A price belongs at the end of the row at every width. Hiding it
      // in a menu would be hiding the number the row is about.
      await pump(tester, 360,
          actions: three([]), leading: const Text('RM 1,450.00'));
      expect(find.text('RM 1,450.00'), findsOneWidget);
    });
  });

  group('on a wide screen', () {
    testWidgets('they stay as buttons', (tester) async {
      await pump(tester, 1400, actions: three([]));
      expect(find.byKey(const ValueKey('row-menu')), findsNothing);
      expect(find.text('Interviews'), findsOneWidget);
      expect(find.text('Move to Shortlisted'), findsOneWidget);
    });

    testWidgets('an icon-only action is an icon, with its words as the '
        'tooltip', (tester) async {
      await pump(tester, 1400, actions: three([]));
      expect(find.text('It came to nothing'), findsNothing);
      expect(
        find.byIcon(Icons.do_not_disturb_on_outlined),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('three')))
            .tooltip,
        'It came to nothing',
      );
    });

    testWidgets('emphasis picks the button', (tester) async {
      await pump(tester, 1400, actions: three([]));
      expect(find.byKey(const ValueKey('one')), findsOneWidget);
      expect(
        tester.widget(find.byKey(const ValueKey('two'))),
        isA<OutlinedButton>(),
      );
    });

    testWidgets('and pressing one runs it', (tester) async {
      final pressed = <String>[];
      await pump(tester, 1400, actions: three(pressed));
      await tester.tap(find.text('Interviews'));
      await tester.pumpAndSettle();
      expect(pressed, ['one']);
    });
  });

  testWidgets('a row with nothing to offer shows no menu', (tester) async {
    // An empty menu button is a button that does nothing, which is
    // worse than no button.
    await pump(tester, 360, actions: const []);
    expect(find.byKey(const ValueKey('row-menu')), findsNothing);
  });
}
