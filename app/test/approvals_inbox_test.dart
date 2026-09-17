import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/features/approvals/approvals_screen.dart';

/// The approvals inbox, and where a request takes you.
///
/// Two things live only in this widget.
///
/// The first is WHERE TAPPING A REQUEST GOES. Somebody approving a
/// document is signing for it, and a tile that opens the wrong one --
/// or opens a purchase order under a sales route -- means signing
/// having read something else. `_route` switches on `entity_kind` and
/// interpolates `doc_type`, and neither the SQL suite nor the router's
/// own tests can see that switch.
///
/// The second is that the Rules tab is HIDDEN from somebody who cannot
/// set rules. The screen's own comment gives the reason and it is not
/// secrecy: "a control somebody cannot use is a control that teaches
/// them to ignore controls".
void main() {
  Map<String, dynamic> request({
    String id = 'e1',
    String kind = 'sales_document',
    String? docType = 'invoice',
    String docNo = 'INV-001',
    num amount = 1200,
    String by = 'Aminah',
    int step = 1,
  }) => {
    'entity_id': id,
    'entity_kind': kind,
    'doc_type': docType,
    'doc_no': docNo,
    'amount': amount,
    'requested_by_name': by,
    'requested_at': '2026-01-14T09:00:00Z',
    'step_no': step,
  };

  late GoRouter router;

  Widget wrap(
    List<Map<String, dynamic>> inbox, {
    bool canAdmin = false,
  }) {
    router = GoRouter(
      initialLocation: '/approvals',
      routes: [
        GoRoute(
          path: '/approvals',
          builder: (_, __) => const ApprovalsScreen(),
        ),
        GoRoute(
          path: '/sales/:type/:id',
          builder: (_, __) => const Scaffold(body: Text('a sales document')),
        ),
        GoRoute(
          path: '/purchases/:type/:id',
          builder: (_, __) =>
              const Scaffold(body: Text('a purchase document')),
        ),
        GoRoute(
          path: '/journals',
          builder: (_, __) => const Scaffold(body: Text('the journal list')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        myApprovalsProvider.overrideWith((ref) async => inbox),
        canAdminProvider.overrideWithValue(canAdmin),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  String where() => router.routerDelegate.currentConfiguration.uri.toString();

  group('where a request takes you', () {
    testWidgets('a sales document opens under its own type', (tester) async {
      await tester.pumpWidget(wrap([request(id: 'abc', docType: 'invoice')]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('INV-001'));
      await tester.pumpAndSettle();

      // The type is interpolated, so a quotation and an invoice do not
      // land on the same page.
      expect(where(), '/sales/invoice/abc');
    });

    testWidgets('and a purchase document under the purchases route', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap([
          request(
            id: 'def',
            kind: 'purchase_document',
            docType: 'bill',
            docNo: 'BILL-9',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('BILL-9'));
      await tester.pumpAndSettle();

      // The control that matters: a bill routed to /sales/bill/def
      // opens a document this company does not have, or worse, one it
      // does.
      expect(where(), '/purchases/bill/def');
    });

    testWidgets('a journal goes to the list, because there is no page for one',
        (tester) async {
      await tester.pumpWidget(
        wrap([
          request(id: 'ghi', kind: 'journal', docType: null, docNo: 'JV-4'),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('JV-4'));
      await tester.pumpAndSettle();

      expect(where(), '/journals');
    });

    testWidgets('and something with nowhere to go is not tappable at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap([
          request(id: 'jkl', kind: 'something_new', docNo: 'X-1'),
        ]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('X-1'));
      await tester.pumpAndSettle();

      // A tile that silently goes nowhere is better than one that
      // guesses a route. Still on the inbox.
      expect(where(), '/approvals');
    });

    testWidgets('a sales document with no type is not tappable either', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap([request(id: 'mno', docType: null, docNo: 'Y-1')]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Y-1'));
      await tester.pumpAndSettle();

      // `/sales//mno` is not a route, and a null interpolated into a
      // path is the kind of thing that 404s in front of somebody
      // holding a document to sign.
      expect(where(), '/approvals');
    });
  });

  group('what the tile says before you open it', () {
    testWidgets('who raised it, when, which step, and how much', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap([request(by: 'Encik Rahman', step: 2, amount: 4500)]),
      );
      await tester.pumpAndSettle();

      // Enough to decide whether to open it at all, and the step
      // number because the same document comes back at each one.
      expect(find.textContaining('Raised by Encik Rahman'), findsOneWidget);
      expect(find.textContaining('step 2'), findsOneWidget);
      expect(find.textContaining('RM 4,500.00'), findsOneWidget);
    });

    testWidgets('and an empty inbox says so rather than showing nothing', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const []));
      await tester.pumpAndSettle();

      expect(find.text('Nothing to approve'), findsOneWidget);
    });
  });

  group('the rules tab', () {
    testWidgets('is not offered to somebody who cannot set rules', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(const []));
      await tester.pumpAndSettle();

      // Not secrecy: a control somebody cannot use is a control that
      // teaches them to ignore controls.
      expect(find.text('Rules'), findsNothing);
      expect(find.text('My inbox'), findsOneWidget);
    });

    testWidgets('and is offered to an administrator', (tester) async {
      await tester.pumpWidget(wrap(const [], canAdmin: true));
      await tester.pumpAndSettle();

      // The control. Without it, a tab bar that never showed Rules
      // would pass the assertion above.
      expect(find.text('Rules'), findsOneWidget);
    });
  });
}
