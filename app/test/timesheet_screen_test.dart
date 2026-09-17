import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/features/timesheets/timesheet_screen.dart';

/// Time recorded, and time turned into an invoice.
///
/// Three things live only in this widget.
///
/// AN HOUR ALREADY BILLED CANNOT BE EDITED HERE. It is a line on an
/// invoice somebody has been sent; changing it would move the hours and
/// leave the invoice where it was. The screen expresses that by handing
/// `onTap` a null, which is invisible on screen -- the row looks
/// identical -- so it is asserted on the callback rather than on
/// anything a screenshot would show.
///
/// RECORDED AND CHARGEABLE ARE TWO DIFFERENT TOTALS. Hours that never
/// become an invoice are the whole failure mode of selling time, and a
/// header that folded every entry into both figures would report a
/// practice as fully chargeable while it was writing off half its week.
///
/// AND WHAT AN HOUR IS AGAINST. A project, else a matter, else nobody
/// -- and the last of those is a sentence rather than a blank, because
/// a row with no client is exactly the row somebody should look at.
void main() {
  // The screen asks for the current month, so the test builds the same
  // key rather than a fixed one. `DateTime(y, m + 1, 0)` is the last
  // day of month m, which is how the screen writes it too.
  final now = DateTime.now();
  final period = (
    from: DateTime(now.year, now.month, 1),
    to: DateTime(now.year, now.month + 1, 0),
  );

  Map<String, dynamic> entry({
    String id = 't1',
    String description = 'Drafting the share transfer',
    num minutes = 90,
    num amount = 450,
    bool isBillable = true,
    bool isBilled = false,
    String? projectName,
    String? matterName,
    String? entryDate,
  }) => {
    'id': id,
    'description': description,
    'minutes': minutes,
    'amount': amount,
    'is_billable': isBillable,
    'is_billed': isBilled,
    'entry_date': entryDate ?? '2026-09-14',
    'projects': projectName == null ? null : {'name': projectName},
    'matters': matterName == null ? null : {'name': matterName},
  };

  Widget wrap(
    List<Map<String, dynamic>> entries, {
    String role = 'owner',
  }) => ProviderScope(
    overrides: [
      myTimeEntriesProvider(period).overrideWith((ref) async => entries),
      timesheetReportProvider(period).overrideWith((ref) async => const []),
      billingRatesProvider.overrideWith((ref) async => const []),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const TimesheetScreen(),
    ),
  );

  Future<void> show(
    WidgetTester tester,
    List<Map<String, dynamic>> entries, {
    String role = 'owner',
    double? width,
  }) async {
    if (width != null) {
      // `tester.view.physicalSize`, not `setSurfaceSize`: the latter
      // moves the render surface without moving `MediaQuery`, so the
      // screen would take its DESKTOP branch. See docs/widget-tests.md.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(wrap(entries, role: role));
    await tester.pumpAndSettle();
  }

  /// The tile's tap callback, which is what says whether an entry may be
  /// edited. Null means it may not.
  VoidCallback? tapOf(WidgetTester tester, String description) {
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text(description),
        matching: find.byType(ListTile),
      ),
    );
    return tile.onTap;
  }

  group('an hour that has already been invoiced', () {
    testWidgets('cannot be edited from here', (tester) async {
      await show(tester, [
        entry(id: 'a', description: 'Billed work', isBilled: true),
        entry(id: 'b', description: 'Unbilled work', isBilled: false),
      ]);

      // Invisible on screen: both rows look the same. Changing a billed
      // hour would move the hours and leave the invoice where it was.
      expect(tapOf(tester, 'Billed work'), isNull);
      expect(tapOf(tester, 'Unbilled work'), isNotNull);
    });

    testWidgets('and says so with a chip', (tester) async {
      await show(tester, [entry(description: 'Billed work', isBilled: true)]);

      expect(find.text('Billed'), findsOneWidget);
    });

    testWidgets('an unbilled non-chargeable hour is marked internal',
        (tester) async {
      // Two different facts: "already invoiced" and "never will be".
      await show(tester, [
        entry(description: 'Internal meeting', isBillable: false),
      ]);

      expect(find.text('Internal'), findsOneWidget);
      expect(find.text('Billed'), findsNothing);
      // Still editable: nobody has been sent anything.
      expect(tapOf(tester, 'Internal meeting'), isNotNull);
    });

    testWidgets('and an ordinary chargeable hour carries no chip at all',
        (tester) async {
      // The control for both chips.
      await show(tester, [entry(description: 'Ordinary work')]);

      expect(find.byType(StatusChip), findsNothing);
    });

    testWidgets('a viewer may edit nothing, billed or not', (tester) async {
      await show(tester, [
        entry(id: 'a', description: 'Billed work', isBilled: true),
        entry(id: 'b', description: 'Unbilled work'),
      ], role: 'viewer');

      expect(tapOf(tester, 'Billed work'), isNull);
      expect(tapOf(tester, 'Unbilled work'), isNull);
      // And is not invited to record any.
      expect(find.byKey(const ValueKey('record-time')), findsNothing);
    });

    testWidgets('somebody who may write is', (tester) async {
      await show(tester, [entry()]);

      expect(find.byKey(const ValueKey('record-time')), findsOneWidget);
    });
  });

  group('recorded against chargeable', () {
    testWidgets('are two different totals', (tester) async {
      // 90 + 150 + 60 = 300 minutes recorded, of which 90 + 60 = 150 are
      // chargeable. Folding every entry into both figures reports a
      // practice as fully chargeable while it writes off half its week.
      await show(tester, [
        entry(id: 'a', description: 'A', minutes: 90, isBillable: true),
        entry(id: 'b', description: 'B', minutes: 150, isBillable: false),
        entry(id: 'c', description: 'C', minutes: 60, isBillable: true),
      ]);

      expect(
        find.text('5.00 hours recorded, 2.50 of them chargeable.'),
        findsOneWidget,
      );
    });

    testWidgets('and a part hour keeps its two places', (tester) async {
      // 25 minutes is 0.42 hours. Rounded to whole hours it is nothing,
      // and a practice recording six-minute units would lose every one.
      await show(tester, [entry(minutes: 25)]);

      expect(find.textContaining('0.42 hours recorded'), findsOneWidget);
    });
  });

  group('what an hour is against', () {
    testWidgets('a project, by name', (tester) async {
      await show(tester, [
        entry(projectName: 'Menara Ampang fit-out', minutes: 90),
      ]);

      expect(find.textContaining('· Menara Ampang fit-out · 1.50h'),
          findsOneWidget);
    });

    testWidgets('a matter where there is no project', (tester) async {
      await show(tester, [
        entry(projectName: null, matterName: 'Tan v Rahman'),
      ]);

      expect(find.textContaining('· Tan v Rahman ·'), findsOneWidget);
    });

    testWidgets('the project wins where an entry carries both',
        (tester) async {
      // Both columns are populated on the row; the screen has to pick
      // one, and picking the other silently re-files the hour.
      await show(tester, [
        entry(projectName: 'Menara Ampang fit-out', matterName: 'Tan v Rahman'),
      ]);

      expect(find.textContaining('Menara Ampang fit-out'), findsOneWidget);
      expect(find.textContaining('Tan v Rahman'), findsNothing);
    });

    testWidgets('and an hour against nobody says so', (tester) async {
      // Not a blank. A row with no client is exactly the row somebody
      // should be looking at.
      await show(tester, [entry(projectName: null, matterName: null)]);

      expect(find.textContaining('Not chargeable to anyone'), findsOneWidget);
    });
  });

  group('nothing recorded', () {
    testWidgets('says the rate is not something to know', (tester) async {
      await show(tester, []);

      expect(find.text('No time recorded'), findsOneWidget);
      expect(find.textContaining('The rate comes from your billing rate'),
          findsOneWidget);
    });
  });
  /// The bar above the three tabs, at every width one is opened at.
  ///
  /// It ran 44 pixels off a 412px phone and 96 off a 360: the period
  /// button carries twenty-three characters -- "01/09/2026 —
  /// 30/09/2026" -- beside a title reading "Timesheets" and the job
  /// costing icon. Flutter CLIPS an overflowing toolbar in a release
  /// build rather than reporting it, so what a phone lost was the
  /// right-hand end of the very control that says which week the hours
  /// below belong to.
  ///
  /// These assert nothing but that the screen rendered, because a
  /// `RenderFlex` overflow IS a test failure here.
  group('the bar fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        await show(tester, [entry()], width: width);

        expect(find.byType(TimesheetScreen), findsOneWidget);
      });
    }
  });

  group('the period being looked at', () {
    testWidgets('keeps its full dates on a phone, below the tabs',
        (tester) async {
      // Not abbreviated. The year is what tells somebody which period
      // they are looking at, and it moves rather than shortening.
      await show(tester, [entry()], width: 412);

      final range = find.byKey(const ValueKey('timesheet-range'));
      final tabs = find.byType(TabBar);
      expect(range, findsOneWidget);
      expect(tester.getCenter(range).dy, lessThan(tester.getCenter(tabs).dy));

      final label = tester
          .widget<Text>(find.descendant(of: range, matching: find.byType(Text)))
          .data!;
      expect(RegExp(r'\d{2}/\d{2}/\d{4}').allMatches(label), hasLength(2));
    });

    testWidgets('and sits on the toolbar on a laptop', (tester) async {
      // The control for where it lives. Without it, "the range is above
      // the tabs" passes against a screen that always puts it there.
      await show(tester, [entry()], width: 1400);

      final range = find.byKey(const ValueKey('timesheet-range'));
      expect(tester.getCenter(range).dy, lessThan(56));
    });
  });

}
