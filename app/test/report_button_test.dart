import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/router.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/feedback/report_button.dart';
import 'package:iakauntan/src/features/feedback/screenshot.dart';

/// The button a beta tester carries on every screen.
///
/// Three things are worth asserting and they are in different places.
///
/// **Who sees it.** `0663` decides, and the failure that matters is the
/// one in the generous direction: a button drawn for everybody would
/// open a form that the server then refuses, which is a worse outcome
/// than no button. So the loading and error arms are asserted as well
/// as the two answers, because they are what the app draws most often —
/// the lookup is in flight on every cold start.
///
/// **Where it sits.** The placement is a fraction of the travel rather
/// than a pixel offset, so rotating a phone keeps it roughly where it
/// was put. That is arithmetic, and it is pure and tested as such —
/// dragging a real widget across a real window would assert the gesture
/// recogniser rather than the rule.
///
/// **That it is not in its own photograph.** The button is a sibling of
/// the screenshot boundary rather than a child of it. Nothing on screen
/// would ever show that up; what shows it up is the tree.
void main() {
  Widget wrap(Widget child, {bool? beta, bool erroring = false}) =>
      ProviderScope(
        overrides: [
          isBetaTesterProvider.overrideWith((ref) async {
            if (erroring) throw StateError('the lookup failed');
            if (beta == null) {
              // Never completes: the lookup still in flight, which is
              // what every cold start looks like for a moment.
              return Completer<bool>().future;
            }
            return beta;
          }),
        ],
        // `ReportButtonOverlay` wraps the whole app in `app.dart`, so
        // the test has to wrap too. Written without it first, and every
        // assertion about the button failed to find one -- which is the
        // right failure and the reason this line is worth a comment.
        //
        // `navigatorKey` because the button opens its sheet and its
        // form through `rootNavigatorKey` rather than through its own
        // context: it lives above the navigator in the real app, so
        // `Navigator.of(context)` finds nothing. A tree without the key
        // gives a button that does nothing when tapped.
        child: MaterialApp(
          theme: AppTheme.light(),
          navigatorKey: rootNavigatorKey,
          home: ReportButtonOverlay(child: child),
        ),
      );

  group('where the button sits', () {
    // The default inset, named rather than typed out, so the sums
    // below cannot drift from the widget's.
    const inset = Space.md;
    const travelX = 400 - 52 - inset * 2;

    test('the bottom right is where it starts', () {
      final at = spotToOffset((x: 1, y: 1), const Size(400, 800), 52);
      expect(at.dx, inset + travelX);
      expect(at.dy, inset + (800 - 52 - inset * 2));
    });

    test('and the top left is the other end of the same travel', () {
      final at = spotToOffset((x: 0, y: 0), const Size(400, 800), 52);
      expect(at, const Offset(inset, inset));
    });

    test('halfway is halfway along the travel, not along the window', () {
      // The distinction the fraction exists for. Half the WINDOW would
      // be 200, which puts the button's left edge past the middle by
      // half its own width.
      final at = spotToOffset((x: 0.5, y: 0.5), const Size(400, 800), 52);
      expect(at.dx, inset + travelX / 2);
      expect(at.dx, lessThan(200));
    });

    test('a spot past the edge is brought back', () {
      // A finger leaves the screen. That is the ordinary case, not an
      // error, and the button has to end up somewhere pressable.
      expect(clampSpot((x: 1.4, y: -0.3)), (x: 1.0, y: 0.0));
      expect(clampSpot((x: 0.5, y: 0.5)), (x: 0.5, y: 0.5));
    });

    test('a window narrower than the button does not go negative', () {
      // 40 of room and a 52 button. The subtraction is negative, and an
      // unclamped one puts the button off the left of the screen --
      // which is the one place it cannot be dragged back from.
      final at = spotToOffset((x: 1, y: 1), const Size(40, 40), 52);
      expect(at.dx, greaterThanOrEqualTo(0));
      expect(at.dy, greaterThanOrEqualTo(0));
    });
  });

  group('what a screenshot is called', () {
    test('it carries the moment it was taken', () {
      // Stamped because a tester reporting three faults in a minute
      // would otherwise send three files called the same thing.
      expect(
        screenshotName(DateTime(2026, 9, 21, 11, 4, 7)),
        'screen-20260921-110407.png',
      );
    });

    test('and every part is padded, so the names sort', () {
      expect(
        screenshotName(DateTime(2026, 1, 2, 3, 4, 5)),
        'screen-20260102-030405.png',
      );
    });
  });

  group('taking one', () {
    test('wraps the bytes as a PNG the report can carry', () {
      // The type, which decides what the storage object is served as
      // and which thumbnail the picker draws. Nothing asserted it
      // before and a mutant that dropped it survived.
      //
      // The rasterising half is deliberately not asserted here: a
      // headless `flutter test` does not dependably produce an image,
      // so a test around `toImage` would be a test of the harness.
      final file = screenshotFile(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]),
        at: DateTime(2026, 9, 21, 11, 4, 7),
      );
      expect(file.mimeType, 'image/png');
      expect(file.name, 'screen-20260921-110407.png');
      expect(file.bytes, [0x89, 0x50, 0x4E, 0x47]);
    });

    testWidgets('and gives back nothing where there is no boundary',
        (t) async {
      // A key attached to no render object, which is what the button
      // has if it is pressed during the first frame. Null rather than
      // a throw: somebody who pressed report still has something to
      // say, and taking the form away because the camera failed is the
      // wrong trade.
      await t.pumpWidget(const MaterialApp(home: Text('no boundary')));
      expect(await captureScreenshot(GlobalKey()), isNull);
    });
  });

  group('who sees it', () {
    testWidgets('somebody on the beta list', (t) async {
      await t.pumpWidget(wrap(const Text('a screen'), beta: true));
      await t.pump();
      expect(find.byKey(const ValueKey('beta-report-button')), findsOneWidget);
    });

    testWidgets('and nobody else', (t) async {
      await t.pumpWidget(wrap(const Text('a screen'), beta: false));
      await t.pump();
      expect(find.byKey(const ValueKey('beta-report-button')), findsNothing);
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('not while the answer is still on its way', (t) async {
      // The state every cold start passes through. Guessing yes here
      // would flash a button at everybody and open a form the server
      // refuses.
      await t.pumpWidget(wrap(const Text('a screen'), beta: null));
      await t.pump();
      expect(find.byKey(const ValueKey('beta-report-button')), findsNothing);
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('and not when the lookup failed', (t) async {
      await t.pumpWidget(wrap(const Text('a screen'), erroring: true));
      await t.pump();
      expect(find.byKey(const ValueKey('beta-report-button')), findsNothing);
      // The app itself is unharmed, which is the point: a failed
      // lookup costs a button, never a screen.
      expect(find.text('a screen'), findsOneWidget);
    });
  });

  group('the button is not in its own photograph', () {
    /// The nearest [RepaintBoundary] above [of], as an element.
    ///
    /// Identity, not "a RepaintBoundary with a GlobalKey". Flutter puts
    /// its own boundaries all over the tree — a `Scaffold`, a route, a
    /// `ListView` item — and several carry global keys, so a check by
    /// shape finds one above everything and says nothing at all. This
    /// was written that way first and passed for the wrong reason.
    Element? boundaryAbove(WidgetTester t, Finder of) {
      Element? found;
      t.element(of).visitAncestorElements((e) {
        if (e.widget is RepaintBoundary) {
          found = e;
          return false;
        }
        return true;
      });
      return found;
    }

    bool isUnder(WidgetTester t, Finder what, Element ancestor) {
      var under = false;
      t.element(what).visitAncestorElements((e) {
        if (identical(e, ancestor)) {
          under = true;
          return false;
        }
        return true;
      });
      return under;
    }

    testWidgets('the app is inside the boundary and the button is not',
        (t) async {
      await t.pumpWidget(wrap(const Text('a screen'), beta: true));
      await t.pump();

      final shutter = boundaryAbove(t, find.text('a screen'));
      expect(shutter, isNotNull, reason: 'nothing would be captured at all');

      // The one that matters. A button inside this element appears in
      // the corner of every screenshot a tester sends: a picture of the
      // app, plus a thing that is not part of the app, in the place the
      // fault probably was.
      expect(
        isUnder(t, find.byKey(const ValueKey('beta-report-button')), shutter!),
        isFalse,
        reason: 'the button is inside the screenshot boundary',
      );
    });
  });

  group('where app.dart actually puts it', () {
    testWidgets('the form opens although the overlay is above the navigator',
        (t) async {
      // `wrap` above puts the overlay under `home:`, which is BELOW the
      // navigator. `app.dart` puts it in `MaterialApp.builder`, which
      // is ABOVE one — the builder's child IS the navigator. A
      // `showDialog` that looked up the tree from there would find no
      // Navigator and throw, in production, on a test suite that was
      // entirely green.
      //
      // So this one mirrors the real tree rather than a convenient one.
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            isBetaTesterProvider.overrideWith((ref) async => true),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            navigatorKey: rootNavigatorKey,
            builder: (context, child) =>
                ReportButtonOverlay(child: child ?? const SizedBox.shrink()),
            home: const Scaffold(body: Text('a screen')),
          ),
        ),
      );
      await t.pump();

      await t.tap(find.byKey(const ValueKey('beta-report-button')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('report-plain')));
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.text('Tell us'), findsOneWidget);
      expect(find.text('a screen'), findsOneWidget);
    });
  });

  group('the menu', () {
    testWidgets('offers both ways in', (t) async {
      await t.pumpWidget(wrap(const Scaffold(body: Text('a screen')),
          beta: true));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('beta-report-button')));
      await t.pumpAndSettle();

      expect(find.byKey(const ValueKey('report-with-shot')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-plain')), findsOneWidget);
    });

    testWidgets('and reporting without one opens the form in place',
        (t) async {
      // In place, over the screen that was already there -- not a route
      // to /feedback. Closing it has to put somebody back in the middle
      // of what they were doing, or nobody reports the second fault of
      // the morning.
      await t.pumpWidget(wrap(const Scaffold(body: Text('a screen')),
          beta: true));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('beta-report-button')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('report-plain')));
      await t.pumpAndSettle();

      expect(find.text('Tell us'), findsOneWidget);
      // The screen underneath is still mounted, which is what "in
      // place" means and what a route would have broken.
      expect(find.text('a screen'), findsOneWidget);
    });
  });
}
