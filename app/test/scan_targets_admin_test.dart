import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/scan_kinds_repository.dart';
import 'package:iakauntan/src/data/scan_targets_repository.dart';
import 'package:iakauntan/src/features/admin/scan_kinds_admin.dart';

/// Where a scanned paper goes, and what it fills. `0681`.
///
/// Until now a kind of document named a SCREEN in free text, so every
/// document ever scanned was asked the same eleven questions out of one
/// hard-coded schema in the edge function — whether it was a bill, a
/// bank statement or a name card. A kind now names a module and an
/// action, and the fields on offer are the real columns of the table
/// that action writes.
///
/// The claims worth the most here are the ones about NOT lying:
///
///   * a column that was ticked and has since been dropped is shown,
///     not hidden, or somebody wonders where their configuration went;
///   * a target with nothing ticked says so, because it is silently
///     left out of what the reader is sent;
///   * and a foreign key is offered and marked rather than hidden —
///     `contact_id` cannot be read off a page, and it is still the only
///     place "the supplier as printed" can hang.
void main() {
  ScanTarget target({
    String module = 'purchases',
    String action = 'bill',
    String label = "A supplier's bill",
    String table = 'purchase_documents',
    String? moduleName = 'Purchasing',
    String? hint = 'Becomes a bill, with the supplier and the lines.',
  }) => ScanTarget(
    module: module,
    action: action,
    label: label,
    tableName: table,
    moduleName: moduleName,
    hint: hint,
  );

  ScanTargetColumn column({
    String name = 'doc_no',
    String type = 'text',
    bool required = false,
    bool foreign = false,
    bool asked = false,
    bool stillThere = true,
    String? description,
  }) => ScanTargetColumn(
    name: name,
    dataType: type,
    isRequired: required,
    isForeign: foreign,
    isAsked: asked,
    stillThere: stillThere,
    description: description,
  );

  group('the target a kind points at', () {
    test('a module and an action make a key', () {
      const k = ScanKind(
        code: 'bill',
        label: "Supplier's bill",
        targetModule: 'purchases',
        targetAction: 'bill',
      );
      expect(k.targetKey, 'purchases.bill');
    });

    // Half a target is not a target — the database refuses one, and
    // reading one here as a key would send the console asking for
    // columns of a table nobody named.
    test('half of one is not a key', () {
      expect(
        const ScanKind(code: 'x', label: 'X', targetModule: 'purchases')
            .targetKey,
        isNull,
      );
      expect(const ScanKind(code: 'x', label: 'X').targetKey, isNull);
    });
  });

  group('reading a column off the wire', () {
    test('a ticked column arrives whole', () {
      final c = ScanTargetColumn.fromJson(const {
        'column_name': 'doc_no',
        'data_type': 'text',
        'is_required': true,
        'is_foreign': false,
        'is_asked': true,
        'still_there': true,
        'description': "The supplier's own bill number.",
        'sort_order': 10,
      });
      expect(c.name, 'doc_no');
      expect(c.isRequired, isTrue);
      expect(c.isAsked, isTrue);
      expect(c.description, "The supplier's own bill number.");
    });

    // A blank description is no description. Stored as '' it would read
    // as a question that had been written, and nobody would go back and
    // write one.
    test('a blank description is none', () {
      expect(column(description: null).description, isNull);
      expect(
        ScanTargetColumn.fromJson(const {
          'column_name': 'x',
          'description': '   ',
        }).description,
        isNull,
      );
    });

    // Absent must read as present. A database that does not send the
    // column would otherwise mark every field as dropped and paint the
    // whole list red.
    test('a missing still_there reads as still there', () {
      expect(
        ScanTargetColumn.fromJson(const {'column_name': 'x'}).stillThere,
        isTrue,
      );
    });
  });

  group('what the reader answers with', () {
    test('the target and its fields arrive on the extraction', () {
      final e = OcrExtraction.fromJson(const {
        'supplier_name': 'Lim Hardware',
        'target': 'purchases.bill',
        'fields': {'doc_no': 'INV-9912', 'doc_date': '03/09/2026'},
      });
      expect(e.target, 'purchases.bill');
      expect(e.fields['doc_no'], 'INV-9912');
      // Left as printed. `03/09/2026` is not a date until somebody who
      // knows the column decides which way round it is.
      expect(e.fields['doc_date'], '03/09/2026');
    });

    // Every reading before 0681, every phone scan, and every platform
    // with no targets configured. It must read as "nobody asked",
    // never as "asked and found nothing".
    test('a reading with no target is empty, not broken', () {
      final e = OcrExtraction.fromJson(const {'supplier_name': 'Lim'});
      expect(e.target, isNull);
      expect(e.fields, isEmpty);
      expect(e.toJson().containsKey('fields'), isFalse);
    });

    test('empty values are dropped rather than stored as blanks', () {
      final e = OcrExtraction.fromJson(const {
        'fields': {'doc_no': '  ', 'total': 'RM 12.00'},
      });
      expect(e.fields.containsKey('doc_no'), isFalse);
      expect(e.fields['total'], 'RM 12.00');
    });
  });

  group('the picker', () {
    Widget harness(
      List<ScanTarget> targets,
      List<ScanTargetColumn> columns, {
      String? value = 'purchases.bill',
    }) => ProviderScope(
      overrides: [
        scanTargetsProvider.overrideWith((ref) async => targets),
        scanTargetColumnsProvider.overrideWith((ref, t) async => columns),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ScanKindTargetPicker(
              value: value,
              enabled: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    testWidgets('lists the real columns of the table', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [
          column(name: 'doc_no', asked: true, description: 'The number.'),
          column(name: 'doc_date', type: 'date'),
          column(name: 'contact_id', foreign: true),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('doc_no'), findsOneWidget);
      expect(find.text('doc_date'), findsOneWidget);
      expect(find.text('contact_id'), findsOneWidget);
      // Said, so nobody goes hunting for the table name.
      expect(
        find.textContaining('purchase_documents'),
        findsOneWidget,
      );
    });

    testWidgets('a foreign key is offered and marked', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [column(name: 'contact_id', foreign: true)]),
      );
      await tester.pumpAndSettle();

      // `StatusChip` runs its words through `Fmt.label`.
      expect(find.text('Matched by name'), findsOneWidget);
    });

    testWidgets('a target with nothing ticked says it is not offered', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [column(name: 'doc_no')]),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('not offered to the reader at all'),
        findsOneWidget,
      );
    });

    testWidgets('a column ticked and since dropped is shown, not hidden', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [
          column(name: 'doc_no', asked: true),
          column(name: 'a_column_from_last_year', asked: true,
              stillThere: false),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('no longer in the table'),
        findsOneWidget,
      );
      expect(find.text('No longer a column'), findsOneWidget);
    });

    testWidgets('only a ticked field asks how to ask for it', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [
          column(name: 'doc_no', asked: true),
          column(name: 'doc_date'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('scan-field-why-doc_no')),
        findsOneWidget,
      );
      // A box under every column of a wide table is a form nobody reads.
      expect(
        find.byKey(const ValueKey('scan-field-why-doc_date')),
        findsNothing,
      );
    });

    testWidgets('saving is off until something is changed', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [column(name: 'doc_no', asked: true)]),
      );
      await tester.pumpAndSettle();

      final save = find.byKey(const ValueKey('scan-kind-save-fields'));
      expect(tester.widget<ButtonStyleButton>(save).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('scan-field-doc_no')));
      await tester.pumpAndSettle();
      expect(tester.widget<ButtonStyleButton>(save).onPressed, isNotNull);
    });

    // One module, one action: the second dropdown is a control with one
    // choice, which is a control that asks a question it has already
    // answered.
    testWidgets('a module with one action does not ask which', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness([target()], const []));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-kind-module')), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-kind-action')), findsNothing);
    });

    testWidgets('a module with several does', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([
          target(),
          target(action: 'purchase_order', label: 'A purchase order'),
        ], const []),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-kind-action')), findsOneWidget);
    });

    testWidgets('no target means no field list at all', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness([target()], [column(name: 'doc_no')], value: null),
      );
      await tester.pumpAndSettle();

      expect(find.text('doc_no'), findsNothing);
      expect(
        find.text('Filed only — nothing is created'),
        findsOneWidget,
      );
    });
  });
}
