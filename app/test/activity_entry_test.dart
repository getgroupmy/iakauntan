import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/documents/activity_entry.dart';

Map<String, dynamic> row(String kind,
        {String? status, String? detail, String? recipient, String? note}) =>
    {
      'kind': kind,
      'status': status,
      'detail': detail,
      'recipient': recipient,
      'note': note,
    };

void main() {
  group('what the timeline shows', () {
    test('an email keeps its status in the chip', () {
      final l = ActivityLine.from(
          row('email', status: 'sent', detail: 'sent now · PDF attached'));
      expect(l.label, 'Emailed');
      expect(l.badge, 'sent');
      expect(l.tone, ActivityTone.good);
      expect(l.detail, 'sent now · PDF attached');
    });

    test('a failed email reads as bad news', () {
      expect(ActivityLine.from(row('email', status: 'failed')).tone,
          ActivityTone.bad);
    });

    // The point of 0495's audit read: `status` there is the raw trigger
    // operation ('insert', 'update'), which means nothing to a reader.
    // What happened is in `detail`.
    test('a change shows what happened, not the trigger operation', () {
      final l = ActivityLine.from(
          row('change', status: 'update', detail: 'posted to the ledger'));
      expect(l.label, 'Changed');
      expect(l.badge, 'posted to the ledger');
      expect(l.badge, isNot('update'));
      expect(l.tone, ActivityTone.good);
    });

    test('a void reads as bad news', () {
      expect(
          ActivityLine.from(row('change', status: 'update', detail: 'voided'))
              .tone,
          ActivityTone.bad);
    });

    test('an edit says which fields moved, in words', () {
      final l = ActivityLine.from(row('change',
          status: 'update', detail: 'edited', note: 'due_date, reference'));
      expect(l.note, 'changed due_date, reference');
    });

    test('a payment names the receipt and the amount', () {
      final l = ActivityLine.from(row('payment',
          status: 'received',
          detail: 'RCP-1 · 400.00',
          recipient: 'Buyer Bhd'));
      expect(l.label, 'Paid');
      expect(l.tone, ActivityTone.good);
      expect(l.detail, 'RCP-1 · 400.00');
      expect(l.recipient, 'Buyer Bhd');
    });

    test('LHDN validating is good and LHDN rejecting is not', () {
      expect(ActivityLine.from(row('e-invoice', status: 'valid')).tone,
          ActivityTone.good);
      expect(ActivityLine.from(row('e-invoice', status: 'rejected')).tone,
          ActivityTone.bad);
      expect(ActivityLine.from(row('e-invoice', status: 'submitted')).tone,
          ActivityTone.waiting);
    });

    // Before 0495 every unrecognised kind fell through to the PDF row,
    // so a change, a payment and an e-invoice would all have been drawn
    // as 'PDF downloaded'.
    test('each of the six kinds gets its own label', () {
      final labels = [
        'email',
        'share link',
        'pdf',
        'change',
        'payment',
        'e-invoice',
      ].map((k) => ActivityLine.from(row(k, detail: 'x')).label).toList();
      expect(labels.toSet().length, 6);
    });

    test('empty strings do not become empty lines', () {
      final l = ActivityLine.from(
          row('pdf', status: 'downloaded', recipient: '', note: '  '));
      expect(l.recipient, isNull);
      expect(l.note, isNull);
    });
  });
}
