import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/einvoice/received_einvoice.dart';
import 'package:iakauntan/src/features/einvoice/received_einvoices_screen.dart';

/// The screen over `0650`, wired to a repository that answers.
///
/// `received_einvoice_test.dart` asserts the rules; this asserts that
/// the screen is actually joined to them -- that the list it draws came
/// from the repository, that the filter it offers is sent, and that the
/// menu on a row reflects what `draftBillProblem` says rather than
/// offering a button the database will refuse.
///
/// The last of those is the one worth having. A disabled item whose
/// label is still "Draft a bill" would pass any assertion about the
/// item EXISTING, and would tell somebody nothing about why pressing it
/// does nothing.
void main() {
  Widget wrap(Repo repo) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(id: 'o1', name: 'Kedai Kita', slug: 'kedai'),
      ),
      memberRoleProvider.overrideWith((ref) async => 'owner'),
      orgLogoProvider.overrideWith((ref) async => null),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const ReceivedEinvoicesScreen(),
    ),
  );

  Future<void> show(WidgetTester t, Repo repo) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1400, 2000);
    addTearDown(t.view.reset);
    await t.pumpWidget(wrap(repo));
    await t.pump();
  }

  testWidgets('a list on its way is outlined, not spun', (t) async {
    await show(t, _Never());

    // `ListSkeleton` draws outlined `ListTile`s and carries no keys, so
    // the assertion is on the shape: rows, and no circle. The control
    // for it is the next test, where the same finder must produce a
    // list that came from the repository -- without that pair, a screen
    // stuck on bones forever would pass this one.
    expect(find.byType(ListTile), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // And nothing from the data branch has been drawn.
    expect(find.byKey(const ValueKey('received-r1')), findsNothing);
  });

  testWidgets('what arrived is drawn from what the repository answered', (
    t,
  ) async {
    final repo = _Answers();
    await show(t, repo);
    await t.pump();

    expect(find.text('Pembekal Jaya Sdn Bhd · INV-9001'), findsOneWidget);
    expect(find.byKey(const ValueKey('received-r1')), findsOneWidget);
    // And it asked for everything, which is what the default filter
    // means. A screen that quietly asked for one status would show a
    // short list with no way to tell.
    expect(repo.askedFor, ['all']);
  });

  testWidgets('an empty list explains what the screen is for', (t) async {
    // Not a blank page. Nothing has arrived yet is the state every
    // company starts in, and it is the one moment somebody needs to be
    // told how a document gets here.
    await show(t, _Answers(rows: const []));
    await t.pump();

    expect(find.textContaining('Nothing has arrived yet'), findsOneWidget);
    expect(find.textContaining('import the file here'), findsOneWidget);
  });

  testWidgets('choosing a filter asks the repository for that status', (
    t,
  ) async {
    final repo = _Answers();
    await show(t, repo);
    await t.pump();

    await t.tap(find.byKey(const ValueKey('received-filter-billed')));
    await t.pump();
    await t.pump();

    expect(repo.askedFor, ['all', 'billed']);
  });

  testWidgets('a document with no supplier says so on the row', (t) async {
    // `0650` matches by TIN and never by name, so this is the ordinary
    // state of a document from a supplier not yet on file -- and the
    // TIN is what somebody will search the contact list with.
    await show(t, _Answers());
    await t.pump();

    expect(find.textContaining('C1234567890'), findsOneWidget);
  });

  testWidgets('the menu says WHY a bill cannot be drafted', (t) async {
    await show(t, _Answers());
    await t.pump();

    await t.tap(find.byKey(const ValueKey('received-menu-r1')));
    await t.pumpAndSettle();

    // The reason is the label. Not "Draft a bill", greyed out, which
    // says nothing.
    expect(find.text('Link a supplier to this document first.'), findsOneWidget);
    expect(find.text('Draft a bill'), findsNothing);
    // And the action that WOULD fix it is offered.
    expect(find.text('Create and link supplier'), findsOneWidget);
  });

  testWidgets('and offers the draft once a supplier is linked', (t) async {
    // The control for the assertion above: without it, a menu that
    // never offered the draft at all would pass it.
    await show(
      t,
      _Answers(
        rows: [
          const ReceivedEinvoice(
            id: 'r2',
            status: 'received',
            docNo: 'INV-9002',
            typeCode: '01',
            currency: 'MYR',
            supplierName: 'Pembekal Jaya Sdn Bhd',
            contactId: 'c1',
            contactName: 'Pembekal Jaya Sdn Bhd',
            payableAmount: 212,
          ),
        ],
      ),
    );
    await t.pump();

    await t.tap(find.byKey(const ValueKey('received-menu-r2')));
    await t.pumpAndSettle();

    expect(find.text('Draft a bill'), findsOneWidget);
    // Nothing to fix, so nothing is offered to fix it.
    expect(find.text('Create and link supplier'), findsNothing);
  });

  testWidgets('a credit note offers a credit note, not a bill', (t) async {
    await show(
      t,
      _Answers(
        rows: [
          const ReceivedEinvoice(
            id: 'r3',
            status: 'received',
            typeCode: '02',
            currency: 'MYR',
            contactId: 'c1',
            supplierName: 'Pembekal Jaya Sdn Bhd',
          ),
        ],
      ),
    );
    await t.pump();

    await t.tap(find.byKey(const ValueKey('received-menu-r3')));
    await t.pumpAndSettle();

    expect(find.text('Draft a purchase credit note'), findsOneWidget);
  });

  testWidgets('a document already billed is not offered again', (t) async {
    await show(
      t,
      _Answers(
        rows: [
          const ReceivedEinvoice(
            id: 'r4',
            status: 'billed',
            typeCode: '01',
            currency: 'MYR',
            contactId: 'c1',
            billId: 'b1',
            supplierName: 'Pembekal Jaya Sdn Bhd',
          ),
        ],
      ),
    );
    await t.pump();

    await t.tap(find.byKey(const ValueKey('received-menu-r4')));
    await t.pumpAndSettle();

    expect(
      find.text('A bill has already been drafted from this document.'),
      findsOneWidget,
    );
  });

  testWidgets('the import button is there and is not the only way in', (
    t,
  ) async {
    await show(t, _Answers());
    await t.pump();

    expect(find.byKey(const ValueKey('received-import')), findsOneWidget);
    // Set aside is on every row whatever its state, because "this was
    // not for us" applies to a document nothing else can be done with.
    //
    // Scoped to the MENU. A bare `find.text` matches twice: the filter
    // chip for documents already set aside carries the same two words
    // as the action that sets one aside. The two are a state and a
    // verb, they read correctly in their own places, and the finder is
    // what should be narrower -- renaming a control so a matcher can
    // find it is the wrong way round.
    await t.tap(find.byKey(const ValueKey('received-menu-r1')));
    await t.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<String>, 'Set aside'),
      findsOneWidget,
    );
  });
}

/// A repository whose every answer is still on the way.
class _Never implements Repo {
  @override
  Future<List<ReceivedEinvoice>> receivedEinvoices({String? status}) =>
      Completer<List<ReceivedEinvoice>>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}

/// A repository that answers, and remembers what it was asked.
class _Answers implements Repo {
  _Answers({List<ReceivedEinvoice>? rows}) : rows = rows ?? _default;

  static const _default = [
    ReceivedEinvoice(
      id: 'r1',
      status: 'received',
      docNo: 'INV-9001',
      typeCode: '01',
      currency: 'MYR',
      supplierName: 'Pembekal Jaya Sdn Bhd',
      supplierTin: 'C1234567890',
      payableAmount: 212,
      lineCount: 2,
    ),
  ];

  final List<ReceivedEinvoice> rows;

  /// Every status the screen asked for, in order.
  final List<String> askedFor = [];

  @override
  Future<List<ReceivedEinvoice>> receivedEinvoices({String? status}) async {
    askedFor.add(status ?? 'all');
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
