import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/features/secretarial/secretarial_screen.dart';

/// The secretarial desk, where a missed date is the whole risk.
///
/// The dates themselves are computed in SQL from the incorporation date
/// and the year end against the section that imposes them, and asserted
/// there. What this widget decides is what a practice SEES, and three
/// of those decisions are ones somebody acts on that morning.
///
/// HOW LONG IS LEFT. `_when` has three branches around zero, and the
/// boundary is the one that matters: a filing due today is the last day
/// it can be lodged without penalty, and "in 0 days" both reads as
/// nothing to do and sorts in the mind beside "in 9 days". Every
/// fixture here is built relative to MALAYSIAN today, the same way
/// `daysLeft` computes it -- UTC+8, fixed, no daylight saving -- so
/// these assertions do not depend on where the machine running them
/// thinks it is.
///
/// WHETHER ANYBODY HAS TAKEN IT UP. The list is computed from the Act,
/// so without the lifecycle step it shows the same filing as due for as
/// long as the company exists, however many times it was lodged. Three
/// answers and no fourth: not started, being worked on, over.
///
/// AND THE CONSEQUENCE. The overdue notice names s.352, where late
/// lodgement of a charge does not merely cost a penalty -- it costs the
/// security altogether. A notice that said only "3 overdue" has not
/// told a practice why to stop what it is doing.
void main() {
  /// Malaysian today, computed here the way `CorpFiling.daysLeft`
  /// computes it, so a fixture built as "due in 3 days" really is.
  DateTime malaysianToday() {
    final kl = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(kl.year, kl.month, kl.day);
  }

  CorpFiling filing({
    required int inDays,
    String entityId = 'e1',
    String entityName = 'Rantaian Maju Sdn Bhd',
    String filingType = 'annual_return',
    String filingName = 'Annual Return',
    String statuteRef = 's.68 CA 2016',
    String status = 'due',
    String? legacyForm,
    String? filingId,
  }) =>
      CorpFiling(
        entityId: entityId,
        entityName: entityName,
        filingType: filingType,
        filingName: filingName,
        statuteRef: statuteRef,
        triggerDate: malaysianToday().subtract(const Duration(days: 30)),
        dueDate: malaysianToday().add(Duration(days: inDays)),
        status: status,
        legacyForm: legacyForm,
        filingId: filingId,
      );

  CorpEntity entity({
    String id = 'e1',
    String name = 'Rantaian Maju Sdn Bhd',
    String type = 'sdn_bhd',
    String status = 'incorporated',
    String? registrationNo = '202001234567',
    DateTime? incorporatedOn,
    int? fyeDay = 31,
    int? fyeMonth = 12,
  }) =>
      CorpEntity(
        id: id,
        name: name,
        entityType: type,
        status: status,
        registrationNo: registrationNo,
        incorporatedOn: incorporatedOn,
        fyeDay: fyeDay,
        fyeMonth: fyeMonth,
      );

  late GoRouter router;

  Widget wrap({
    List<CorpFiling> filings = const [],
    List<CorpEntity> entities = const [],
    String role = 'owner',
  }) {
    router = GoRouter(
      initialLocation: '/secretarial',
      routes: [
        GoRoute(
          path: '/secretarial',
          builder: (_, __) => const SecretarialScreen(),
        ),
        GoRoute(
          path: '/secretarial/people',
          builder: (_, __) => const Scaffold(body: Text('the people list')),
        ),
        GoRoute(
          path: '/secretarial/new',
          builder: (_, __) => const Scaffold(body: Text('a new company')),
        ),
        GoRoute(
          path: '/secretarial/:id',
          builder: (_, __) => const Scaffold(body: Text('one company')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        corpFilingsProvider.overrideWith((ref) async => filings),
        corpEntitiesProvider.overrideWith((ref) async => entities),
        memberRoleProvider.overrideWith((ref) async => role),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    );
  }

  Future<void> show(
    WidgetTester tester, {
    List<CorpFiling> filings = const [],
    List<CorpEntity> entities = const [],
    String role = 'owner',
  }) async {
    await tester.pumpWidget(
        wrap(filings: filings, entities: entities, role: role));
    await tester.pumpAndSettle();
  }

  String where() => router.routerDelegate.currentConfiguration.uri.toString();

  group('how long is left', () {
    testWidgets('a deadline still ahead counts down', (tester) async {
      await show(tester, filings: [filing(inDays: 9)]);

      expect(find.text('in 9 days'), findsOneWidget);
    });

    testWidgets('one due today says so, not "in 0 days"', (tester) async {
      // The boundary. Today is the last day it can be lodged without
      // penalty; "in 0 days" reads as nothing to do.
      await show(tester, filings: [filing(inDays: 0)]);

      expect(find.text('due today'), findsOneWidget);
      expect(find.text('in 0 days'), findsNothing);
    });

    testWidgets('and one already missed counts up, positively',
        (tester) async {
      // Late by five days reads "5 days late" and not "-5 days late",
      // which is what an unnegated difference gives you.
      await show(tester, filings: [filing(inDays: -5)]);

      expect(find.text('5 days late'), findsOneWidget);
      expect(find.text('-5 days late'), findsNothing);
    });
  });

  group('what being late costs', () {
    testWidgets('the notice counts the overdue ones only', (tester) async {
      await show(tester, filings: [
        filing(inDays: -5, entityId: 'a'),
        filing(inDays: -1, entityId: 'b', entityName: 'Alpha Holdings Sdn Bhd'),
        filing(inDays: 3, entityId: 'c', entityName: 'Beta Ventures Sdn Bhd'),
      ]);

      // Two, not three: the third is merely urgent.
      expect(find.textContaining('2 filings are past the statutory deadline'),
          findsOneWidget);
    });

    testWidgets('one overdue filing is singular', (tester) async {
      await show(tester, filings: [filing(inDays: -5)]);

      expect(find.textContaining('1 filing is past the statutory deadline'),
          findsOneWidget);
    });

    testWidgets('and it names what s.352 costs', (tester) async {
      await show(tester, filings: [filing(inDays: -5)]);

      // Not merely a penalty. A charge lodged late under s.352 is
      // void against a liquidator, and the practice needs that word in
      // front of it rather than a count.
      expect(find.textContaining('s.352'), findsOneWidget);
      expect(find.textContaining('costs the security altogether'),
          findsOneWidget);
    });

    testWidgets('nothing overdue, no notice', (tester) async {
      // The control: the notice is conditional.
      await show(tester, filings: [filing(inDays: 3), filing(inDays: 40)]);

      expect(find.textContaining('past the statutory deadline'), findsNothing);
    });
  });

  group('whether anybody has taken it up', () {
    testWidgets('a deadline nobody has started offers to start it',
        (tester) async {
      await show(tester, filings: [filing(inDays: 9, filingId: null)]);

      expect(find.text('Start it'), findsOneWidget);
      expect(find.text('Lodged?'), findsNothing);
    });

    testWidgets('one already opened asks whether it went', (tester) async {
      await show(tester,
          filings: [filing(inDays: 9, filingId: 'f1', status: 'in_progress')]);

      expect(find.text('Lodged?'), findsOneWidget);
      expect(find.text('Start it'), findsNothing);
    });

    testWidgets('and a settled one offers nothing at all', (tester) async {
      // lodged, approved and not_applicable are all past the point where
      // anything on this screen helps. Offering "Lodged?" on a filing
      // already lodged invites lodging it twice.
      for (final status in const ['lodged', 'approved', 'not_applicable']) {
        await show(tester,
            filings: [filing(inDays: 9, filingId: 'f1', status: status)]);

        expect(find.text('Lodged?'), findsNothing, reason: status);
        expect(find.text('Start it'), findsNothing, reason: status);
        expect(find.byType(StatusChip), findsOneWidget, reason: status);
      }
    });
  });

  group('what the row says about the filing', () {
    testWidgets('the section and the date that triggered it', (tester) async {
      await show(tester, filings: [
        filing(
          inDays: 9,
          filingName: 'Annual Return',
          statuteRef: 's.68 CA 2016',
        ),
      ]);

      expect(find.text('Rantaian Maju Sdn Bhd'), findsOneWidget);
      expect(find.text('Annual Return'), findsOneWidget);
      // The section is on the row because a practice checks the rule,
      // not only the date.
      expect(find.textContaining('s.68 CA 2016 · triggered'), findsOneWidget);
    });

    testWidgets('the old form number in brackets, where there is one',
        (tester) async {
      // Somebody who has filed these for twenty years knows Form 24 and
      // not "Return of Allotment of Shares".
      await show(tester, filings: [
        filing(
          inDays: 9,
          filingName: 'Return of Allotment of Shares',
          legacyForm: 'Form 24',
        ),
      ]);

      expect(find.text('Return of Allotment of Shares (Form 24)'),
          findsOneWidget);
    });

    testWidgets('and nothing in brackets where there is not', (tester) async {
      // The control for the line above: a filing with no legacy form
      // must not render empty brackets.
      await show(tester, filings: [filing(inDays: 9, legacyForm: null)]);

      expect(find.text('Annual Return'), findsOneWidget);
      expect(find.textContaining('()'), findsNothing);
    });
  });

  group('the companies on the books', () {
    testWidgets('carry the type, the number and the year end', (tester) async {
      await show(tester, entities: [
        entity(
          type: 'sdn_bhd',
          registrationNo: '202001234567',
          incorporatedOn: DateTime(2020, 3, 14),
          fyeDay: 31,
          fyeMonth: 12,
        ),
      ]);

      expect(
        find.text('Sdn Bhd · 202001234567 · incorporated 14/03/2020 · '
            'year end 31 December'),
        findsOneWidget,
      );
    });

    testWidgets('a company with no registration number says so', (tester) async {
      // "no number" rather than a blank, because a company awaiting
      // incorporation is an ordinary state and a gap reads as a bug.
      await show(tester, entities: [
        entity(registrationNo: null, incorporatedOn: null),
      ]);

      expect(find.textContaining('no number'), findsOneWidget);
      // And with no incorporation date, that clause is absent entirely
      // rather than reading "incorporated —".
      expect(find.textContaining('incorporated'), findsNothing);
    });
  });

  group('where the desk takes you', () {
    testWidgets('a deadline opens the company it belongs to', (tester) async {
      await show(tester, filings: [
        filing(inDays: 9, entityId: 'abc', entityName: 'Rantaian Maju Sdn Bhd'),
      ]);

      await tester.tap(find.text('Rantaian Maju Sdn Bhd'));
      await tester.pumpAndSettle();

      // The filing's entity, not the first on the books: a practice
      // clicking a deadline is opening that company's file.
      expect(where(), '/secretarial/abc');
    });

    testWidgets('and so does a company on the books', (tester) async {
      await show(tester, entities: [entity(id: 'xyz', name: 'Beta Ventures')]);

      await tester.tap(find.text('Beta Ventures'));
      await tester.pumpAndSettle();

      expect(where(), '/secretarial/xyz');
    });

    testWidgets('the people are a list of their own', (tester) async {
      // Because a director outlives any one board: the same NRIC
      // resigns from one company and sits on another.
      await show(tester);

      await tester.tap(find.byKey(const ValueKey('open-people')));
      await tester.pumpAndSettle();

      expect(where(), '/secretarial/people');
    });
  });

  group('who may add a company', () {
    // `find.byType` matches the EXACT runtime type, and `FilledButton.icon`
    // builds a private subclass -- so `widgetWithText(FilledButton, ...)`
    // finds nothing even with the button on screen, and the viewer case
    // below would pass against a button that was always there. A
    // predicate matches the subclass.
    Finder addCompany() => find.ancestor(
          of: find.text('Add company'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        );

    testWidgets('somebody who may write is offered it', (tester) async {
      await show(tester, role: 'owner');

      expect(addCompany(), findsOneWidget);
    });

    testWidgets('a viewer is not', (tester) async {
      await show(tester, role: 'viewer');

      expect(addCompany(), findsNothing);
      expect(find.text('Add company'), findsNothing);
      // But still gets the desk, and the people: reading is not writing.
      expect(find.text('Falling due'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-people')), findsOneWidget);
    });
  });

  group('an empty desk', () {
    testWidgets('says what it means rather than looking broken',
        (tester) async {
      await show(tester);

      expect(find.text('Nothing due'), findsOneWidget);
      // Six months is the window, and saying so is the difference
      // between "nothing to do" and "nothing loaded".
      expect(find.textContaining('next six months'), findsOneWidget);
      expect(find.text('No companies yet'), findsOneWidget);
      expect(find.textContaining('incorporation date and year end'),
          findsWidgets);
    });
  });
}
