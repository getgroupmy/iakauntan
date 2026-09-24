import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/shared/scan_progress.dart';

/// The modal that holds the screen while a document is read.
///
/// Asked for in one sentence: "once a document is uploaded for scanning
/// it should have a progress popup and block all activity till its 100%
/// completed". Between the press and the answer there was nothing on
/// screen at all — an upload and a read, several seconds of it, looking
/// exactly like a button that had not worked.
///
/// What these assert is the two halves of that: it BLOCKS, and it GOES
/// AWAY. The second is the one worth having tests for. A progress dialog
/// that outlives the work it describes is worse than none at all,
/// because the only way past it is to reload the page — so there is a
/// case here for each way the work can end.
void main() {
  /// A screen with one button that runs [action] behind the modal.
  Widget host({
    required Future<String> Function(void Function(ScanStage)) action,
    void Function(Object)? onError,
    void Function(String)? onValue,
    ScanStage from = ScanStage.attaching,
  }) =>
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    // The await on its own line, and NOT written
                    // `onValue?.call(await whileScanning(...))`. Dart's
                    // null-shorting skips the whole expression when the
                    // receiver is null — arguments included — so with
                    // no `onValue` that form never calls the thing
                    // under test at all. Four of these tests failed
                    // that way, saying the dialog was missing when the
                    // work had never started.
                    final value = await whileScanning<String>(
                      context,
                      from: from,
                      action: action,
                    );
                    onValue?.call(value);
                  } catch (e) {
                    onError?.call(e);
                  }
                },
                child: const Text('Scan'),
              ),
            ),
          ),
        ),
      );

  Future<void> start(WidgetTester tester) async {
    await tester.tap(find.text('Scan'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('it is up while the work runs, and says what is happening',
      (tester) async {
    final held = Completer<String>();
    String? got;
    await tester.pumpWidget(host(
      action: (_) => held.future,
      onValue: (v) => got = v,
    ));
    await start(tester);

    expect(find.text('Scanning'), findsOneWidget);
    expect(find.text('Attaching the file'), findsOneWidget);
    expect(find.text('Step 1 of 2'), findsOneWidget);
    expect(got, isNull);

    held.complete('read');
    await tester.pumpAndSettle();

    expect(find.text('Scanning'), findsNothing);
    expect(got, 'read');
  });

  testWidgets('and nothing behind it can be reached', (tester) async {
    final held = Completer<String>();
    var presses = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                presses++;
                whileScanning<String>(context, action: (_) => held.future);
              },
              child: const Text('Scan'),
            ),
          ),
        ),
      ),
    ));
    await start(tester);
    expect(presses, 1);

    // The button that started it is under the barrier now, which is
    // the point: a second press is a second upload and a second
    // charge for one document.
    await tester.tap(find.text('Scan'), warnIfMissed: false);
    await tester.pump();
    expect(presses, 1);

    // And the barrier itself does not dismiss it. SETTLED, not pumped
    // once: a dismissal is animated, so a single frame after the tap
    // still finds the dialog on its way out and the assertion would
    // pass whether or not the barrier were live.
    //
    // A MUTANT THAT SURVIVES HERE AND IS EQUIVALENT: flipping
    // `barrierDismissible` to true changes nothing, because a barrier
    // dismissal goes through `Navigator.maybePop`, and `canPop: false`
    // on the `PopScope` above the dialog vetoes exactly that. The two
    // flags are one mechanism, and the `PopScope` is the half that
    // decides. Both are kept: `barrierDismissible: false` says what is
    // meant at the place somebody would look for it, and it is the
    // guard that remains if the scope is ever loosened.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Scanning'), findsOneWidget);

    held.complete('read');
    await tester.pumpAndSettle();
  });

  // The back gesture on a phone and the browser's back button both
  // reach a dialog. Either would leave the upload running behind a
  // screen that says nothing about it.
  testWidgets('nor does going back', (tester) async {
    final held = Completer<String>();
    await tester.pumpWidget(host(action: (_) => held.future));
    await start(tester);

    final guard = tester.widget<PopScope>(find.ancestor(
      of: find.byType(AlertDialog),
      matching: find.byType(PopScope),
    ));
    expect(guard.canPop, isFalse);

    held.complete('read');
    await tester.pumpAndSettle();
  });

  testWidgets('the stage moves when the work says so', (tester) async {
    final held = Completer<String>();
    void Function(ScanStage)? report;
    await tester.pumpWidget(host(action: (r) {
      report = r;
      return held.future;
    }));
    await start(tester);

    expect(find.text('Attaching the file'), findsOneWidget);

    report!(ScanStage.reading);
    await tester.pump();
    expect(find.text('Reading the document'), findsOneWidget);
    expect(find.text('Step 2 of 2'), findsOneWidget);

    // `0703`'s fallback. The wait just got longer and the modal has to
    // say why, or it reads as stuck.
    report!(ScanStage.readingHere);
    await tester.pump();
    expect(find.text('Reading it on this device instead'), findsOneWidget);
    expect(find.textContaining('did not answer'), findsOneWidget);

    held.complete('read');
    await tester.pumpAndSettle();
  });

  // The case that makes this safe to use at all.
  testWidgets('it closes when the work throws, and the error still arrives',
      (tester) async {
    final held = Completer<String>();
    Object? caught;
    await tester.pumpWidget(host(
      action: (_) => held.future,
      onError: (e) => caught = e,
    ));
    await start(tester);
    expect(find.text('Scanning'), findsOneWidget);

    held.completeError(StateError('the reader refused'));
    await tester.pumpAndSettle();

    expect(find.text('Scanning'), findsNothing);
    expect(caught, isA<StateError>());
  });

  // A rescan has no upload, so a "Step 2 of 2" counter would be the
  // only thing on screen implying a step one that never happened.
  testWidgets('a rescan counts no steps', (tester) async {
    final held = Completer<String>();
    await tester.pumpWidget(
        host(action: (_) => held.future, from: ScanStage.reading));
    await start(tester);

    expect(find.text('Reading the document'), findsOneWidget);
    expect(find.text('Step 2 of 2'), findsNothing);

    held.complete('read');
    await tester.pumpAndSettle();
  });

  // Blocking everything is the request; blocking everything FOREVER is
  // an app that has to be force-quit, and a scan can hang on a vendor
  // that is not answering anybody.
  testWidgets('after a long wait there is a way out', (tester) async {
    final held = Completer<String>();
    String? got;
    await tester.pumpWidget(host(
      action: (_) => held.future,
      onValue: (v) => got = v,
    ));
    await start(tester);

    // Absent, and still absent well into the wait. Asserting it only
    // at the first frame let a timer of `Duration.zero` through the
    // first sweep — the button would have been there from the start
    // and this said nothing.
    expect(find.text('Leave it running'), findsNothing);
    await tester.pump(scanWaitBeforeEscape - const Duration(seconds: 5));
    expect(find.text('Leave it running'), findsNothing);

    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Leave it running'), findsOneWidget);

    await tester.tap(find.text('Leave it running'));
    await tester.pumpAndSettle();
    expect(find.text('Scanning'), findsNothing);

    // The work was not cancelled, and finishing after the dialog has
    // gone must not throw over a modal that is no longer there.
    held.complete('read');
    await tester.pumpAndSettle();
    expect(got, 'read');
  });
}
