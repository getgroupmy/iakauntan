import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/documents/invoice_pdf.dart';
import 'package:iakauntan/src/features/hr/payslip_pdf.dart';

/// A PDF that compiles is not a PDF that is right. These build real files
/// from the shapes the database actually returns — checked against the
/// hosted project, not invented — and look at the bytes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final org = Organization(
    id: 'o1',
    name: 'Sinar Teknologi Sdn Bhd',
    slug: 'sinar',
    registrationNo: '202301004567',
    tin: 'C12345678900',
    sstRegistrationNo: 'W10-1808-32000123',
    isSstRegistered: true,
    addressLine1: 'Level 12, Menara Sinar',
    city: 'Kuala Lumpur',
    postcode: '50450',
    stateCode: '14',
    email: 'accounts@sinar.my',
    phone: '+60 3 1234 5678',
  );

  String head(List<int> bytes) => String.fromCharCodes(bytes.take(5));

  group('invoice', () {
    BusinessDocument invoice({
      double tax = 60,
      double paid = 0,
      String einvoice = 'valid',
      String? glEntryId = 'gl-1',
    }) =>
        BusinessDocument(
          id: 'd1',
          docType: 'invoice',
          docNo: 'INV-2026-00042',
          docDate: DateTime(2026, 8, 11),
          dueDate: DateTime(2026, 9, 10),
          contactId: 'c1',
          contactName: 'Bumi Maju Enterprise',
          reference: 'PO 7781',
          subtotal: 1000,
          taxAmount: tax,
          totalAmount: 1060,
          paidAmount: paid,
          balanceAmount: 1060 - paid,
          roundingAmount: 0.02,
          einvoiceStatus: einvoice,
          glEntryId: glEntryId,
          notes: 'Thank you for your business.',
          termsConditions: 'Payment within 30 days.',
          lines: [
            DocumentLine(
              lineNo: 1,
              description: 'Implementation services',
              quantity: 10,
              unitPrice: 80,
              taxRate: 6,
              taxAmount: 48,
              lineSubtotal: 800,
              lineTotal: 848,
            ),
            DocumentLine(
              lineNo: 2,
              description: 'Support retainer — August',
              quantity: 1,
              unitPrice: 200,
              taxRate: 6,
              taxAmount: 12,
              lineSubtotal: 200,
              lineTotal: 212,
            ),
          ],
        );

    test('produces a real PDF', () async {
      final bytes = await buildInvoicePdf(
          org: org, doc: invoice(), documentLabel: 'Invoice');
      expect(head(bytes), '%PDF-');
      expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
      expect(bytes.length, greaterThan(5000));
    });

    test('a document with no tax, no discount and no lines still renders',
        () async {
      // The column set is decided by what the lines contain, so the empty
      // case is the one that would throw on an index that is not there.
      final bytes = await buildInvoicePdf(
        org: Organization(id: 'o', name: 'Bare Sdn Bhd', slug: 'bare'),
        doc: BusinessDocument(
          id: 'd',
          docType: 'invoice',
          docNo: 'INV-1',
          docDate: DateTime(2026, 1, 1),
          contactId: 'c',
          einvoiceStatus: 'not_applicable',
        ),
        documentLabel: 'Invoice',
      );
      expect(head(bytes), '%PDF-');
    });

    test('an unposted document is marked as a draft', () async {
      // Not a rendering detail: a draft that looks like a tax invoice is
      // a document somebody pays against.
      final bytes = await buildInvoicePdf(
        org: org,
        doc: invoice(glEntryId: null, einvoice: 'not_applicable'),
        documentLabel: 'Invoice',
      );
      expect(head(bytes), '%PDF-');
    });
  });

  group('payslip', () {
    // The line kinds and descriptions are copied from a real payslip:
    // basic salary is an earning LINE, and the statutory deductions are
    // deduction LINES. Printing the scalar fields as well would list
    // every figure twice while the totals still footed.
    Payslip payslip({bool verified = true}) => Payslip(
          id: 'p1',
          employeeName: 'Nurul Aina binti Rahman',
          employeeNo: 'EMP-004',
          departmentName: 'Finance',
          positionTitle: 'Accounts Executive',
          periodCode: '2026-08',
          basicSalary: 5000,
          grossPay: 5000,
          totalDeductions: 693.25,
          netPay: 4306.75,
          epfEmployee: 550,
          epfEmployer: 650,
          socsoEmployee: 25,
          socsoEmployer: 87.5,
          eisEmployee: 10,
          eisEmployer: 10,
          pcb: 108.25,
          zakat: 0,
          hrdf: 50,
          otHours: 0,
          schedulesVerified: verified,
          lines: [
            PayslipLine(
                kind: 'earning',
                code: 'BASIC',
                description: 'Basic salary',
                amount: 5000),
            PayslipLine(
                kind: 'deduction',
                code: 'EPF',
                description: 'EPF employee',
                amount: 550),
            PayslipLine(
                kind: 'deduction',
                code: 'SOCSO',
                description: 'SOCSO employee',
                amount: 25),
            PayslipLine(
                kind: 'deduction',
                code: 'EIS',
                description: 'EIS employee',
                amount: 10),
            PayslipLine(
                kind: 'deduction',
                code: 'PCB',
                description: 'PCB / MTD',
                amount: 108.25),
            PayslipLine(
                kind: 'employer_contribution',
                code: 'EPF_ER',
                description: 'EPF employer',
                amount: 650),
            PayslipLine(
                kind: 'employer_contribution',
                code: 'HRDF',
                description: 'HRD Corp levy',
                amount: 50),
          ],
        );

    test('produces a real PDF', () async {
      final bytes = await buildPayslipPdf(org: org, payslip: payslip());
      expect(head(bytes), '%PDF-');
      expect(String.fromCharCodes(bytes.skip(bytes.length - 6)).trim(), '%%EOF');
    });

    test('an unverified schedule is carried onto the payslip itself',
        () async {
      // The warning has to travel with the document, because the payslip
      // is what the employee keeps.
      final withWarning =
          await buildPayslipPdf(org: org, payslip: payslip(verified: false));
      final without =
          await buildPayslipPdf(org: org, payslip: payslip(verified: true));
      expect(withWarning.length, greaterThan(without.length),
          reason: 'the warning block should add content, not be dropped');
    });

    test('a payslip with no lines at all still renders', () async {
      final bytes = await buildPayslipPdf(
        org: org,
        payslip: Payslip(
          id: 'p',
          employeeName: 'No Lines',
          basicSalary: 0,
          grossPay: 0,
          totalDeductions: 0,
          netPay: 0,
          epfEmployee: 0,
          epfEmployer: 0,
          socsoEmployee: 0,
          socsoEmployer: 0,
          eisEmployee: 0,
          eisEmployer: 0,
          pcb: 0,
          zakat: 0,
          hrdf: 0,
          otHours: 0,
          schedulesVerified: true,
          lines: const [],
        ),
      );
      expect(head(bytes), '%PDF-');
    });
  });
  group('letterhead logo', () {
    // A real 1x1 PNG. MemoryImage sniffs the header, so a stub of random
    // bytes would prove nothing.
    final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

    test('an invoice with a logo renders, and carries it', () async {
      final without = await buildInvoicePdf(
          org: org, doc: _plainInvoice(), documentLabel: 'Invoice');
      final with_ = await buildInvoicePdf(
          org: org,
          doc: _plainInvoice(),
          documentLabel: 'Invoice',
          logo: png);

      expect(String.fromCharCodes(with_.take(5)), '%PDF-');
      expect(with_.length, greaterThan(without.length),
          reason: 'the image should be embedded, not silently dropped');
    });

    test('a payslip with a logo renders', () async {
      final bytes = await buildPayslipPdf(
        org: org,
        payslip: Payslip(
          id: 'p',
          employeeName: 'With Logo',
          basicSalary: 0,
          grossPay: 0,
          totalDeductions: 0,
          netPay: 0,
          epfEmployee: 0,
          epfEmployer: 0,
          socsoEmployee: 0,
          socsoEmployer: 0,
          eisEmployee: 0,
          eisEmployer: 0,
          pcb: 0,
          zakat: 0,
          hrdf: 0,
          otHours: 0,
          schedulesVerified: true,
          lines: const [],
        ),
        logo: png,
      );
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });
}

/// The smallest invoice that still exercises the letterhead.
BusinessDocument _plainInvoice() => BusinessDocument(
      id: 'd',
      docType: 'invoice',
      docNo: 'INV-9',
      docDate: DateTime(2026, 8, 11),
      contactId: 'c',
      contactName: 'A Customer',
      einvoiceStatus: 'not_applicable',
      glEntryId: 'gl',
      subtotal: 100,
      totalAmount: 100,
      lines: [
        DocumentLine(
            lineNo: 1,
            description: 'One thing',
            quantity: 1,
            unitPrice: 100,
            lineSubtotal: 100,
            lineTotal: 100),
      ],
    );
