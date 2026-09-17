import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';

/// The ceiling the e-Invoice submitter stops at, on both sides of a
/// language boundary.
///
/// `einvoice_documents.retry_count` was a column nothing wrote to. The
/// bulk picker selects `status in ('queued','draft','failed','invalid')`
/// and `invalid` is what MyInvois says when it has REJECTED a document
/// — a buyer TIN that does not exist, a classification code LHDN does
/// not have. Almost never transient, so the same document was
/// re-rendered, re-signed and re-submitted on every sweep for ever,
/// against an API that is rate-limited and counts submissions per
/// taxpayer.
///
/// `supabase/functions/myinvois/retry.ts` counts it and stops. This
/// screen has to agree with that file about when, and Dart cannot
/// import TypeScript — so the figure is read out of the real file
/// rather than restated here. A screen saying "stopped after 5
/// attempts" while the submitter stops at 3 is worse than a screen
/// saying nothing.
void main() {
  EinvoiceDocument doc({int retries = 0}) => EinvoiceDocument(
    id: 'e1',
    internalDocNo: 'INV-1',
    status: 'invalid',
    typeCode: '01',
    issueDate: DateTime(2026, 3, 1),
    retryCount: retries,
  );

  group('the two copies of the ceiling agree', () {
    test('and the figure is read out of retry.ts, not restated', () {
      // Deliberately the real file. If somebody changes MAX_ATTEMPTS in
      // the submitter, this fails here rather than on a screen that
      // quietly claims the wrong number.
      final source = File('../supabase/functions/myinvois/retry.ts');
      expect(source.existsSync(), isTrue,
          reason: 'retry.ts is where the submitter keeps the ceiling');

      final match = RegExp(r'MAX_ATTEMPTS\s*=\s*(\d+)')
          .firstMatch(source.readAsStringSync());
      expect(match, isNotNull,
          reason: 'retry.ts no longer declares MAX_ATTEMPTS');

      expect(int.parse(match!.group(1)!), einvoiceMaxAttempts);
    });

    test('and it is a number that lets a transient failure through', () {
      // A ceiling of one gives up on a token that expired mid-batch.
      expect(einvoiceMaxAttempts, greaterThan(1));
    });
  });

  group('when the submitter has given up', () {
    test('a document at the ceiling says so', () {
      expect(doc(retries: einvoiceMaxAttempts).retriesExhausted, isTrue);
    });

    test('and one attempt short of it does not', () {
      expect(doc(retries: einvoiceMaxAttempts - 1).retriesExhausted, isFalse);
    });

    test('a document nothing has tried is not exhausted', () {
      expect(doc().retriesExhausted, isFalse);
    });

    test('and past the ceiling still counts as stopped', () {
      // A person forcing Submit is never refused, so the count on a
      // document somebody keeps retrying by hand can pass the ceiling.
      expect(doc(retries: einvoiceMaxAttempts + 3).retriesExhausted, isTrue);
    });
  });

  group('the count comes off the wire', () {
    test('as the number the column holds', () {
      expect(
        EinvoiceDocument.fromJson({
          'id': 'e1',
          'issue_date': '2026-03-01',
          'retry_count': 4,
        }).retryCount,
        4,
      );
    });

    test('and a row without it has not been tried', () {
      // `retry_count` is `not null default 0`, so this is the shape of
      // a row read before the column meant anything — and it must not
      // read as exhausted.
      final row = EinvoiceDocument.fromJson({
        'id': 'e1',
        'issue_date': '2026-03-01',
      });

      expect(row.retryCount, 0);
      expect(row.retriesExhausted, isFalse);
    });
  });
}
