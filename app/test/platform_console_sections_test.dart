import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// The platform console's ten sections.
///
/// They were a scrolling strip of tabs, then a second side menu drawn
/// inside the console beside the app's own — which on a laptop meant a
/// window with two menus in it, a column of icons on the far left and a
/// list of sections next to it. They are routes now, and the app's one
/// side menu opens them like any other screen.
///
/// What is protected here is that the table below stays a table the
/// menu and the router can both be built from: distinct paths under
/// /admin, headings that come in runs so grouping does not reorder
/// anything, and enough marked primary that a phone's bottom bar has
/// slots to draw.
void main() {
  group('the section table', () {
    test('every section has its own route under the console', () {
      final paths = platformConsoleSections.map((s) => s.path).toList();
      expect(paths.toSet(), hasLength(paths.length), reason: 'no duplicates');
      for (final p in paths) {
        expect(p == '/admin' || p.startsWith('/admin/'), isTrue,
            reason: '$p belongs to the console');
      }
    });

    test('every section has its own name', () {
      final labels = platformConsoleSections.map((s) => s.label).toList();
      expect(labels.toSet(), hasLength(labels.length));
    });

    test('headings come in runs, so grouping cannot reorder the menu', () {
      // `groupByModule` keeps a heading's items together in the order it
      // first met them. If a group appeared twice with something else
      // between, switching grouping on would move a section past its
      // neighbours — the menu would rearrange itself under somebody.
      final seen = <String>[];
      for (final s in platformConsoleSections) {
        if (seen.isEmpty || seen.last != s.group) {
          expect(seen, isNot(contains(s.group)),
              reason: '${s.group} is split across the table');
          seen.add(s.group);
        }
      }
      expect(seen.length, greaterThan(1), reason: 'there are headings to show');
    });

    test('grouping the sections keeps every one of them', () {
      final sections = groupByModule<ConsoleSection>(
        platformConsoleSections,
        (s) => s.group,
        const {},
        true,
      );
      final grouped = [for (final s in sections) ...s.items];
      expect(grouped, platformConsoleSections,
          reason: 'grouped, the order is the table\'s own');
      for (final s in sections) {
        expect(s.heading, isNotNull,
            reason: 'no section falls out under no heading');
      }
    });

    test('enough sections are primary for a phone to draw a bar', () {
      // Material asserts on a `NavigationBar` with fewer than two
      // destinations, and "More" is only one of them. With nothing
      // marked primary an operator's phone threw instead of rendering.
      final primary = platformConsoleSections.where((s) => s.primary);
      expect(primary.length, greaterThanOrEqualTo(1));
      expect(primary.first.path, '/admin', reason: 'Overview leads');
    });
  });

  group('the screen', () {
    Widget harness(String path, {required bool admin}) => ProviderScope(
          overrides: [
            isPlatformAdminProvider.overrideWith((_) async => admin),
            platformStatsProvider.overrideWith((_) async => const {}),
            platformOrgsProvider.overrideWith((_) async => const []),
            platformModulesProvider.overrideWith((_) async => const []),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: PlatformConsoleScreen(path: path),
          ),
        );

    testWidgets('shows the section the route names', (tester) async {
      await tester.pumpWidget(harness('/admin/organizations', admin: true));
      await tester.pumpAndSettle();

      // The app bar names it, and the section itself is what is under it.
      expect(find.text('Organizations'), findsOneWidget);
      expect(find.text('No organizations yet'), findsOneWidget);
    });

    testWidgets('and falls back to Overview for a path it does not know',
        (tester) async {
      await tester.pumpWidget(harness('/admin/nonsense', admin: true));
      await tester.pumpAndSettle();

      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Platform health'), findsOneWidget);
    });

    testWidgets('somebody who is not platform staff sees none of it',
        (tester) async {
      await tester.pumpWidget(harness('/admin', admin: false));
      await tester.pumpAndSettle();

      expect(find.text('Not a platform administrator'), findsOneWidget);
      expect(find.text('Platform health'), findsNothing);
    });
  });
}
