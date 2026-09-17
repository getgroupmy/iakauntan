import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/hr/people_screen.dart';

/// The employee directory, and the bar above it.
///
/// This screen had no test. It came up in a survey of every real
/// `AppBar.actions` row in the app — the exercise that found the same
/// defect on six other screens — and it was two pixels over at 360, the
/// narrowest Android in common use. Two pixels is not much, but Flutter
/// CLIPS an overflowing toolbar in a release build rather than
/// reporting it, so the way to find out is to render it.
///
/// Two of its neighbours in that survey, `items_screen.dart` and
/// `pipeline_screen.dart`, were clean at every width. The estimate had
/// flagged all three; only one was real, which is the reason the sweeps
/// render rather than compute.
void main() {
  Widget harness({bool canManageHr = true}) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      directoryProvider.overrideWith((ref) async => const []),
      canManageHrProvider.overrideWithValue(canManageHr),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const PeopleScreen()),
  );

  /// `pump` twice rather than `pumpAndSettle`: `directoryProvider` is
  /// overridden but the screen's other reads are not, and an
  /// unreachable repository leaves `AsyncView` retrying on a periodic
  /// timer that never settles.
  Future<void> show(
    WidgetTester tester, {
    double width = 1400,
    bool canManageHr = true,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(harness(canManageHr: canManageHr));
    await tester.pump();
    await tester.pump();
  }

  group('the bar fits', () {
    for (final width in [1400.0, 1000.0, 800.0, 700.0, 600.0, 412.0, 360.0]) {
      testWidgets('at ${width.toInt()} wide', (tester) async {
        await show(tester, width: width);

        expect(find.byType(PeopleScreen), findsOneWidget);
      });
    }
  });

  group('adding somebody', () {
    testWidgets('names what is being added on a laptop', (tester) async {
      await show(tester);

      expect(find.text('Add employee'), findsOneWidget);
    });

    testWidgets('and keeps the button, losing the noun, on a phone',
        (tester) async {
      // The button stays: adding somebody is what an HR manager opens
      // this screen to do. The list behind it says who is being added.
      await show(tester, width: 412);

      expect(find.text('Add'), findsOneWidget);
      expect(find.text('Add employee'), findsNothing);
    });

    testWidgets('and is not offered to somebody who does not run HR',
        (tester) async {
      // The control for all three actions. Every one of them opens
      // something only an HR manager may see — the attendance month and
      // the expiring-documents list are other people's records.
      await show(tester, canManageHr: false);

      expect(find.text('Add employee'), findsNothing);
      expect(find.text('Add'), findsNothing);
      expect(find.byKey(const ValueKey('attendance-month')), findsNothing);
      expect(find.byKey(const ValueKey('expiring-documents')), findsNothing);
    });

    testWidgets('and all of them are offered to somebody who does',
        (tester) async {
      await show(tester);

      expect(find.byKey(const ValueKey('attendance-month')), findsOneWidget);
      expect(find.byKey(const ValueKey('expiring-documents')), findsOneWidget);
    });
  });
}
