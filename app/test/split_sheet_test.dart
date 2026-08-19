import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/split_sheet.dart';

/// Splitting a bill.
///
/// That the shares sum to the whole is asserted in
/// `supabase/tests/pos_fnb.sql`, against `pos_even_split`. What is
/// asserted here is the distinction 0216 exists to protect: splitting
/// by item moves lines and makes a second bill, splitting evenly moves
/// nothing. A screen that blurred the two is how a till issues four
/// invoices for one meal.
void main() {
  Map<String, dynamic> line(String id, String name, num qty, num price) => {
    'id': id,
    'line_no': 1,
    'description': name,
    'quantity': '$qty',
    'unit_price': '$price',
    'line_total': '${qty * price}',
  };

  Future<List<String>?> showSplit(
    WidgetTester tester,
    List<Map<String, dynamic>> lines,
  ) async {
    List<String>? out;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  out = await showModalBottomSheet<List<String>>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => SplitSheet(lines: lines),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return out;
  }

  testWidgets('nothing ticked is nothing to move, and the button says so', (
    tester,
  ) async {
    await showSplit(tester, [
      line('l1', 'Ikan bakar', 1, 22),
      line('l2', 'Teh tarik', 2, 3),
    ]);

    expect(find.text('Tick something to move'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('the button counts what is moving and what it comes to', (
    tester,
  ) async {
    await showSplit(tester, [
      line('l1', 'Ikan bakar', 1, 22),
      line('l2', 'Teh tarik', 2, 3),
    ]);

    await tester.tap(find.text('Ikan bakar'));
    await tester.pumpAndSettle();

    expect(find.text('Move 1 · RM 22.00'), findsOneWidget);
  });

  testWidgets('moving everything is refused, and named as the reason', (
    tester,
  ) async {
    await showSplit(tester, [
      line('l1', 'Ikan bakar', 1, 22),
      line('l2', 'Teh tarik', 2, 3),
    ]);

    await tester.tap(find.text('Ikan bakar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Teh tarik'));
    await tester.pumpAndSettle();

    // Moving the lot is a rename, not a split, and would leave an empty
    // bill behind. Stopped here rather than explained after the fact.
    expect(find.text('That is the whole bill'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('an even split shows the shares and that they add up', (
    tester,
  ) async {
    // Ten ringgit three ways: 3.34 + 3.33 + 3.33. The remainder rides
    // on the first, and the sum is the property that matters.
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: EvenSplitDialog(
            shares: const [
              {'share_no': 1, 'amount': '3.34'},
              {'share_no': 2, 'amount': '3.33'},
              {'share_no': 3, 'amount': '3.33'},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 ways'), findsOneWidget);
    expect(find.text('RM 3.34'), findsOneWidget);
    expect(find.text('RM 3.33'), findsNWidgets(2));
    expect(find.text('They add up to'), findsOneWidget);
    expect(find.text('RM 10.00'), findsOneWidget);
  });
}
