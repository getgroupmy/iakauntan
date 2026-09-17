import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skeletonizer/skeletonizer.dart';

import 'package:iakauntan/src/core/skeletons.dart';
import 'package:iakauntan/src/core/widgets.dart';

/// An outline of the rows on the way, instead of a spinner.
///
/// Three things are worth asserting and one of them has teeth.
///
/// The first two are about honesty: a skeleton is not content, so it
/// must not scroll and must not take a tap; and a screen that has NOT
/// asked for one must still get the circle, because the pages whose
/// layout the payload decides are right to keep it — `core/
/// page_waiting.dart` makes that argument and it still stands.
///
/// The third is the one that matters. A skeleton grid that breaks at
/// different widths from the real grid REFLOWS the instant the data
/// lands, which is exactly the flicker a skeleton exists to remove —
/// and nothing would ever report it, because the outline and the
/// content are never on screen at the same moment. So the column rule
/// is one shared function, and this is the test that says the dashboard
/// and the skeleton read the same one.
void main() {
  /// Whether anything on screen is being drawn as bones.
  ///
  /// Reads `SkeletonizerScope`, the inherited widget the bones consult,
  /// rather than looking for the `Skeletonizer` widget — which is an
  /// abstract class with factory constructors, so `find.byType` on it
  /// matches nothing at all and every assertion written that way
  /// passes for the wrong reason.
  bool skeletonizing(WidgetTester t) {
    final scopes = t.widgetList<SkeletonizerScope>(
      find.byType(SkeletonizerScope),
    );
    return scopes.any((s) => s.enabled);
  }

  Widget wrap(Widget child, {Size size = const Size(1200, 900)}) =>
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('the column rule', () {
    test('is one function, and these are its three answers', () {
      // Four across on a desktop, two on a tablet, one on a phone.
      // Pinned because `_MetricGrid` in dashboard_screen.dart calls
      // this same function -- so a change here moves both, and a
      // change to only one of them is no longer possible to write.
      expect(tileColumns(1200), 4);
      expect(tileColumns(1100), 4);
      expect(tileColumns(1099), 2);
      expect(tileColumns(700), 2);
      expect(tileColumns(699), 1);
      expect(tileColumns(320), 1);
    });

    testWidgets('and the skeleton grid actually uses it', (t) async {
      // Not the same statement as the test above. That one checks the
      // arithmetic; this one checks that `TilesSkeleton` ASKS it rather
      // than carrying its own copy, which is what it did at first.
      //
      // The widths are chosen to tell those two apart, and the first
      // set did not. 1200, 800 and 400 give 4, 2 and 1 under almost
      // any plausible pair of breakpoints -- a mutation run replaced
      // the shared call with `width >= 900 ? 4 : (width >= 500 ? 2 :
      // 1)` and the test passed, because every sampled width fell on
      // the same side of both rules. 1000 and 600 are the ones that
      // separate them: under the real breakpoints they are 2 and 1,
      // and under that mutant they are 4 and 2.
      for (final (width, want) in [
        (1200.0, 4),
        (1100.0, 4),
        (1000.0, 2),
        (800.0, 2),
        (700.0, 2),
        (600.0, 1),
        (400.0, 1),
      ]) {
        await t.pumpWidget(
          wrap(const TilesSkeleton(), size: Size(width, 900)),
        );
        final grid = t.widget<GridView>(find.byType(GridView));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, want, reason: 'at ${width}px');
      }
    });
  });

  group('a skeleton is not content', () {
    testWidgets('so it does not scroll', (t) async {
      // A list that can be dragged before there is anything in it is a
      // gesture that does nothing -- and worse, it takes the drag from
      // a pull-to-refresh that would have helped.
      await t.pumpWidget(wrap(const ListSkeleton()));
      final list = t.widget<ListView>(find.byType(ListView));
      expect(list.physics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('and neither does the tile grid', (t) async {
      await t.pumpWidget(wrap(const TilesSkeleton()));
      final grid = t.widget<GridView>(find.byType(GridView));
      expect(grid.physics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('and it is drawn as bones rather than as itself', (t) async {
      // The whole mechanism in one assertion. Without a skeletonizer
      // in force these are real `ListTile`s holding real empty `Text`,
      // which is a list of blank rows -- indistinguishable from
      // content that loaded and had nothing in it.
      //
      // `SkeletonizerScope` and not `Skeletonizer`: the latter is an
      // abstract class with factory constructors, so `find.byType`
      // finds none of them and the first version of this test passed
      // nothing while looking like it checked everything. The scope is
      // the inherited widget the bones actually read, so finding it
      // with `enabled` true is a statement about what is in force
      // rather than about which class was written.
      await t.pumpWidget(wrap(const ListSkeleton(rows: 3)));
      expect(skeletonizing(t), isTrue);
      expect(find.byType(ListTile), findsNWidgets(3));
    });

    testWidgets('and the row count is what was asked for', (t) async {
      await t.pumpWidget(wrap(const ListSkeleton(rows: 7)));
      expect(find.byType(ListTile), findsNWidgets(7));
    });
  });

  group('what each shape leaves out', () {
    testWidgets('a list without avatars draws no bone where none goes',
        (t) async {
      // Most of the app's lists have no avatar. A bone in that slot
      // pushes every title across by forty pixels and then they all
      // jump back when the data lands, which is the flicker again --
      // fainter, and in the direction that is harder to notice.
      await t.pumpWidget(wrap(const ListSkeleton(rows: 2, leading: false)));
      for (final tile in t.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.leading, isNull);
      }
      await t.pumpWidget(wrap(const ListSkeleton(rows: 2)));
      for (final tile in t.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.leading, isNotNull);
      }
    });

    testWidgets('and one without second lines draws no second line',
        (t) async {
      await t.pumpWidget(wrap(const ListSkeleton(rows: 2, subtitle: false)));
      for (final tile in t.widgetList<ListTile>(find.byType(ListTile))) {
        expect(tile.subtitle, isNull);
      }
    });

    testWidgets('and a table draws the columns the real one has', (t) async {
      // The count is the point. A table skeleton with the wrong number
      // of columns reflows on arrival.
      await t.pumpWidget(wrap(const TableSkeleton(columns: 5, rows: 3)));
      expect(find.byType(Row), findsNWidgets(3));
      expect(find.byType(Expanded), findsNWidgets(15));
    });
  });

  group('AsyncView', () {
    testWidgets('draws the skeleton a screen gave it', (t) async {
      await t.pumpWidget(
        wrap(
          AsyncView<int>(
            value: const AsyncValue.loading(),
            skeleton: const ListSkeleton(rows: 2),
            builder: (_) => const Text('arrived'),
          ),
        ),
      );
      expect(skeletonizing(t), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('and still the circle for a screen that gave none',
        (t) async {
      // The behaviour that must NOT change. Skeletons are opt-in: the
      // pre-sign-in pages draw a shape the payload decides, and an
      // outline there is a guess that turns out wrong -- the same
      // flicker in fainter grey. `core/page_waiting.dart` argues it at
      // length and is still right.
      await t.pumpWidget(
        wrap(
          AsyncView<int>(
            value: const AsyncValue.loading(),
            builder: (_) => const Text('arrived'),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(skeletonizing(t), isFalse);
    });

    testWidgets('and the older loading override still means what it meant',
        (t) async {
      await t.pumpWidget(
        wrap(
          AsyncView<int>(
            value: const AsyncValue.loading(),
            loading: const Text('one moment'),
            builder: (_) => const Text('arrived'),
          ),
        ),
      );
      expect(find.text('one moment'), findsOneWidget);
    });

    testWidgets('and the skeleton is gone the moment the data is there',
        (t) async {
      // A skeleton that outlived its answer would be a screen showing
      // an outline of content it already has.
      await t.pumpWidget(
        wrap(
          AsyncView<int>(
            value: const AsyncValue.data(1),
            skeleton: const ListSkeleton(),
            builder: (n) => Text('arrived $n'),
          ),
        ),
      );
      expect(find.text('arrived 1'), findsOneWidget);
      expect(skeletonizing(t), isFalse);
    });

    testWidgets('and an error is an answer, not a longer wait', (t) async {
      await t.pumpWidget(
        wrap(
          AsyncView<int>(
            value: AsyncValue.error(Exception('no'), StackTrace.empty),
            skeleton: const ListSkeleton(),
            builder: (_) => const Text('arrived'),
          ),
        ),
      );
      expect(skeletonizing(t), isFalse);
      expect(find.byType(ErrorState), findsOneWidget);
    });
  });
}
