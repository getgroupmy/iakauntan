import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/csv.dart';
import 'package:iakauntan/src/features/imports/file_shape.dart';
import 'package:iakauntan/src/features/imports/import_screen.dart';
import 'package:iakauntan/src/features/imports/import_template.dart';

/// A blank file with the right headings.
///
/// The thing worth asserting is not that a string was produced. It is
/// that the file this hands somebody is one the importer will actually
/// understand — a template whose headings the importer does not
/// recognise is worse than no template, because the person who fills it
/// in has no reason to doubt it.
///
/// So the test below is a round trip: build the template, then feed its
/// headings back through the same mapper the importer uses.
void main() {
  group('every kind', () {
    test('produces a template the importer recognises, column for column', () {
      for (final kind in ImportKind.values) {
        final columns = importTemplateColumns(kind);
        final map = headerMapper(importColumnsFor(kind));

        expect(
          columns,
          isNotEmpty,
          reason: '${importKindLabel(kind)} has no columns at all',
        );

        for (final column in columns) {
          expect(
            map(column),
            column,
            reason:
                'the ${importKindLabel(kind)} template offers "$column", '
                'which its own importer does not map to itself',
          );
        }
      }
    });

    test('and names every required column', () {
      // A template that omits a required column is a file that cannot
      // import, handed to somebody as though it could.
      const requiredByKind = <ImportKind, List<String>>{
        ImportKind.contacts: ['name'],
        ImportKind.items: ['code', 'name'],
        ImportKind.accounts: ['code', 'name', 'account_subtype'],
      };
      requiredByKind.forEach((kind, required) {
        for (final column in required) {
          expect(
            importTemplateColumns(kind),
            contains(column),
            reason: '${importKindLabel(kind)} must ask for $column',
          );
        }
      });
    });

    test('and gives each kind its own filename', () {
      final names = ImportKind.values.map(importTemplateFilename).toSet();
      // Seven downloads into one folder, and somebody has to tell them
      // apart afterwards.
      expect(names, hasLength(ImportKind.values.length));
      for (final name in names) {
        expect(name, endsWith('.csv'));
      }
    });
  });

  group('the file itself', () {
    test('is one line, and no example row', () {
      // A template carrying a worked example is a template that imports
      // the example — into books that are about to become the real
      // ones. Asserted rather than left to intention.
      for (final kind in ImportKind.values) {
        final csv = importTemplateCsv(kind);
        expect(csv.trim().split('\n'), hasLength(1));
      }
    });

    test('needs no quoting, and would survive it if it did', () {
      // The headings are plain identifiers, so the naive join is
      // correct. This is the assertion that catches somebody adding a
      // column called `unit price (RM)` and quietly breaking the file
      // for every spreadsheet that reads it.
      for (final kind in ImportKind.values) {
        for (final column in importTemplateColumns(kind)) {
          expect(
            column,
            matches(RegExp(r'^[a-z0-9_]+$')),
            reason: '"$column" needs CSV quoting the template does not do',
          );
        }
      }
    });

    test('and round-trips through the CSV parser it will be read by', () {
      for (final kind in ImportKind.values) {
        final parsed = splitCsvLine(importTemplateCsv(kind).trim());
        expect(parsed, importTemplateColumns(kind));
      }
    });
  });
}
