import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/searchable_picker.dart';

/// A box you type into instead of a list you scroll.
///
/// The matching is asserted on the pure function, because what is worth
/// getting wrong is not the overlay: it is WHICH rows come back for what
/// somebody typed. A filter that quietly matched only the label would
/// look right in a screenshot and fail the storeman who types a code.
void main() {
  final contacts = <PickerOption<String>>[
    const PickerOption(
      value: 'c1',
      label: 'Ramli Enterprise Sdn Bhd',
      sublabel: 'C-0001',
      keywords: ['C-0001'],
    ),
    const PickerOption(
      value: 'c2',
      label: 'Bayu Digital Sdn Bhd',
      sublabel: 'C-0002',
      keywords: ['C-0002'],
    ),
    const PickerOption(
      value: 'c3',
      label: 'Kilang Lestari Sdn Bhd',
      sublabel: 'C-0003',
      keywords: ['C-0003'],
    ),
  ];

  List<String> idsFor(String query) =>
      matchingOptions(contacts, query).map((o) => o.value).toList();

  group('what comes back', () {
    test('an empty box shows everything', () {
      // A picker that shows nothing until you type is a dropdown you
      // cannot browse, which is worse than the dropdown it replaced.
      expect(idsFor(''), ['c1', 'c2', 'c3']);
      expect(idsFor('   '), ['c1', 'c2', 'c3']);
    });

    test('a name finds its row', () {
      expect(idsFor('bayu'), ['c2']);
    });

    test('and case does not matter', () {
      expect(idsFor('BAYU'), ['c2']);
      expect(idsFor('BaYu'), ['c2']);
    });

    test('a code finds it too, without anybody choosing which to type', () {
      expect(idsFor('C-0003'), ['c3']);
    });

    test('every word has to match, in any order', () {
      // People type the words they remember, not the string as filed.
      expect(idsFor('sdn ramli'), ['c1']);
      expect(idsFor('ramli sdn'), ['c1']);
      // And a word that matches nothing rules the row out, rather than
      // being ignored because the other word matched.
      expect(idsFor('ramli lestari'), isEmpty);
    });

    test('a word every row shares narrows to nothing in particular', () {
      expect(idsFor('sdn'), hasLength(3));
    });

    test('nothing matching comes back empty rather than unfiltered', () {
      // The failure that hides a broken filter: returning everything
      // when the query matches nothing looks like a working picker.
      expect(idsFor('zzzz'), isEmpty);
    });
  });

  group('the order rows come back in', () {
    final accounts = <PickerOption<String>>[
      const PickerOption(value: 'a1', label: 'Retained earnings',
          keywords: ['3200', 'contra 1000']),
      const PickerOption(value: 'a2', label: '1000 Cash at bank',
          keywords: ['1000']),
    ];

    test('a label that STARTS with what was typed comes first', () {
      // Typing "1000" must not put "Retained earnings (contra 1000)"
      // above account 1000 itself.
      expect(
        matchingOptions(accounts, '1000').map((o) => o.value),
        ['a2', 'a1'],
      );
    });

    test('and otherwise the list keeps the order it was given', () {
      // Which is the order the caller sorted it into — by code, by name,
      // by whatever the screen needs. A picker that re-sorted would undo
      // that silently.
      expect(idsFor('sdn'), ['c1', 'c2', 'c3']);
    });
  });

  group('the box itself', () {
    Future<void> pump(
      WidgetTester tester, {
      String? value,
      ValueChanged<String?>? onChanged,
      Future<String?> Function(String)? onCreate,
      bool allowEmpty = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchablePicker<String>(
              options: contacts,
              value: value,
              onChanged: onChanged ?? (_) {},
              onCreate: onCreate,
              allowEmpty: allowEmpty,
              label: 'Customer',
              createLabel: 'Add customer',
            ),
          ),
        ),
      );
    }

    testWidgets('shows the chosen row rather than an id', (tester) async {
      await pump(tester, value: 'c2');
      expect(find.text('Bayu Digital Sdn Bhd'), findsOneWidget);
    });

    testWidgets('opens the whole list on a tap, with nothing typed',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();

      expect(find.text('Ramli Enterprise Sdn Bhd'), findsOneWidget);
      expect(find.text('Bayu Digital Sdn Bhd'), findsOneWidget);
      expect(find.text('Kilang Lestari Sdn Bhd'), findsOneWidget);
    });

    testWidgets('typing narrows it', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'kilang');
      await tester.pumpAndSettle();

      expect(find.text('Kilang Lestari Sdn Bhd'), findsOneWidget);
      expect(find.text('Bayu Digital Sdn Bhd'), findsNothing);
    });

    testWidgets('choosing a row reports it and fills the box',
        (tester) async {
      String? chosen;
      await pump(tester, onChanged: (v) => chosen = v);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kilang Lestari Sdn Bhd'));
      await tester.pumpAndSettle();

      expect(chosen, 'c3');
    });

    testWidgets('a row is chosen even though the tap blurs the box',
        (tester) async {
      // Reported from the Record expense screen: the list opens, and
      // tapping a row does nothing.
      //
      // A tap anywhere that is not the text field BLURS it, and the
      // focus listener closed the overlay — so between the finger going
      // down and coming up, the row it was on stopped existing. A plain
      // `tester.tap` never showed it, because the whole gesture lands
      // in one frame with no blur in the middle. This one blurs where
      // the browser blurs.
      String? chosen;
      await pump(tester, onChanged: (v) => chosen = v);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();

      final row = find.text('Kilang Lestari Sdn Bhd');
      expect(row, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(row));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(chosen, 'c3');
    });

    testWidgets('and inside a dialog, which is where it is really used',
        (tester) async {
      // Reported from Record expense, which is an AlertDialog. The bare
      // Scaffold above is not the shape the product uses it in: the
      // overlay goes into the Navigator's overlay, and the dialog is
      // there too.
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    content: SizedBox(
                      width: 400,
                      child: SearchablePicker<String>(
                        options: contacts,
                        value: null,
                        onChanged: (v) => chosen = v,
                        label: 'Customer',
                      ),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.text('Kilang Lestari Sdn Bhd'), findsOneWidget);

      await tester.tap(find.text('Kilang Lestari Sdn Bhd'));
      await tester.pumpAndSettle();
      expect(chosen, 'c3');
    });

    testWidgets('the offer to add appears only once something is typed',
        (tester) async {
      await pump(tester, onCreate: (_) async => null);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add customer'), findsNothing);

      await tester.enterText(find.byType(TextFormField), 'Syarikat Baru');
      await tester.pumpAndSettle();
      expect(find.text('Add customer "Syarikat Baru"'), findsOneWidget);
    });

    testWidgets('and never where the list is not the caller\'s to extend',
        (tester) async {
      // No onCreate: a currency or a state code is not something
      // somebody adds from a picker, and offering would be a dead end.
      await pump(tester);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Syarikat Baru');
      await tester.pumpAndSettle();

      expect(find.textContaining('Add customer'), findsNothing);
      expect(find.text('Nothing matches that.'), findsOneWidget);
    });

    testWidgets('adding one selects it', (tester) async {
      String? chosen;
      await pump(
        tester,
        onChanged: (v) => chosen = v,
        onCreate: (typed) async => 'c2',
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Bayu');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add customer "Bayu"'));
      await tester.pumpAndSettle();

      expect(chosen, 'c2');
    });

    testWidgets('backing out of adding leaves the choice alone',
        (tester) async {
      var calls = 0;
      await pump(
        tester,
        value: 'c1',
        onChanged: (_) => calls++,
        onCreate: (_) async => null,
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Baru');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add customer "Baru"'));
      await tester.pumpAndSettle();

      expect(calls, 0);
      expect(find.text('Ramli Enterprise Sdn Bhd'), findsOneWidget);
    });

    testWidgets('a chosen row shows up when its list arrives late',
        (tester) async {
      // The screen knows the id before the list it belongs to has
      // loaded — a reconciliation opened on a bank account, a document
      // opened on its customer. The box was showing nothing, and went
      // on showing nothing after the list arrived.
      Widget build(List<PickerOption<String>> options) => MaterialApp(
            home: Scaffold(
              body: SearchablePicker<String>(
                options: options,
                value: 'c2',
                onChanged: (_) {},
                label: 'Customer',
              ),
            ),
          );

      await tester.pumpWidget(build(const []));
      expect(find.text('Bayu Digital Sdn Bhd'), findsNothing);

      await tester.pumpWidget(build(contacts));
      await tester.pump();
      expect(find.text('Bayu Digital Sdn Bhd'), findsOneWidget);
    });

    testWidgets('a tap genuinely outside closes it and keeps the choice',
        (tester) async {
      // The other half of the fix: the overlay is no longer closed on
      // blur, so something else has to close it. A tap outside both the
      // field and the overlay is what "outside" means.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                SearchablePicker<String>(
                  options: contacts,
                  value: 'c1',
                  onChanged: (_) {},
                  label: 'Customer',
                ),
                const SizedBox(height: 400, child: Text('elsewhere')),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.text('Bayu Digital Sdn Bhd'), findsOneWidget);

      await tester.tapAt(tester.getCenter(find.text('elsewhere')));
      await tester.pumpAndSettle();

      expect(find.text('Bayu Digital Sdn Bhd'), findsNothing);
      // And what was chosen before is still in the box, not half a
      // name nobody selected.
      expect(find.text('Ramli Enterprise Sdn Bhd'), findsOneWidget);
    });

    testWidgets('Escape closes it', (tester) async {
      await pump(tester, value: 'c1');
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.text('Bayu Digital Sdn Bhd'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Bayu Digital Sdn Bhd'), findsNothing);
    });

    testWidgets('"none" is offered only where it is an answer',
        (tester) async {
      await pump(tester, allowEmpty: true);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.text('None'), findsOneWidget);
    });

    testWidgets('and not where it is not', (tester) async {
      await pump(tester);
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      expect(find.text('None'), findsNothing);
    });
  });

  /// A cell in a row of a table rather than a field on a form.
  ///
  /// The tax code and the unit on a line of an invoice get about a
  /// fifth of the row each and no vertical room for a floating label.
  /// Dense form is the same control at the height a table row can
  /// afford — which is the thing worth asserting, because a picker
  /// that quietly grew a row would have been rejected as a regression
  /// on the busiest screen in the product.
  group('dense, for a cell in a row', () {
    late ThemeData theme;

    Future<void> pumpDense(WidgetTester tester, {required bool dense}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                theme = Theme.of(context);
                return Center(
                  child: SizedBox(
                    width: 200,
                    child: SearchablePicker<String>(
                      options: contacts,
                      value: null,
                      onChanged: (_) {},
                      label: 'Tax',
                      dense: dense,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    TextField fieldOf(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField));

    testWidgets('asks for the compact box and the small type',
        (tester) async {
      await pumpDense(tester, dense: true);
      final field = fieldOf(tester);
      // Both, and separately: `isDense` alone still leaves the row
      // carrying body text a table row has no height for.
      expect(field.decoration!.isDense, isTrue);
      expect(field.style, theme.textTheme.bodySmall);
    });

    testWidgets('and a form field asks for neither', (tester) async {
      await pumpDense(tester, dense: false);
      final field = fieldOf(tester);
      expect(field.decoration!.isDense, isFalse);
      expect(field.style, isNull);
      expect(field.decoration!.labelText, 'Tax');
    });

    testWidgets('says what it is for in the box, since there is no label',
        (tester) async {
      await pumpDense(tester, dense: true);
      // The floating label has nowhere to float to, so the label
      // becomes the hint. Without this the cell is a blank box.
      expect(fieldOf(tester).decoration!.labelText, isNull);
      expect(find.text('Tax'), findsOneWidget);
    });

    testWidgets('and still opens, narrows and chooses', (tester) async {
      String? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: SearchablePicker<String>(
                  options: contacts,
                  value: null,
                  onChanged: (v) => chosen = v,
                  label: 'Tax',
                  dense: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextFormField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'kilang');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kilang Lestari Sdn Bhd'));
      await tester.pumpAndSettle();

      expect(chosen, 'c3');
    });
  });
}
