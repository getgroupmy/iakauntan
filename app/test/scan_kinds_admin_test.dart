import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/platform_live.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/features/admin/platform_console_screen.dart';
import 'package:iakauntan/src/features/admin/scan_kinds_admin.dart';

/// The console page for what AI SmartScan can recognise. `0614`.
///
/// Three kinds of claim, and none of them is about how the page looks:
/// what the form refuses before the database has to, the destinations
/// the page offers against the ones the database was seeded with, and
/// the page being reachable at all — a console page nothing routes to
/// is a page nobody finds, and that failure is silent.
void main() {
  group('what the form refuses', () {
    test('a kind with no name cannot be saved', () {
      expect(
        scanKindProblem(code: 'resit_tol', label: '  ', isNew: true),
        contains('needs a name'),
      );
    });

    test('nor one with no code', () {
      expect(
        scanKindProblem(code: '', label: 'Toll receipt', isNew: true),
        contains('needs a code'),
      );
    });

    test('a code with a space in it says what a code is', () {
      final problem = scanKindProblem(
        code: 'bank statement',
        label: 'Bank statement',
        isNew: true,
      );
      // The words matter as much as the refusal: "invalid" sends
      // somebody back to the field with nothing to try.
      expect(problem, contains('lower-case letters'));
      expect(problem, contains('credit_note'));
    });

    test('and so does one starting with a digit', () {
      expect(
        scanKindProblem(code: '2nd_copy', label: 'Second copy', isNew: true),
        contains('lower-case letters'),
      );
    });

    test('a good one is accepted', () {
      expect(
        scanKindProblem(
          code: 'nota_kredit',
          label: 'Credit note',
          isNew: true,
        ),
        isNull,
      );
    });

    test('an existing kind is not asked about its code again', () {
      // The code is fixed once set — the field is disabled — so
      // checking it on an edit would refuse a save nobody can fix. The
      // name is still checked, because the name is still editable.
      expect(
        scanKindProblem(code: 'not a code', label: 'Renamed', isNew: false),
        isNull,
      );
      expect(
        scanKindProblem(code: 'bill', label: '   ', isNew: false),
        contains('needs a name'),
      );
    });
  });

  group('where a kind can be sent', () {
    test('"filed only" is offered, and is first', () {
      // Three of the kinds this shipped with have no destination. If
      // the list did not offer null, those three could not be edited
      // at all without being given one.
      expect(scanKindDestinations.first.$1, isNull);
    });

    test('the destinations the migration seeded are all offered', () {
      // The seeded rows and this list are written down twice, in SQL
      // and in Dart. `scan_document_kinds.sql` asserts the other
      // direction — that no seeded row names something this list does
      // not have — and together they make the two agree.
      final offered = {for (final d in scanKindDestinations) d.$1};
      expect(offered, containsAll(<String?>{
        'purchase_document',
        'expense',
        'goods_received',
        'bank_import',
        'contact',
      }));
    });

    test('every destination has words to show', () {
      for (final d in scanKindDestinations) {
        expect(d.$2.trim(), isNotEmpty, reason: 'for ${d.$1}');
      }
    });

    test('an unknown destination is shown as itself rather than blank', () {
      // An administrator can type anything into the column through the
      // RPC, and a row the app does not recognise still has to draw.
      expect(scanKindDestinationLabel('mesyuarat'), 'mesyuarat');
      expect(scanKindDestinationLabel('bank_import'), contains('bank'));
      expect(scanKindDestinationLabel(null), contains('Filed only'));
    });
  });

  group('reachable from the console', () {
    test('the page is on the menu', () {
      expect(
        platformConsoleSections.any((s) => s.page is ScanKindsAdminTab),
        isTrue,
      );
    });

    test('under document scanning, beside the readers and the credit', () {
      final section = platformConsoleSections.firstWhere(
        (s) => s.page is ScanKindsAdminTab,
      );
      expect(section.group, 'Document scanning');
      expect(section.path, '/admin/scan-kinds');
    });

    test('and a change made on it reaches the scan somebody has open', () {
      // The console's own list is not enough. The provider the scan
      // result reads is the one that matters, and leaving it out looks
      // — from the administrator's chair — exactly like the save not
      // having worked.
      expect(
        platformLiveProviders('scan_document_kinds'),
        containsAll(<Object>[allScanKindsProvider, offeredScanKindsProvider]),
      );
    });
  });
}
