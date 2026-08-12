import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/pdf_kit.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/contacts/statement.dart';
import 'package:iakauntan/src/features/contacts/statement_pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final asAt = DateTime(2026, 8, 11);

  BusinessDocument doc(
    String no,
    DateTime? due,
    double balance, {
    String currency = 'MYR',
    double rate = 1,
  }) =>
      BusinessDocument(
        id: no,
        docType: 'invoice',
        docNo: no,
        docDate: DateTime(2026, 1, 1),
        dueDate: due,
        contactId: 'c1',
        einvoiceStatus: 'valid',
        currency: currency,
        exchangeRate: rate,
        totalAmount: balance,
        balanceAmount: balance,
      );

  group('ageing', () {
    test('the buckets add up to the total, always', () {
      // The one property a customer will check, and the one that makes a
      // statement indefensible if it fails.
      final aged = ageing([
        doc('A', asAt.add(const Duration(days: 5)), 100),
        doc('B', asAt.subtract(const Duration(days: 10)), 200),
        doc('C', asAt.subtract(const Duration(days: 45)), 300),
        doc('D', asAt.subtract(const Duration(days: 75)), 400),
        doc('E', asAt.subtract(const Duration(days: 200)), 500),
      ], asAt);

      expect(aged.total, 1500);
      expect(aged.buckets.fold<double>(0, (s, b) => s + b.$2), aged.total);
      expect(aged.current, 100);
      expect(aged.upTo30, 200);
      expect(aged.upTo60, 300);
      expect(aged.upTo90, 400);
      expect(aged.over90, 500);
    });

    test('due today is not overdue', () {
      // Off by one here means dunning a customer who has until close of
      // business to pay.
      expect(ageing([doc('A', asAt, 100)], asAt).current, 100);
    });

    test('the band boundaries are inclusive at the top', () {
      // 30 days belongs to "1-30", 31 to "31-60". A customer comparing
      // against their own aged listing assumes this.
      expect(
          ageing([doc('A', asAt.subtract(const Duration(days: 30)), 100)], asAt)
              .upTo30,
          100);
      expect(
          ageing([doc('A', asAt.subtract(const Duration(days: 31)), 100)], asAt)
              .upTo60,
          100);
      expect(
          ageing([doc('A', asAt.subtract(const Duration(days: 90)), 100)], asAt)
              .upTo90,
          100);
      expect(
          ageing([doc('A', asAt.subtract(const Duration(days: 91)), 100)], asAt)
              .over90,
          100);
    });

    test('a document with no due date is current, not 90 days overdue', () {
      // The alternative is treating a null as the epoch, which would put
      // it in the oldest bucket and accuse the customer of nothing.
      expect(ageing([doc('A', null, 100)], asAt).current, 100);
      expect(ageing([doc('A', null, 100)], asAt).over90, 0);
    });

    test('the time of day the report runs does not move a document', () {
      final morning = DateTime(2026, 8, 11, 8);
      final evening = DateTime(2026, 8, 11, 23, 59);
      final due = DateTime(2026, 8, 11);
      expect(ageing([doc('A', due, 100)], morning).current,
          ageing([doc('A', due, 100)], evening).current);
    });

    test('a settled document contributes nothing', () {
      expect(ageing([doc('A', asAt, 0)], asAt).total, 0);
    });

    test('a foreign balance is converted before it is added', () {
      // USD 10,000 raised at 4.70, plus RM 5,000. Adding the face
      // values gives 15,000 and a statement that is wrong by RM 42,000 —
      // which nothing else in the system would have objected to.
      final aged = ageing([
        doc('USD-1', asAt, 10000, currency: 'USD', rate: 4.70),
        doc('MYR-1', asAt, 5000),
      ], asAt);

      expect(aged.total, closeTo(52000, 0.005));
    });

    test('base-currency books are untouched by the conversion', () {
      // Every existing document carries a rate of 1, in the column
      // default and in the model default alike.
      expect(ageing([doc('A', asAt, 1234.56)], asAt).total, 1234.56);
    });
  });

  group('statement PDF', () {
    final org = Organization(
      id: 'o1',
      name: 'Sinar Teknologi Sdn Bhd',
      slug: 'sinar',
      registrationNo: '202301004567',
      sstRegistrationNo: 'W10-1808-32000123',
      isSstRegistered: true,
      addressLine1: 'Level 12, Menara Sinar',
      city: 'Kuala Lumpur',
    );

    final contact = Contact(
      id: 'c1',
      code: 'CUST-0004',
      name: 'Bumi Maju Enterprise',
      contactType: 'customer',
      addressLine1: 'No 8, Jalan Dagang',
      city: 'Shah Alam',
      postcode: '40000',
    );

    test('produces a real PDF', () async {
      final bytes = await buildStatementPdf(
        org: org,
        contact: contact,
        documents: [
          doc('INV-1', asAt.subtract(const Duration(days: 40)), 500),
          doc('INV-2', asAt.add(const Duration(days: 10)), 250),
        ],
        asAt: asAt,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
    });

    test('a customer who owes nothing gets a statement saying so', () async {
      // Not an error state. "Nothing outstanding" is a useful thing to
      // send, and throwing or producing an empty page is not.
      final bytes = await buildStatementPdf(
          org: org, contact: contact, documents: const [], asAt: asAt);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });

    test('honours pre-printed stationery', () async {
      final printed = await buildStatementPdf(
          org: org,
          contact: contact,
          documents: [doc('INV-1', asAt, 100)],
          asAt: asAt);
      final onPaper = await buildStatementPdf(
          org: org,
          contact: contact,
          documents: [doc('INV-1', asAt, 100)],
          asAt: asAt,
          mode: LetterheadMode.stationery);
      expect(onPaper.length, lessThan(printed.length));
    });
  });
}
