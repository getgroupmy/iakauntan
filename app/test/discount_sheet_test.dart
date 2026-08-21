import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/discount_sheet.dart';

/// Taking money off.
///
/// What a discount does to the money is asserted in
/// `supabase/tests/pos.sql`, against `discount_pos_sale_line` and
/// `discount_pos_sale`. What is asserted here is the thing only a
/// screen can get wrong: a cashier at a counter with a queue behind
/// them typing "10", and not being told which ten it is.
///
/// The two halves of that are a preview that answers in money whichever
/// side of the toggle the number is on, and a refusal that arrives on
/// the device rather than as a round trip.
void main() {
  ({DiscountAnswer? answer, bool clear})? result;
  var opened = 0;

  Widget host({
    required double full,
    String subject = 'Nasi lemak ayam',
    double? percent,
    double? amount,
    String? reason,
  }) {
    result = null;
    opened = 0;
    return MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                opened++;
                result = await showDiscountSheet(
                  context,
                  subject: subject,
                  full: full,
                  currentPercent: percent,
                  currentAmount: amount,
                  currentReason: reason,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester, Widget w) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(w);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  }

  testWidgets('a rate is previewed in money, because money is the question', (
    tester,
  ) async {
    await open(tester, host(full: 20));

    await tester.enterText(find.byType(TextField).first, '10');
    await tester.pumpAndSettle();

    // Ten per cent of twenty ringgit, said as two ringgit. Without this
    // the cashier is agreeing to a number they have not seen.
    expect(
      find.text('Takes off RM 2.00, leaving RM 18.00'),
      findsOneWidget,
    );
  });

  testWidgets('the same number means something else in ringgit', (
    tester,
  ) async {
    await open(tester, host(full: 20));

    await tester.enterText(find.byType(TextField).first, '10');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ringgit'));
    await tester.pumpAndSettle();

    expect(
      find.text('Takes off RM 10.00, leaving RM 10.00'),
      findsOneWidget,
    );
  });

  testWidgets('a discount larger than the line is refused here, not later', (
    tester,
  ) async {
    await open(tester, host(full: 20));

    await tester.tap(find.text('Ringgit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '25');
    await tester.enterText(find.byType(TextField).last, 'burnt');
    await tester.tap(find.text('Take it off'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('more than RM 20.00'),
      findsOneWidget,
    );
    // Still open, and nothing returned: the server would have refused
    // this too, and finding out after the sheet closed is worse.
    expect(result, isNull);
  });

  testWidgets('nothing comes off without a reason', (tester) async {
    await open(tester, host(full: 20));

    await tester.enterText(find.byType(TextField).first, '10');
    await tester.tap(find.text('Take it off'));
    await tester.pumpAndSettle();

    expect(find.text('Say why the price is coming down'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('a rate and a reason come back as a rate', (tester) async {
    await open(tester, host(full: 20));

    await tester.enterText(find.byType(TextField).first, '10');
    await tester.enterText(find.byType(TextField).last, 'Staff meal');
    await tester.tap(find.text('Take it off'));
    await tester.pumpAndSettle();

    // A rate, not the two ringgit it currently comes to. The server
    // re-applies the rate when another plate arrives; sending the
    // amount would freeze the promise at today's basket.
    expect(result?.answer?.percent, 10);
    expect(result?.answer?.amount, isNull);
    expect(result?.answer?.reason, 'Staff meal');
    expect(result?.clear, isFalse);
  });

  testWidgets('putting the price back is offered only where there is one', (
    tester,
  ) async {
    await open(tester, host(full: 20));
    expect(find.text('Put the price back'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(opened, 2);
  });

  testWidgets('a line that already has one offers to undo it', (tester) async {
    await open(
      tester,
      host(full: 20, percent: 10, reason: 'Staff meal'),
    );

    expect(find.text('Put the price back'), findsOneWidget);
    await tester.tap(find.text('Put the price back'));
    await tester.pumpAndSettle();

    // Clearing carries no reason, because nothing is being given away.
    expect(result?.clear, isTrue);
    expect(result?.answer, isNull);
  });
}
