import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/contacts/brought_forward.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';

/// The brought-forward statement, reachable from the screen.
///
/// `0624` built `report_statement_of_account` and tested it in SQL, and
/// for nine months nothing in the app called it. A repository method
/// and a PDF builder that no button reaches is the same amount of dead
/// code as no repository method at all, so these assertions are about
/// the BUTTON: that a customer is offered the choice, that a supplier
/// is not offered a document that does not exist for them, and that
/// choosing it asks the database for the period that was picked.
/// What the screen says once the PDF has actually been built -- either
/// it was saved, or this is not a browser and could not be. Reaching
/// either of them means the document was produced; the refusal above
/// returns before that.
final _produced = RegExp('Downloaded|only available in the browser');

void main() {
  const kinds = [EntityType(code: 'sdn_bhd', label: 'Sdn Bhd', sortOrder: 10)];

  late _FakeRepo repo;

  Widget wrap() => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(id: 'o1', name: 'Kedai Kita', slug: 'kedai'),
      ),
      memberRoleProvider.overrideWith((ref) async => 'owner'),
      allEntityTypesProvider.overrideWith((ref) async => kinds),
      orgLogoProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: ContactEditor(contactId: 'c1')),
    ),
  );

  Future<void> open(
    WidgetTester tester, {
    String contactType = 'customer',
    List<StatementLine>? lines,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 2400);
    addTearDown(tester.view.reset);
    repo = _FakeRepo(contactType: contactType, lines: lines);
    await tester.pumpWidget(wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('a customer is offered both statements', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();

    expect(find.text('What is still unpaid'), findsOneWidget);
    expect(find.text('Everything in a period'), findsOneWidget);
  });

  testWidgets('a supplier is offered only the one that exists', (tester) async {
    // `report_statement_of_account` reads `sales_documents` and
    // `receipts`. Offering a supplier a brought-forward statement would
    // be offering them a document with nothing in it.
    await open(tester, contactType: 'supplier');

    expect(find.byKey(const ValueKey('contact-statement')), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-statement-menu')), findsNothing);
  });

  testWidgets('choosing the period asks the database for it', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in a period'));
    await tester.pumpAndSettle();

    // The picker opens on the period the statement would default to,
    // so somebody who wants this month can simply confirm.
    expect(find.text('Statement period'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repo.askedContactId, 'c1');
    final today = DateTime.now();
    expect(repo.askedFrom, DateTime(today.year, today.month, 1));
    expect(repo.askedTo!.day, today.day);
  });

  testWidgets('and for a period somebody typed, not the default one', (
    tester,
  ) async {
    // The assertion above confirms the picker OPENS on the current
    // month, which is the right suggestion. This one confirms the
    // suggestion is only a suggestion: a statement sent for a period
    // other than the one that was asked for is a wrong document that
    // looks entirely correct.
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in a period'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    // The picker's own fields, found by their labels rather than by
    // position: the contact form behind the dialog is full of text
    // fields, and "the first one in the tree" is one of those.
    await tester.enterText(
      find.widgetWithText(TextField, 'Start Date'),
      '03/04/2026',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End Date'),
      '03/31/2026',
    );
    await tester.pumpAndSettle();
    // Input mode's confirm reads OK; the calendar's reads Save.
    await tester.tap(find.widgetWithText(TextButton, 'OK'));
    await tester.pumpAndSettle();

    expect(repo.askedFrom, DateTime(2026, 3, 4));
    expect(repo.askedTo, DateTime(2026, 3, 31));
  });

  testWidgets('cancelling the picker asks the database for nothing', (
    tester,
  ) async {
    // The old single button fired the moment it was pressed. A picker
    // that reported a period nobody chose would produce a document
    // nobody asked for.
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in a period'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(repo.askedContactId, isNull);
  });

  testWidgets('the open-item statement still works and is a different call', (
    tester,
  ) async {
    // Adding the second document must not have taken the first one
    // away, and the two must not be the same request.
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('What is still unpaid'));
    await tester.pumpAndSettle();

    expect(repo.askedOpenItems, isTrue);
    expect(repo.askedContactId, isNull);
  });

  testWidgets('a statement that does not add up is not produced', (
    tester,
  ) async {
    // The running balance comes down from the database and the page
    // prints it. If it disagrees with the movements beside it, the
    // customer is being asked for a figure nothing on the page
    // explains -- so the screen says so instead of sending it.
    await open(
      tester,
      lines: const [
        StatementLine(
          lineNo: 0,
          entryDate: null,
          kind: 'opening',
          docNo: null,
          dueDate: null,
          currency: null,
          debit: 0,
          credit: 0,
          baseDebit: 0,
          baseCredit: 0,
          balance: 500,
        ),
        StatementLine(
          lineNo: 1,
          entryDate: null,
          kind: 'invoice',
          docNo: 'INV-1',
          dueDate: null,
          currency: null,
          debit: 0,
          credit: 0,
          baseDebit: 1200,
          baseCredit: 0,
          balance: 9999,
        ),
      ],
    );

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in a period'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not agree'), findsOneWidget);
    // And nothing behind it. Reporting the refusal and then producing
    // the document anyway would show both in turn, so the second
    // message has to be waited for rather than assumed absent.
    expect(find.textContaining(_produced), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining(_produced), findsNothing);
  });

  testWidgets('a statement that adds up is produced', (tester) async {
    // The control for the assertion above: same path, honest figures,
    // and the export is reached.
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('contact-statement-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Everything in a period'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining(_produced), findsOneWidget);
  });
}

