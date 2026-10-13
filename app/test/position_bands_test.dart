import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/repository.dart';

/// `0863`. A position's salary band is HR's: the database withholds
/// `min_salary` and `max_salary` from every client role and gives them
/// to a member who manages HR through `position_salary_bands`. So the
/// app names the columns it reads, and puts the bands back beside the
/// positions on the one screen that shows them.
void main() {
  test('the columns the app reads are every one but the band', () {
    // A select naming a withheld column is refused outright, and the
    // HR setup list, the hire dialog and the employee editor with it.
    expect(RepoHr.positionColumns, isNot(contains('min_salary')));
    expect(RepoHr.positionColumns, isNot(contains('max_salary')));
    expect(RepoHr.positionColumns, contains('title'));
  });

  group('a band beside its position', () {
    test('where the function named one', () {
      final merged = RepoHr.withPositionBands(
        [
          {'id': 'p1', 'title': 'Finance Manager'},
        ],
        [
          {'position_id': 'p1', 'min_salary': 9000, 'max_salary': 14000},
        ],
      );
      expect(merged.single['min_salary'], 9000);
      expect(merged.single['max_salary'], 14000);
    });

    test('and none -- not nought -- where it did not', () {
      final merged = RepoHr.withPositionBands(
        [
          {'id': 'p1', 'title': 'Finance Manager'},
        ],
        const [],
      );
      expect(merged.single.containsKey('min_salary'), isFalse);
      expect(merged.single['title'], 'Finance Manager');
    });
  });
}
