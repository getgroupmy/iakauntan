import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/imports/import_file.dart';
import 'package:iakauntan/src/features/settings/chart_export.dart';

/// The chart leaving, and a file arriving.
///
/// Both halves have one failure mode that is silent, and both are
/// asserted here rather than discovered in somebody's ledger:
///
///   * an export whose columns do not match `import_accounts` is a
///     backup nobody can restore;
///   * a CSV that is not UTF-8 decoded leniently puts a black diamond
///     in a customer's name and leaves it there for ever.
void main() {
  Account account(
    String code,
    String name, {
    String type = 'expense',
    String subtype = 'operating_expense',
    bool group = false,
    bool active = true,
    double balance = 0,
  }) => Account(
    id: code,
    code: code,
    name: name,
    accountType: type,
    accountSubtype: subtype,
    isGroup: group,
    isActive: active,
    currentBalance: balance,
  );

  group('the chart as a file', () {
    test('the header is what the importer reads', () {
      // 0550's importer takes code, name, account_type, account_subtype,
      // parent_code, description, is_group. Everything the export writes
      // that the importer takes has to be spelled its way, or a chart
      // exported here does not go back in.
      final header = chartOfAccountsCsv([account('8000', 'X')]).split('\n').first;
      expect(header.split(','), containsAll(<String>[
        'code',
        'name',
        'account_type',
        'account_subtype',
        'is_group',
      ]));
    });

    test('a row carries the account', () {
      final csv = chartOfAccountsCsv([
        account('4000', 'Sales', type: 'revenue', subtype: 'sales',
            balance: 1234.5),
      ]);
      expect(csv, contains('4000,Sales,revenue,sales,false,true,1234.50'));
    });

    test('sorted by code, so a heading precedes its accounts', () {
      // The importer refuses a parent that comes after the account
      // using it. Exporting in any other order would produce a file
      // this product cannot read back.
      final csv = chartOfAccountsCsv([
        account('8010', 'Fuel'),
        account('8000', 'Motor vehicle expenses', group: true),
      ]);
      final lines = csv.trim().split('\n');
      expect(lines[1], startsWith('8000,'));
      expect(lines[2], startsWith('8010,'));
    });

    test('a name with a comma survives the round trip', () {
      final csv = chartOfAccountsCsv([
        account('6100', 'Rent, rates and insurance'),
      ]);
      expect(csv, contains('"Rent, rates and insurance"'));
    });

    test('and one with a quotation mark', () {
      expect(csvField('The "old" account'), '"The ""old"" account"');
    });

    test('a plain name is not quoted for nothing', () {
      expect(csvField('Fuel'), 'Fuel');
    });

    test('the filename carries the company and the day', () {
      final name = chartExportFilename('Sinar Teknologi Sdn Bhd',
          DateTime(2026, 3, 7));
      expect(name, 'sinar-teknologi-sdn-bhd-chart-of-accounts-2026-03-07.csv');
    });

    test('and a company with no name still produces a file', () {
      expect(chartExportFilename(null, DateTime(2026, 1, 1)),
          'chart-chart-of-accounts-2026-01-01.csv');
    });
  });

  group('a file somebody uploads', () {
    Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

    test('a UTF-8 file is read', () {
      final read = readImportFile(bytes('code,name\n8000,Fuel\n'));
      expect(read.problem, isNull);
      expect(read.text, contains('8000,Fuel'));
    });

    test('a byte-order mark is stripped', () {
      // Excel writes one. Left in place it becomes an invisible
      // character on the front of the first heading, so `code` stops
      // matching `code` and every row is missing its account number for
      // a reason nobody can see.
      final withBom = Uint8List.fromList(
          [0xEF, 0xBB, 0xBF, ...utf8.encode('code,name\n8000,Fuel\n')]);
      final read = readImportFile(withBom);
      expect(read.problem, isNull);
      expect(read.text!.startsWith('code'), isTrue);
    });

    test('a file that is not UTF-8 is refused, not read leniently', () {
      // 0xC0 is not valid UTF-8. This is what Excel's plain "CSV"
      // produces for a name like Ünal on a Windows machine. Decoded
      // leniently it becomes U+FFFD and lands in the database.
      final cp1252 = Uint8List.fromList([
        ...utf8.encode('code,name\n8000,'),
        0xDC, // Ü in code page 1252
        ...utf8.encode('nal\n'),
      ]);
      final read = readImportFile(cp1252, name: 'suppliers.csv');
      expect(read.text, isNull);
      expect(read.problem, contains('not UTF-8'));
      expect(read.problem, contains('CSV UTF-8'));
      expect(read.problem, contains('suppliers.csv'));
    });

    test('an empty file says so', () {
      expect(readImportFile(Uint8List(0)).problem, contains('empty'));
    });

    test('a file of whitespace says so too', () {
      expect(readImportFile(bytes('   \n\n')).problem, contains('nothing'));
    });

    test('a file past the limit is refused with its size', () {
      final big = Uint8List(importFileLimit + 1);
      final read = readImportFile(big);
      expect(read.text, isNull);
      expect(read.problem, contains('2 MB'));
    });

    test('and one at the limit is not', () {
      // The boundary itself is allowed. A limit that refused the exact
      // size it names is a limit nobody can satisfy.
      final atLimit = Uint8List.fromList(
        utf8.encode('a\n'.padRight(importFileLimit, 'x')),
      );
      expect(atLimit.length, importFileLimit);
      expect(readImportFile(atLimit).problem, isNull);
    });
  });
}
