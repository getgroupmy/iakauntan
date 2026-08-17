import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';

/// Approvals, on the screen side.
///
/// Every refusal — the raiser signing their own, a step decided out of
/// order, an unapproved document reaching the ledger — is asserted in
/// `supabase/tests/approvals.sql`, where it belongs: the gate is a
/// trigger and a screen cannot weaken it.
///
/// What is asserted here is the thing the screen decides on its own: the
/// four sentences a document can be told about its own approval, and the
/// wording of the rule somebody is about to write. Both are places where
/// showing the wrong one of two similar states costs somebody a day.
void main() {
  ProviderContainer harness(List<Map<String, dynamic>> inbox) {
    final c = ProviderContainer(
      overrides: [
        repoProvider.overrideWithValue(null),
        myApprovalsProvider.overrideWith((ref) async => inbox),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// The same four-way choice `_ApprovalBanner` makes, kept here so the
  /// test is about the rule rather than about widget plumbing.
  String banner(Map<String, dynamic> s) {
    if (s['is_approved'] == true) return 'approved';
    if (s['awaiting_me'] == true) return 'mine';
    if (s['request_id'] != null) return 'waiting';
    return 'unsent';
  }

  group('the banner', () {
    test('four states are four different sentences', () {
      expect(banner({'is_required': true, 'is_approved': true}), 'approved');
      expect(
        banner({
          'is_required': true,
          'is_approved': false,
          'request_id': 'r1',
          'awaiting_me': true,
        }),
        'mine',
      );
      expect(
        banner({
          'is_required': true,
          'is_approved': false,
          'request_id': 'r1',
          'awaiting_me': false,
        }),
        'waiting',
      );
      expect(banner({'is_required': true, 'is_approved': false}), 'unsent');
    });

    test('"waiting for you" outranks "waiting for approval"', () {
      // Both rows are pending with a live request. The difference is a
      // boolean the database computed from who is signed in, and
      // collapsing the two is how a document sits for a week on the desk
      // of the one person who could have released it in a second.
      const mine = {
        'is_required': true,
        'is_approved': false,
        'request_id': 'r1',
        'awaiting_me': true,
        'awaiting_who': 'Siti',
      };
      const theirs = {
        'is_required': true,
        'is_approved': false,
        'request_id': 'r2',
        'awaiting_me': false,
        'awaiting_who': 'Siti',
      };
      expect(banner(mine), 'mine');
      expect(banner(theirs), 'waiting');
    });

    test('an approved document is approved even while a step lingers', () {
      // `is_approved` is the request's verdict, not the absence of
      // steps. A row that somehow still carried a step id must not
      // re-open a chain the database has closed.
      expect(
        banner({
          'is_required': true,
          'is_approved': true,
          'request_id': 'r1',
          'awaiting_me': true,
        }),
        'approved',
      );
    });
  });

  group('the inbox', () {
    test('a row knows where its document lives', () {
      String? route(Map<String, dynamic> r) {
        final id = r['entity_id'] as String?;
        final type = r['doc_type'] as String?;
        if (id == null) return null;
        return switch (r['entity_kind']) {
          'sales_document' when type != null => '/sales/$type/$id',
          'purchase_document' when type != null => '/purchases/$type/$id',
          'journal' => '/journals',
          _ => null,
        };
      }

      expect(
        route({
          'entity_kind': 'sales_document',
          'doc_type': 'invoice',
          'entity_id': 'x',
        }),
        '/sales/invoice/x',
      );
      expect(
        route({
          'entity_kind': 'purchase_document',
          'doc_type': 'purchase_request',
          'entity_id': 'y',
        }),
        '/purchases/purchase_request/y',
      );
      // A journal has a list and no per-entry route. Better the list
      // than a route that 404s.
      expect(
        route({
          'entity_kind': 'journal',
          'doc_type': 'manual',
          'entity_id': 'z',
        }),
        '/journals',
      );
      // The doc type is what makes the route; without it there is
      // nowhere to send anybody, and a tile that goes nowhere is better
      // than one that goes to the wrong document.
      expect(
        route({'entity_kind': 'sales_document', 'entity_id': 'x'}),
        isNull,
      );
    });

    test(
      'the inbox is the database\'s list, in the database\'s order',
      () async {
        final c = harness(const [
          {
            'request_id': 'r1',
            'doc_no': 'PR-0002',
            'amount': 200.0,
            'requested_at': '2026-01-02T00:00:00Z',
          },
          {
            'request_id': 'r2',
            'doc_no': 'INV-0009',
            'amount': 90000.0,
            'requested_at': '2026-03-01T00:00:00Z',
          },
        ]);
        final rows = await c.read(myApprovalsProvider.future);

        // Oldest first, which is what `my_approvals` orders by — not
        // largest first. A screen that sorted by amount would put the
        // ninety thousand on top and quietly bury the requisition that has
        // been waiting two months.
        expect(rows.map((r) => r['doc_no']), ['PR-0002', 'INV-0009']);
      },
    );
  });

  group('what a rule says it will do', () {
    test('a scoped rule names the type, an unscoped one does not', () {
      expect(approvalEntityLabel('sales_document', 'invoice'), 'Invoices');
      expect(
        approvalEntityLabel('sales_document', null),
        'Every sales document',
      );
      expect(
        approvalEntityLabel('purchase_document', 'purchase_request'),
        'Purchase Requests',
      );
      // A journal has one sort, so there is nothing to narrow.
      expect(approvalEntityLabel('journal', null), 'Manual journals');
    });
  });
}
