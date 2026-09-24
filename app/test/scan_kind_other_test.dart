import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/smartscan/scan_destination.dart';
import 'package:iakauntan/src/features/smartscan/scan_kind_sheet.dart';

/// Looking at the page, and saying what it is when the list cannot.
///
///     When something is sent it don't get any data or recognise any
///     data it should prompt back a popup where use can view and review
///     the document or image and inform what kind of document it is /
///     if it's not in list there should be a other option where
///     freestyle text to key in document type name
///
/// The sheet offered eight destinations and nothing else. Somebody
/// holding a payment voucher, a petty cash slip or a cash bill closed
/// it, and what the platform learned was nothing — about the most
/// valuable document in the module, since a reading that came back
/// empty is a document this product cannot yet handle, in the hands of
/// somebody who knows exactly what it is.
void main() {
  /// Opens the sheet and hands back the list the handler appends to.
  ///
  /// Not a helper that RETURNS the answer: that returns before anybody
  /// has pressed anything. `docs/widget-tests.md` lists this one.
  Future<List<ScanKindAnswer?>> open(
    WidgetTester tester, {
    bool canView = true,
  }) async {
    final answers = <ScanKindAnswer?>[];
    var viewed = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => answers.add(await showScanKindSheet(
                context,
                onView: canView ? () async => viewed++ : null,
                because: 'Nothing could be read from it.',
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return answers;
  }

  group('the sheet a document nobody could read comes back to', () {
    testWidgets('offers a look at the page', (tester) async {
      // The question cannot be answered from memory, and the case it is
      // asked in is the one where the reader could not answer it
      // either.
      await open(tester);
      expect(find.byKey(const ValueKey('scan-kind-view')), findsOneWidget);
      expect(find.text('View the document'), findsOneWidget);
    });

    testWidgets('and draws no such button where there is nothing to open',
        (tester) async {
      // A file somebody removed. A button that opens nothing is worse
      // than no button.
      await open(tester, canView: false);
      expect(find.byKey(const ValueKey('scan-kind-view')), findsNothing);
    });

    testWidgets('still offers every destination', (tester) async {
      await open(tester);
      for (final d in offerableDestinations) {
        expect(find.byKey(ValueKey('scan-kind-${d.name}')), findsOneWidget,
            reason: d.name);
      }
    });

    testWidgets('a destination comes back as a destination', (tester) async {
      final answers = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-expense')));
      await tester.pumpAndSettle();
      expect(answers.single?.to, ScanDestination.expense);
      expect(answers.single?.named, isNull);
    });
  });

  group('nothing on the list fits', () {
    testWidgets('the box is not open until somebody says so',
        (tester) async {
      // A text box sitting under eight tiles reads as the ninth option
      // and gets typed into by people who had a tile to press.
      await open(tester);
      expect(
          find.byKey(const ValueKey('scan-kind-other-name')), findsNothing);
      expect(find.byKey(const ValueKey('scan-kind-other')), findsOneWidget);
    });

    testWidgets('and opens when they do', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      expect(
          find.byKey(const ValueKey('scan-kind-other-name')), findsOneWidget);
      // And the tile is gone, so there is one thing to do rather than
      // two that look alike.
      expect(find.byKey(const ValueKey('scan-kind-other')), findsNothing);
    });

    testWidgets('an empty box sends nothing', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      final send = tester.widget<FilledButton>(
        find.byKey(const ValueKey('scan-kind-other-send')),
      );
      expect(send.onPressed, isNull);
    });

    testWidgets('what somebody types comes back as a name', (tester) async {
      final answers = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('scan-kind-other-name')),
        'Payment voucher',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scan-kind-other-send')));
      await tester.pumpAndSettle();

      expect(answers.single?.named, 'Payment voucher');
      // And no destination: nothing is created from a kind this product
      // has never heard of.
      expect(answers.single?.to, isNull);
    });

    testWidgets('spaces around it are not a name', (tester) async {
      final answers = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('scan-kind-other-name')),
        '   ',
      );
      await tester.pumpAndSettle();
      final send = tester.widget<FilledButton>(
        find.byKey(const ValueKey('scan-kind-other-send')),
      );
      expect(send.onPressed, isNull);
      expect(answers, isEmpty);
    });

    testWidgets('it is trimmed on the way out', (tester) async {
      final answers = await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('scan-kind-other-name')),
        '  Baucar Bayaran  ',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('scan-kind-other-send')));
      await tester.pumpAndSettle();
      expect(answers.single?.named, 'Baucar Bayaran');
    });

    testWidgets('it says nothing is created from it', (tester) async {
      // Otherwise somebody types a name and waits for a bill.
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('scan-kind-other')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing is created from it'),
          findsOneWidget);
    });
  });
}
