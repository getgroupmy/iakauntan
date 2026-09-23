import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';

/// Things that fit a laptop and run off a phone.
///
/// Both of these shipped: the e-Invoice filter lost "Needs fixing" off
/// the right edge with "Submitted" wrapping mid-word beside it, and the
/// invoice app bar pushed "Submit e-Invoice" half off the screen. Flutter
/// reports neither as an error in release — the pixels are just gone —
/// so the only way to catch them is to lay them out at a phone's width
/// and look.
void main() {
  /// A common Android phone, in logical pixels.
  const phone = Size(412, 830);

  Future<void> pump(WidgetTester tester, Widget child, {Size size = phone}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: child),
    ));
    await tester.pumpAndSettle();
  }

  /// The five e-Invoice filters, which are the widest set in the app.
  Widget filters() => FilterBar(
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'all', label: Text('All')),
            ButtonSegment(value: 'queued', label: Text('Queued')),
            ButtonSegment(value: 'submitted', label: Text('Submitted')),
            ButtonSegment(value: 'valid', label: Text('Valid')),
            ButtonSegment(value: 'attention', label: Text('Needs fixing')),
          ],
          selected: const {'all'},
          onSelectionChanged: (_) {},
        ),
      );

  group('filter bar', () {
    testWidgets('does not overflow on a phone', (tester) async {
      await pump(tester, Align(alignment: Alignment.topLeft, child: filters()));
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow here is the whole bug');
    });

    testWidgets('the last option can be scrolled to', (tester) async {
      await pump(tester, Align(alignment: Alignment.topLeft, child: filters()));

      final last = find.text('Needs fixing');
      expect(last, findsOneWidget, reason: 'built, even if off screen');

      await tester.scrollUntilVisible(last, 80,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      // On screen, whole, not clipped at the edge.
      final box = tester.getRect(last);
      expect(box.right, lessThanOrEqualTo(412),
          reason: 'the label must sit inside the viewport, not past it');
      expect(tester.takeException(), isNull);
    });

    testWidgets('labels are not shortened for small screens', (tester) async {
      // The words are what the rest of the app calls these states; an
      // abbreviation that only exists on a phone is a second vocabulary.
      await pump(tester, Align(alignment: Alignment.topLeft, child: filters()));
      expect(find.text('Needs fixing'), findsOneWidget);
      expect(find.text('Submitted'), findsOneWidget);
    });

    testWidgets('a wide screen still shows every option at once',
        (tester) async {
      await pump(tester, Align(alignment: Alignment.topLeft, child: filters()),
          size: const Size(1400, 900));
      for (final label in ['All', 'Queued', 'Submitted', 'Valid', 'Needs fixing']) {
        expect(tester.getRect(find.text(label)).right, lessThan(1400));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('the expenses app bar', () {
    // The third one of these to ship. Two labelled buttons beside a
    // title overflowed by 104 pixels at 412 wide — found by
    // CONSTRUCTING the screen for the first time, which nothing had
    // ever done. Flutter calls it an error in debug and silently
    // clips it in release, so the pixels were simply gone on a phone.
    Widget bar({required bool narrow}) => Scaffold(
          appBar: AppBar(
            title: const Text('Expenses'),
            actions: [
              if (!narrow)
                TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.document_scanner_outlined,
                        size: 18),
                    label: const Text('Export')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(narrow ? 'Record' : 'Record expense')),
              ),
              if (narrow)
                PopupMenuButton<int>(
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 0, child: Text('Export')),
                  ],
                ),
            ],
          ),
          body: const SizedBox(),
        );

    testWidgets('fits a phone once it collapses', (tester) async {
      await pump(tester, bar(narrow: true));
      expect(tester.takeException(), isNull);
      for (final f in [
        find.text('Record'),
        find.byIcon(Icons.more_vert),
      ]) {
        expect(tester.getRect(f).right, lessThanOrEqualTo(412), reason: '$f');
      }
    });

    testWidgets('and would not have before', (tester) async {
      // Proof the collapse does something. This is the arrangement
      // that shipped.
      await pump(tester, bar(narrow: false));
      final error = tester.takeException();
      expect(error, isFlutterError);
      expect('$error', contains('overflowed'));
    });
  });

  group('an app bar with more actions than fit', () {
    // The shape the invoice editor produces once a document is posted.
    Widget bar({required bool narrow}) => Scaffold(
          appBar: AppBar(
            title: const Text('INV-2026-00001'),
            actions: [
              if (!narrow) const Chip(label: Text('Partial')),
              IconButton(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  onPressed: () {}),
              if (!narrow)
                TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.payments_outlined, size: 18),
                    label: const Text('Receive payment')),
              FilledButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                  label: Text(narrow ? 'Submit' : 'Submit e-Invoice')),
              if (narrow)
                PopupMenuButton<int>(
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 0, child: Text('Receive payment')),
                  ],
                ),
            ],
          ),
          body: const SizedBox(),
        );

    testWidgets('the collapsed bar fits a phone', (tester) async {
      await pump(tester, bar(narrow: true));
      expect(tester.takeException(), isNull);

      // Every action sits inside the screen rather than past its edge.
      for (final f in [
        find.byIcon(Icons.picture_as_pdf_outlined),
        find.text('Submit'),
        find.byIcon(Icons.more_vert),
      ]) {
        expect(tester.getRect(f).right, lessThanOrEqualTo(412), reason: '$f');
      }
    });

    testWidgets('the uncollapsed bar would not have', (tester) async {
      // Proof the collapse is doing something rather than being
      // decoration: the wide arrangement, laid out on a phone, overflows
      // — and this is the exact failure the screenshots showed.
      await pump(tester, bar(narrow: false));

      final error = tester.takeException();
      expect(error, isFlutterError);
      expect('$error', contains('overflowed'));
      expect(tester.getRect(find.text('Submit e-Invoice')).right,
          greaterThan(412),
          reason: 'the last action sat past the right edge of the screen');
    });
  });

  group('the ticket reply controls', () {
    // The sixth of these, and the worst: 252 pixels, so Send was
    // entirely off the right edge and a ticket could not be replied to
    // from a phone at all. Found by constructing `TicketScreen` for
    // the first time.
    Widget controls({required bool narrow}) {
      final mode = SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: true, label: Text('Internal note')),
          ButtonSegment(value: false, label: Text('Reply to requester')),
        ],
        selected: const {true},
        onSelectionChanged: (_) {},
      );
      final send = FilledButton(onPressed: () {}, child: const Text('Send'));
      const quick = Icon(Icons.quickreply_outlined);

      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: mode,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [quick, const SizedBox(width: 8), send],
                    ),
                  ],
                )
              : Row(
                  children: [
                    mode,
                    const Spacer(),
                    quick,
                    const SizedBox(width: 8),
                    send,
                  ],
                ),
        ),
      );
    }

    testWidgets('fit a phone once they stack', (tester) async {
      await pump(tester, controls(narrow: true));
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('Send')).right,
        lessThanOrEqualTo(412),
      );
    });

    testWidgets('and would not have on one line', (tester) async {
      // Proof the stack does something. This is what shipped.
      await pump(tester, controls(narrow: false));
      final error = tester.takeException();
      expect(error, isFlutterError);
      expect('$error', contains('overflowed'));
    });
  });
}
