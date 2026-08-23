import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/corp_models.dart';

/// Which day a statutory deadline is counted against.
///
/// 0305 pinned the server's half of this to `Asia/Kuala_Lumpur`: a
/// deadline under CA 2016 falls on a Malaysian date, and reading
/// `current_date` on a UTC session made the engine a day behind for the
/// eight hours of the Malaysian working morning.
///
/// `CorpFiling.daysLeft` is the client's half of the same question, and
/// it used to read the device clock — so a secretary on a laptop set to
/// London, or a browser reporting UTC, would have seen a different
/// answer from the list the server had just sent them. These assert the
/// sign convention and the boundary, which is where an off-by-one in
/// that arithmetic would show up.
void main() {
  // Malaysia is a fixed UTC+8 with no daylight saving since 1982, which
  // is why the production code can hard-code the offset and why this
  // test can compute the expected day the same way without a time zone
  // database.
  DateTime malaysianToday() {
    final kl = DateTime.now().toUtc().add(const Duration(hours: 8));
    return DateTime(kl.year, kl.month, kl.day);
  }

  CorpFiling due(DateTime on) => CorpFiling(
    entityId: 'e1',
    entityName: 'Tepat Masa Sdn Bhd',
    filingType: 'annual_return',
    filingName: 'Annual Return',
    statuteRef: 'CA 2016 s.68',
    triggerDate: on.subtract(const Duration(days: 30)),
    dueDate: on,
    status: 'due',
  );

  test('a filing due today in Malaysia has no days left, and is not late', () {
    final f = due(malaysianToday());
    expect(f.daysLeft, 0);
    // The boundary that matters. A deadline is missed the day after it
    // falls, not on it — telling a secretary otherwise sends them to
    // argue with SSM about a deadline they have not missed, which is
    // the same rule 0304 applies on the server.
    expect(f.isOverdue, isFalse);
  });

  test('yesterday is late, tomorrow is not', () {
    expect(due(malaysianToday().subtract(const Duration(days: 1))).isOverdue,
        isTrue);
    expect(due(malaysianToday().add(const Duration(days: 1))).isOverdue,
        isFalse);
  });

  test('the count is in whole days either side', () {
    expect(due(malaysianToday().add(const Duration(days: 14))).daysLeft, 14);
    expect(due(malaysianToday().subtract(const Duration(days: 3))).daysLeft,
        -3);
  });

  test('urgent is the fortnight before, and not after it has passed', () {
    // A filing already overdue is not "urgent", it is late, and the two
    // want different words on the screen.
    expect(due(malaysianToday().add(const Duration(days: 14))).isUrgent, isTrue);
    expect(due(malaysianToday().add(const Duration(days: 15))).isUrgent, isFalse);
    expect(due(malaysianToday().subtract(const Duration(days: 1))).isUrgent,
        isFalse);
  });
}
