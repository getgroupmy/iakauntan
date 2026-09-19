/// One to-do, read rather than edited.
///
/// Reported as: the to-do list is not in the menu, and the list page
/// should show the list AND the details of the item.
///
/// The menu half is a row in `app_shell.dart` and a route that has
/// existed since `0526`. The detail half is this file, and what is
/// worth asserting about it is which facts appear:
///
///   * ABSENT FACTS ARE ABSENT. A panel with "Due: —", "About: —" and
///     "Priority: Normal" on every item teaches somebody that most of
///     it is blank and to stop reading. The old dialog's failing was
///     the opposite one — every field as a box, whether or not it said
///     anything — and copying that into a reading pane would have made
///     the detail a form that cannot be typed in.
///   * NORMAL IS NOT A FACT. It is what an item is unless somebody
///     chose otherwise.
///   * OVERDUE IS STRICTLY BEFORE TODAY, which is `Todo.isOverdue`'s
///     rule and is asserted here through the panel because that is
///     where somebody reads it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/dashboard/todo_detail.dart';
import 'package:iakauntan/src/features/dashboard/todos_screen.dart';

void main() {
  final today = DateTime(2026, 9, 19);

  Todo todo({
    String title = 'Chase the Ramli invoice',
    String? notes,
    DateTime? due,
    String priority = 'normal',
    DateTime? doneAt,
    String? link,
    String? contactId,
    String? contactName,
  }) => Todo(
    id: 't1',
    title: title,
    notes: notes,
    dueDate: due,
    priority: priority,
    doneAt: doneAt,
    link: link,
    contactId: contactId,
    contactName: contactName,
  );

  Map<String, String> facts(Todo t) => {
    for (final f in todoFacts(t, today)) f.label: f.value,
  };

  group('what the panel says', () {
    test('a bare item says only that it is open', () {
      expect(facts(todo()), {'Status': 'Open'});
    });

    test('a due date appears, and nothing else invents itself', () {
      expect(facts(todo(due: DateTime(2026, 9, 30))).keys, ['Status', 'Due']);
    });

    test('normal priority is not a fact', () {
      // It is what every item is unless somebody chose otherwise, and a
      // row saying so on all of them is a row nobody reads.
      expect(facts(todo()).containsKey('Priority'), isFalse);
      expect(facts(todo(priority: 'high'))['Priority'], 'High');
      expect(facts(todo(priority: 'low'))['Priority'], 'Low');
    });

    test('an item due before today is overdue, in two places', () {
      final f = facts(todo(due: DateTime(2026, 9, 18)));
      expect(f['Status'], 'Overdue');
      expect(f['Due'], contains('past'));
    });

    test('and one due today is not', () {
      // `Todo.isOverdue` is strict, deliberately: colouring an item red
      // at one minute past midnight on the day it is due is how a list
      // trains somebody to ignore the colour.
      final f = facts(todo(due: today));
      expect(f['Status'], 'Open');
      expect(f['Due'], isNot(contains('past')));
    });

    test('a cleared item says when, and is not overdue', () {
      final f = facts(
        todo(due: DateTime(2026, 9, 1), doneAt: DateTime(2026, 9, 5)),
      );
      expect(f['Status'], startsWith('Done '));
      expect(f['Due'], isNot(contains('past')));
    });
  });

  group('who it is about', () {
    test('the party appears by name', () {
      expect(
        facts(todo(contactId: 'c1', contactName: 'Ramli Enterprise'))['About'],
        'Ramli Enterprise',
      );
    });

    test('and still appears before the name has been read', () {
      // The name is fetched separately from the row, so there is a
      // moment where the item is about somebody whose name is not in
      // hand. Hiding the row until it lands would make the panel jump.
      expect(facts(todo(contactId: 'c1'))['About'], 'A contact');
    });

    test('an item about nobody has no About row at all', () {
      expect(facts(todo()).containsKey('About'), isFalse);
      // And a name with no id does not conjure one — that combination
      // means a stale name, not a party.
      expect(
        facts(todo(contactName: 'Ramli Enterprise')).containsKey('About'),
        isFalse,
      );
    });

    test('a route is shown separately from a party', () {
      // `0526`'s `link` is a SCREEN and `0656`'s contact is a PARTY.
      // One item can carry both, and collapsing them would make
      // "chase Ramli, and here is the invoice" into one of the two.
      final f = facts(
        todo(
          contactId: 'c1',
          contactName: 'Ramli Enterprise',
          link: '/sales/invoice/abc',
        ),
      );
      expect(f['About'], 'Ramli Enterprise');
      expect(f['Goes to'], '/sales/invoice/abc');
    });

    test('and an empty route is no route', () {
      expect(facts(todo(link: '')).containsKey('Goes to'), isFalse);
    });
  });

  group('where the detail is drawn', () {
    test('beside the list on a window with room', () {
      expect(detailBeside(1280), isTrue);
      expect(detailBeside(820), isTrue);
    });

    test('and as a page on one without', () {
      // A phone, and a narrow window on a desktop. Two columns neither
      // of which can be read is worse than one that can.
      expect(detailBeside(430), isFalse);
      expect(detailBeside(819), isFalse);
    });
  });
}
