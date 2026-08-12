import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/csv.dart';

/// The parser both importers now share. The quoting rules are what
/// matter: get them wrong and a description containing a comma shifts
/// every column after it, which reads as data rather than as an error.
void main() {
  group('splitting a line', () {
    test('a comma inside quotes is part of the field', () {
      expect(splitCsvLine('C-001,"Alpha Trading, Sdn Bhd",customer'),
          ['C-001', 'Alpha Trading, Sdn Bhd', 'customer']);
    });

    test('a doubled quote is one literal quote', () {
      expect(splitCsvLine('A,"He said ""hello""",B'),
          ['A', 'He said "hello"', 'B']);
    });

    test('tabs separate too, because that is what pasting gives you', () {
      expect(splitCsvLine('A\tB\tC'), ['A', 'B', 'C']);
    });

    test('an empty trailing field is a field', () {
      expect(splitCsvLine('A,B,'), ['A', 'B', '']);
    });
  });

  group('reading a table', () {
    final fields = headerMapper(const {
      'code': ['customer code'],
      'name': ['company'],
      'credit_limit': ['limit'],
    });

    test('headers are matched however they are spelled', () {
      final t = parseCsvTable('Customer Code,Company,Limit\nC-1,Alpha,500', fields);
      expect(t.problems, isEmpty);
      expect(t.rows.single,
          {'code': 'C-1', 'name': 'Alpha', 'credit_limit': '500'});
    });

    test('a column nothing understands is ignored, not fatal', () {
      // A file exported from another system carries columns this one has
      // no use for. Refusing it would be a reason to give up on the
      // import rather than a reason to fix anything.
      final t = parseCsvTable(
          'code,name,salesperson\nC-1,Alpha,Ahmad', fields);
      expect(t.problems, isEmpty);
      expect(t.rows.single.containsKey('salesperson'), isFalse);
      expect(t.rows.single['name'], 'Alpha');
    });

    test('but a header nothing understands at all is', () {
      final t = parseCsvTable('foo,bar\n1,2', fields);
      expect(t.rows, isEmpty);
      expect(t.problems.single, contains('recognised'));
    });

    test('the same column twice is called out', () {
      // One of them silently wins, and which one depends on column
      // order.
      final t = parseCsvTable('code,name,Customer Code\nC-1,Alpha,C-2', fields);
      expect(t.problems.single, contains('more than once'));
    });

    test('a blank cell is absent rather than empty', () {
      // The database treats a missing key as "not given" and applies a
      // default; an empty string would be a value.
      final t = parseCsvTable('code,name,limit\nC-1,Alpha,', fields);
      expect(t.rows.single.containsKey('credit_limit'), isFalse);
    });

    test('a header on its own is not a file', () {
      expect(parseCsvTable('code,name', fields).problems, isNotEmpty);
      expect(parseCsvTable('', fields).problems, isNotEmpty);
    });

    test('a row of nothing is skipped', () {
      final t = parseCsvTable('code,name\nC-1,Alpha\n,\n', fields);
      expect(t.rows, hasLength(1));
    });
  });
}
