import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/features/pos/provider_roster_screen.dart';

/// Who does the work at one outlet, and the week each of them keeps.
///
/// `provider_roster_test.dart` has every pure function underneath this
/// — `weekFromRows`, `weekBlockedBecause`, `rosterSummary`, all of it.
/// The dialogs on top of them had nothing, and they carry three
/// decisions the helpers cannot.
///
/// A WARNING THAT IS ONLY A COLOUR. `book_appointment` asks
/// `app.pos_provider_is_open`, which is an `exists` over the hours
/// table, so a provider whose week nobody entered is open at NO time
/// and every booking for them is refused by name. The roster line is
/// where that is said before a customer is turned away, and it is said
/// in the warning colour — a screenshot cannot tell the two lines
/// apart.
///
/// AND NOT SAID WHILE IT IS STILL BEING ASKED. The hours arrive one
/// provider at a time, so without the loading branch every name in the
/// shop reads "works no hours" for a moment on opening — the alarm this
/// file exists to raise, raised falsely, every time.
///
/// WHAT MAY BE SAVED. A week with a day half filled in CANNOT be, and
/// the day is named. A week with nothing in it CAN be, and is warned
/// about instead — clearing somebody's hours is a thing a manager does
/// on purpose, and the two messages are exclusive because a half-filled
/// week is not an empty one.
void main() {
  Map<String, dynamic> person({
    String id = 'p1',
    String name = 'Siti',
    String code = 'SITI',
  }) => {
    'id': id,
    'name': name,
    'code': code,
    'employee_id': null,
    'is_active': true,
  };

  /// A row of `pos_provider_hours`, which `0217` numbers by
  /// `extract(isodow)` — 1 is Monday.
  Map<String, dynamic> hours({
    int weekday = 1,
    String start = '09:00:00',
    String end = '18:00:00',
  }) => {'weekday': weekday, 'starts_at': start, 'ends_at': end};

  Map<String, dynamic> away({
    String id = 'o1',
    required String from,
    required String to,
    String? reason = 'Cuti',
  }) => {
    'id': id,
    'starts_at': from,
    'ends_at': to,
    'reason': reason,
  };

  /// The hours for a provider whose answer never arrives, for the
  /// loading branch.
  final pending = Completer<List<Map<String, dynamic>>>();

  Widget wrap({
    List<Map<String, dynamic>> people = const [],
    Map<String, List<Map<String, dynamic>>> weeks = const {},
    Map<String, List<Map<String, dynamic>>> timeOff = const {},
    Set<String> loading = const {},
  }) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      posServiceProvidersProvider('o1').overrideWith((ref) async => people),
      posProviderHoursProvider.overrideWith((ref, id) {
        if (loading.contains(id)) return pending.future;
        return Future.value(weeks[id] ?? const []);
      }),
      posProviderTimeOffProvider
          .overrideWith((ref, id) async => timeOff[id] ?? const []),
      employeesProvider('active').overrideWith((ref) async => const []),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showProviderRoster(context, 'o1'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    List<Map<String, dynamic>> people = const [],
    Map<String, List<Map<String, dynamic>>> weeks = const {},
    Map<String, List<Map<String, dynamic>>> timeOff = const {},
    Set<String> loading = const {},
  }) async {
    await tester.pumpWidget(wrap(
      people: people,
      weeks: weeks,
      timeOff: timeOff,
      loading: loading,
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The colour of a subtitle, which is where the warning lives.
  Color? colourOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style?.color;

  /// Whether a button is live. `onPressed: null` is the whole of the
  /// gate on three of these dialogs, and it is invisible.
  bool enabled(WidgetTester tester, Key key) =>
      tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed != null;

  group('the roster', () {
    testWidgets('says what an empty one costs', (tester) async {
      await show(tester);

      expect(find.text('Nobody yet'), findsOneWidget);
      // Not "add some people": the sentence has to say that a booking
      // for somebody with no week is REFUSED, because that is what
      // happens and nothing else says so.
      expect(find.textContaining('every booking made for them is refused'),
          findsOneWidget);
    });

    testWidgets('lists the days somebody works', (tester) async {
      await show(
        tester,
        people: [person()],
        weeks: {
          'p1': [hours(weekday: 1), hours(weekday: 3), hours(weekday: 6)],
        },
      );

      expect(find.text('Siti'), findsOneWidget);
      expect(find.text('Mon, Wed, Sat'), findsOneWidget);
    });

    testWidgets('and warns, in colour, about somebody who works none',
        (tester) async {
      // Both on one screen. A colour asserted with nothing beside it
      // passes against a list that draws every line the same.
      await show(
        tester,
        people: [
          person(id: 'p1', name: 'Siti'),
          person(id: 'p2', name: 'Aminah'),
        ],
        weeks: {
          'p1': [hours(weekday: 1)],
        },
      );

      const warningLine = 'Works no hours — every booking will be refused';
      expect(find.text(warningLine), findsOneWidget);

      final colours = AppTheme.light().extension<AppColors>()!;
      expect(colourOf(tester, warningLine), colours.warning);
      // The one who does work is not coloured at all: the style is the
      // theme's, untouched.
      expect(colourOf(tester, 'Mon'), isNot(colours.warning));
    });

    testWidgets('and says nothing at all while it is still asking',
        (tester) async {
      // Without this branch every name in the shop reads "works no
      // hours" for a moment on opening, which is the alarm raised
      // falsely on somebody who works a full week.
      await show(tester, people: [person()], loading: const {'p1'});

      expect(find.text('…'), findsOneWidget);
      expect(find.textContaining('Works no hours'), findsNothing);
    });
  });

  group('the week they work', () {
    Future<void> openWeek(WidgetTester tester) async {
      await tester.tap(find.byTooltip('The week they work'));
      await tester.pumpAndSettle();
    }

    testWidgets('names every day, worked or not', (tester) async {
      await show(
        tester,
        people: [person()],
        weeks: {
          'p1': [hours(weekday: 2, start: '10:30:00', end: '19:15:00')],
        },
      );
      await openWeek(tester);

      expect(find.text('10:30–19:15'), findsOneWidget);
      // Six days not worked, named rather than left out: a week is
      // seven decisions and the blank ones are decisions too.
      expect(find.text('Not worked'), findsNWidgets(6));
      expect(find.text('Monday'), findsOneWidget);
      expect(find.text('Sunday'), findsOneWidget);
    });

    testWidgets('an empty week may be saved, and is warned about',
        (tester) async {
      // Clearing somebody's hours is a thing a manager does on purpose
      // — they have left, or the shop has stopped offering what they
      // do. So it saves, and says what it means.
      await show(tester, people: [person()]);
      await openWeek(tester);

      expect(enabled(tester, const ValueKey('week-save')), isTrue);
      expect(
        find.text('Nobody can be booked with them until a day is '
            'filled in.'),
        findsOneWidget,
      );
    });

    testWidgets('and a filled one is not warned about', (tester) async {
      // The control. Without it, "the warning is there" passes against
      // a dialog that always shows it.
      await show(
        tester,
        people: [person()],
        weeks: {
          'p1': [hours(weekday: 1)],
        },
      );
      await openWeek(tester);

      expect(enabled(tester, const ValueKey('week-save')), isTrue);
      expect(find.textContaining('Nobody can be booked'), findsNothing);
    });

    testWidgets('a half-filled day cannot be saved, and is named',
        (tester) async {
      // Only reachable mid-edit: `weekFromRows` drops a row with no
      // end, so a half-filled day is something somebody makes in this
      // dialog and nothing the table can hand back.
      await show(tester, people: [person()]);
      await openWeek(tester);

      // "From" on Monday, and accept the picker's 09:00.
      await tester.tap(find.text('From').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(find.text('Half filled in'), findsOneWidget);
      expect(find.text('Monday needs both a start and an end.'),
          findsOneWidget);
      expect(enabled(tester, const ValueKey('week-save')), isFalse);

      // And the empty-week warning is NOT also on screen. A week with
      // half a day in it is not an empty week, and two messages
      // disagreeing about what is wrong is worse than one.
      expect(find.textContaining('Nobody can be booked'), findsNothing);
    });

    testWidgets('and clearing the day puts it back', (tester) async {
      // The X removes the day rather than blanking its times, which is
      // the difference between "not worked" and "half filled in" —
      // and the second of those cannot be saved.
      await show(tester, people: [person()]);
      await openWeek(tester);

      await tester.tap(find.text('From').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(enabled(tester, const ValueKey('week-save')), isFalse);

      await tester.tap(find.byTooltip('Not worked').first);
      await tester.pumpAndSettle();

      expect(find.text('Half filled in'), findsNothing);
      // Monday specifically, rather than a count of the word across
      // the dialog: the list is lazy and the seventh day scrolls off
      // the bottom once the empty-week warning takes its space, so a
      // count would be asserting how far the list happened to build.
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Monday'),
          matching: find.text('Not worked'),
        ),
        findsOneWidget,
      );
      expect(enabled(tester, const ValueKey('week-save')), isTrue);
    });
  });

  group('their details', () {
    Future<void> openNew(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('roster-add')));
      await tester.pumpAndSettle();
    }

    testWidgets('need both a name and a code', (tester) async {
      await show(tester);
      await openNew(tester);

      expect(enabled(tester, const ValueKey('provider-save')), isFalse);

      // A name on its own is not enough: the code is unique in the
      // shop and is what the diary and the till print.
      await tester.enterText(
          find.byKey(const ValueKey('provider-name')), 'Siti');
      await tester.pumpAndSettle();
      expect(enabled(tester, const ValueKey('provider-save')), isFalse);

      await tester.enterText(find.widgetWithText(TextField, 'Code'), 'SITI');
      await tester.pumpAndSettle();
      expect(enabled(tester, const ValueKey('provider-save')), isTrue);
    });

    testWidgets('and whitespace is not a name', (tester) async {
      await show(tester);
      await openNew(tester);

      await tester.enterText(
          find.byKey(const ValueKey('provider-name')), '   ');
      await tester.enterText(find.widgetWithText(TextField, 'Code'), 'SITI');
      await tester.pumpAndSettle();

      expect(enabled(tester, const ValueKey('provider-save')), isFalse);
    });

    testWidgets('and an existing person arrives filled in', (tester) async {
      await show(tester, people: [person(name: 'Aminah', code: 'AMI')]);
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Their details'), findsOneWidget);
      expect(find.text('Somebody new'), findsNothing);
      expect(enabled(tester, const ValueKey('provider-save')), isTrue);
    });
  });

  group('when they are away', () {
    Future<void> openAway(WidgetTester tester) async {
      await tester.tap(find.byTooltip('When they are away'));
      await tester.pumpAndSettle();
    }

    testWidgets('nothing can be recorded without both ends',
        (tester) async {
      await show(tester, people: [person()]);
      await openAway(tester);

      expect(enabled(tester, const ValueKey('time-off-add')), isFalse);
      expect(find.text('Time off needs a start and an end.'), findsOneWidget);
    });

    testWidgets('and says so when there has never been any', (tester) async {
      await show(tester, people: [person()]);
      await openAway(tester);

      expect(find.text('Never away.'), findsOneWidget);
    });

    testWidgets('a spell that is over is marked differently from one to '
        'come', (tester) async {
      // Past spells are KEPT rather than tidied away: a booking refused
      // in March was refused for a reason, and this row is the reason.
      // Both on one screen, because one icon on its own says nothing
      // about the other.
      final now = DateTime.now();
      final past = now.subtract(const Duration(days: 40));
      final soon = now.add(const Duration(days: 40));
      String at(DateTime d) => d.toIso8601String();

      await show(
        tester,
        people: [person()],
        timeOff: {
          'p1': [
            away(
              id: 'o-past',
              from: at(past),
              to: at(past.add(const Duration(days: 2))),
              reason: 'Cuti tahun lepas',
            ),
            away(
              id: 'o-soon',
              from: at(soon),
              to: at(soon.add(const Duration(days: 2))),
              reason: 'Cuti akan datang',
            ),
          ],
        },
      );
      await openAway(tester);

      expect(find.text('Cuti tahun lepas'), findsOneWidget);
      expect(find.text('Cuti akan datang'), findsOneWidget);

      // Scoped to the row. The roster dialog underneath carries an
      // `event_busy_outlined` of its own -- the button that opened
      // this one -- so an unscoped finder counts two and would count
      // one on a dialog that marked nothing.
      Finder iconOn(String reason, IconData icon) => find.descendant(
        of: find.widgetWithText(ListTile, reason),
        matching: find.byIcon(icon),
      );

      expect(iconOn('Cuti tahun lepas', Icons.history), findsOneWidget);
      expect(
        iconOn('Cuti akan datang', Icons.event_busy_outlined),
        findsOneWidget,
      );
      // And not the other way round.
      expect(iconOn('Cuti tahun lepas', Icons.event_busy_outlined),
          findsNothing);
      expect(iconOn('Cuti akan datang', Icons.history), findsNothing);
    });
  });
}
