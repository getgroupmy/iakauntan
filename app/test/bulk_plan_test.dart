import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/bulk_plan.dart';

BusinessDocument doc(String id, String status, {String type = 'invoice'}) =>
    BusinessDocument(
      id: id,
      docType: type,
      docNo: id.toUpperCase(),
      docDate: DateTime(2026, 3, 4),
      contactId: 'c1',
      status: status,
    );

void main() {
  group('what a batch would do', () {
    final list = [
      doc('a', 'draft'),
      doc('b', 'draft'),
      doc('c', 'posted'),
      doc('d', 'void'),
    ];

    test('nothing ticked is nothing to do', () {
      final plan = BulkPlan.of(list, {}, 'invoice');
      expect(plan.isEmpty, isTrue);
      expect(plan.postLabel(), 'Nothing to post');
    });

    test('the drafts are what a Post would reach', () {
      final plan = BulkPlan.of(list, {'a', 'b'}, 'invoice');
      expect(plan.postable.length, 2);
      expect(plan.postLabel(), 'Post 2');
    });

    // The number people are surprised by afterwards. A bar that said
    // "Post 4" and posted two is worse than a longer label.
    test('and the shortfall is named when some cannot', () {
      final plan = BulkPlan.of(list, {'a', 'b', 'c', 'd'}, 'invoice');
      expect(plan.postable.length, 2);
      expect(plan.postLabel(), 'Post 2 of 4');
    });

    test('a posted document does not post again', () {
      final plan = BulkPlan.of(list, {'c'}, 'invoice');
      expect(plan.postable, isEmpty);
    });

    // Quotations and orders write no journal, so the action does not
    // belong on their list at all.
    test('a document type that writes no journal has nothing to post', () {
      final quotes = [doc('q', 'draft', type: 'quotation')];
      final plan = BulkPlan.of(quotes, {'q'}, 'quotation');
      expect(plan.postable, isEmpty);
      expect(plan.selected.length, 1);
    });

    test('a draft is not something to send in a batch', () {
      final plan = BulkPlan.of(list, {'a', 'c'}, 'invoice');
      expect(plan.emailable.length, 1);
      expect(plan.emailable.single.id, 'c');
      expect(plan.emailLabel(), 'Email 1 of 2');
    });

    test('ticks for documents that are not on the list are ignored', () {
      final plan = BulkPlan.of(list, {'a', 'nonexistent'}, 'invoice');
      expect(plan.selected.length, 1);
    });
  });

  group('what the batch came back with', () {
    List<Map<String, dynamic>> rows(int ok, int bad) => [
          for (var i = 0; i < ok; i++) {'posted': true},
          for (var i = 0; i < bad; i++) {'posted': false},
        ];

    test('all of them', () {
      expect(BulkPlan.outcome(rows(3, 0), 'posted'), '3 done.');
      expect(BulkPlan.outcome(rows(1, 0), 'posted'), '1 done.');
    });

    // The failures are the point: 38 of 40 is a success and two things
    // to go and fix.
    test('most of them', () {
      expect(BulkPlan.outcome(rows(38, 2), 'posted'), '38 done, 2 could not.');
    });

    test('none of them', () {
      expect(BulkPlan.outcome(rows(0, 4), 'posted'), 'None of 4 could.');
      expect(BulkPlan.outcome(rows(0, 1), 'posted'), '1 could not.');
    });

    test('an empty answer says so rather than saying zero', () {
      expect(BulkPlan.outcome(const [], 'posted'), 'Nothing to do.');
    });
  });
}