class _FakeRepo implements Repo {
  _FakeRepo({required this.contactType, List<StatementLine>? lines})
    : lines = lines ?? _sound;

  final String contactType;
  final List<StatementLine> lines;

  String? askedContactId;
  DateTime? askedFrom;
  DateTime? askedTo;
  bool askedOpenItems = false;

  /// 500 brought forward, a 1,200 invoice, a 700 payment, closing at
  /// 1,000 -- which is what the running balance says.
  static const _sound = [
    StatementLine(
      lineNo: 0,
      entryDate: null,
      kind: 'opening',
      docNo: null,
      dueDate: null,
      currency: null,
      debit: 0,
      credit: 0,
      baseDebit: 0,
      baseCredit: 0,
      balance: 500,
    ),
    StatementLine(
      lineNo: 1,
      entryDate: null,
      kind: 'invoice',
      docNo: 'INV-1',
      dueDate: null,
      currency: null,
      debit: 1200,
      credit: 0,
      baseDebit: 1200,
      baseCredit: 0,
      balance: 1700,
    ),
    StatementLine(
      lineNo: 2,
      entryDate: null,
      kind: 'receipt',
      docNo: 'RCP-1',
      dueDate: null,
      currency: null,
      debit: 0,
      credit: 700,
      baseDebit: 0,
      baseCredit: 700,
      balance: 1000,
    ),
  ];

  @override
  Future<Contact> contact(String id) async => Contact(
    id: 'c1',
    code: 'CUST-0004',
    name: 'Bumi Maju Enterprise',
    contactType: contactType,
    entityType: 'sdn_bhd',
  );

  @override
  Future<List<StatementLine>> statementOfAccount({
    required String contactId,
    required DateTime from,
    required DateTime to,
  }) async {
    askedContactId = contactId;
    askedFrom = from;
    askedTo = to;
    return lines;
  }

  @override
  Future<List<BusinessDocument>> outstandingFor({
    required DocKind kind,
    required String contactId,
  }) async {
    askedOpenItems = true;
    return const [];
  }

  /// See `contact_credit_limit_test.dart`: a Dart extension method binds
  /// to the static type, so these are answered here rather than by
  /// overriding the extension.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  @override
  Future<List<Map<String, dynamic>>> groupCompanies() async => const [];

  @override
  Future<List<Map<String, dynamic>>> priceLevels() async => const [];

  @override
  Future<List<Map<String, dynamic>>> states() async => const [];

  @override
  Future<List<Account>> accounts({bool postableOnly = false}) async => const [];

  @override
  Future<Contact> saveContact(Contact contact, {String? id}) async => contact;

  @override
  Future<String> nextContactCode(String contactType) async => 'C-0002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the contact editor called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}
