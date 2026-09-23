import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/shared/document_classifier.dart';

/// Working out what a scanned paper is.
///
/// `0614`. The assertion this file exists for is the first group: a
/// supplier's STATEMENT OF ACCOUNT and a BANK STATEMENT both say
/// "statement of account", and filing the first into the bank
/// reconciliation would invent transactions that never touched the
/// bank. Every other confusion here costs somebody a retype; that one
/// costs a reconciliation that balances to the wrong number.
///
/// Half the paper in a Malaysian office is in Malay, so both languages
/// are asserted throughout. A classifier that only knows English words
/// files every Malay document as "something else", which is not a
/// failure anybody would report — they would simply stop using it.
void main() {
  group('the two statements that are not each other', () {
    test("a bank's statement goes to the reconciliation", () {
      final g = classifyDocument(
        text: 'MAYBANK BERHAD\nSTATEMENT OF ACCOUNT\n'
            'OPENING BALANCE 15,000.00\nWITHDRAWAL 250.00\n'
            'CLOSING BALANCE 14,750.00',
      );
      expect(g.kind, 'bank_statement');
      expect(g.isSure, isTrue);
    });

    test("and a supplier's statement does not", () {
      // The same three words at the top. What tells them apart is what
      // else is on the page.
      final g = classifyDocument(
        text: 'SYARIKAT MAJU SDN BHD\nSTATEMENT OF ACCOUNT\n'
            'OUTSTANDING AS AT 31/03/2026\nAGEING\n'
            'INV-0041  1,080.00',
        hasTotal: true,
      );
      expect(
        g.kind,
        isNot('bank_statement'),
        reason: 'a supplier ledger imported as a bank statement invents '
            'transactions that never touched the bank',
      );
    });

    test('a Malay bank statement is read as one', () {
      final g = classifyDocument(
        text: 'CIMB BANK BERHAD\nPENYATA AKAUN\nBAKI AWAL 5,000.00\n'
            'PENGELUARAN 120.00\nBAKI AKHIR 4,880.00',
      );
      expect(g.kind, 'bank_statement');
    });

    test('a supplier statement that mentions a deposit is still not one', () {
      // The case the ruling-out list exists for. Without "ageing" and
      // "outstanding as at" among the words that rule a bank statement
      // OUT, a supplier ledger carrying the word "deposit" -- which
      // plenty do, for a deposit received -- rules ITSELF out as a
      // statement of account and lands in the bank reconciliation.
      final g = classifyDocument(
        text: 'SYARIKAT MAJU SDN BHD\nSTATEMENT OF ACCOUNT\n'
            'OUTSTANDING AS AT 31/03/2026\nAGEING 30 60 90\n'
            'Less: deposit received 500.00\nINV-0041  1,080.00',
        hasTotal: true,
      );
      expect(g.kind, isNot('bank_statement'));
    });

    test('while a bank counter receipt is a receipt, not a statement', () {
      // It says RESIT at the top, and it carries more words a bank
      // statement carries than the word "resit" has letters. Naming
      // beats counting, and a scale that compared the two numbers
      // would file this as a statement.
      final g = classifyDocument(
        text: 'RESIT\nMAYBANK\nDEPOSIT 500.00\nBAKI AKHIR 4,500.00\n'
            'BAKI AWAL 4,000.00\nCLOSING BALANCE 4,500.00\n'
            'OPENING BALANCE 4,000.00\nTERIMA KASIH',
        hasTotal: true,
      );
      expect(
        g.kind,
        'receipt',
        reason: 'the paper says what it is; the other words are things '
            'it happens to carry',
      );
    });

    test("and a bill that mentions a balance is still a bill", () {
      // "closing balance" appears on plenty of supplier invoices. The
      // words that rule a bank statement out are the ones that cannot
      // be on one.
      final g = classifyDocument(
        text: 'TAX INVOICE\nINV-2026-0041\nCLOSING BALANCE 1,080.00',
        hasTotal: true,
      );
      expect(g.kind, 'bill');
    });
  });

  group('the transaction documents', () {
    test('a tax invoice is a bill', () {
      final g = classifyDocument(
        text: 'TAX INVOICE\nNo. INV-0041\nTotal 1,080.00',
        hasTotal: true,
        hasLines: true,
      );
      expect(g.kind, 'bill');
      expect(g.isSure, isTrue);
    });

    test('and so is an invois cukai', () {
      final g = classifyDocument(
        text: 'INVOIS CUKAI\nNo. INV-0041\nJumlah 1,080.00',
        hasTotal: true,
      );
      expect(g.kind, 'bill');
    });

    test('a resit rasmi is a receipt', () {
      final g = classifyDocument(
        text: 'RESIT RASMI\nTerima kasih\nRM 45.00',
        hasTotal: true,
      );
      expect(g.kind, 'receipt');
    });

    test('a sebut harga is a quotation', () {
      final g = classifyDocument(
        text: 'SEBUT HARGA\nSah sehingga 30/04/2026\nRM 5,000.00',
        hasTotal: true,
      );
      expect(g.kind, 'quotation');
    });

    test('a nota penghantaran is a delivery order', () {
      final g = classifyDocument(
        text: 'NOTA PENGHANTARAN\nDO No. 4412\n10 unit',
      );
      expect(g.kind, 'delivery_order');
    });
  });

  /// A voucher is the company's OWN record of money going out. `0686`.
  ///
  /// This one was photographed into Bills and the screen asked "which
  /// supplier?" with an empty box. Every part of the page was a firm
  /// recording a payment: its own letterhead, its own voucher book, the
  /// EPF as payee. Filed as a bill it would have made a contact record
  /// of the firm itself and a payable it owed to itself.
  group('a voucher is not a bill', () {
    // The real one, transcribed. Handwriting and all — the printed
    // skeleton is what the classifier has to work from, because the
    // blanks are filled in by hand and read badly.
    const voucher = 'SHAHARUDIN, SHAM SUNDER & PARTNERS\n'
        'PAYMENT VOUCHER\n'
        'A/C Debited Office    File Ref EPF    Date 22/1/25   No 16851\n'
        'Pay Online   To KWSP\n'
        'being payment of September 2023 payment   1320.00\n'
        'Prepared by      Approved by      Received by';

    test('the voucher that started this is a payment voucher', () {
      final g = classifyDocument(text: voucher, hasTotal: true);
      expect(g.kind, 'payment_voucher');
      expect(g.isSure, isTrue);
    });

    test('and a baucar bayaran is the same document', () {
      final g = classifyDocument(
        text: 'BAUCAR BAYARAN\nDisediakan oleh\nDiluluskan oleh\n'
            'RM 1,320.00',
        hasTotal: true,
      );
      expect(g.kind, 'payment_voucher');
    });

    // The two above pass on HINTS as much as on the name — a voucher
    // book prints six of them down the right-hand side. A mutation
    // sweep proved it: deleting "payment voucher" from the list of
    // names left both of them passing. These two carry the name and
    // nothing else, so they fail if it goes.
    test('the name alone is enough, with none of the printed skeleton',
        () {
      final g = classifyDocument(
        text: 'PAYMENT VOUCHER\nRM 1,320.00',
        hasTotal: true,
      );
      expect(g.kind, 'payment_voucher');
    });

    test('and so is the Malay name alone', () {
      final g = classifyDocument(
        text: 'BAUCAR BAYARAN\nRM 1,320.00',
        hasTotal: true,
      );
      expect(g.kind, 'payment_voucher');
    });

    test('a voucher that quotes the tax invoice it pays is still a voucher',
        () {
      // The ordinary case, not the exception: a voucher names what it
      // is paying. The first version excluded any page saying "tax
      // invoice" from being a voucher, which would have sent the very
      // document this was written for straight back to Bills.
      final g = classifyDocument(
        text: 'PAYMENT VOUCHER\nbeing payment of TAX INVOICE INV-0041\n'
            '1,080.00',
        hasTotal: true,
      );
      expect(g.kind, 'payment_voucher');
    });

    test('and the printed skeleton alone carries it when the title is cut',
        () {
      // A photograph of a voucher book taken at an angle loses the
      // heading and keeps the pre-printed lines, which is what the
      // camera does to the top of a page held flat on a desk. Without
      // this the hints are decoration — every other fixture here names
      // itself, so a sweep that deletes them changes nothing.
      final g = classifyDocument(
        text: 'A/C Debited Office    File Ref EPF\n'
            'being payment of September 2023 payment\n'
            'Prepared by        Approved by',
        hasTotal: true,
      );
      expect(g.kind, 'payment_voucher');
      // Sure, and that is the existing rule rather than an accident:
      // "several are as good as the paper saying so", asserted further
      // down this file. Four pre-printed phrases off a voucher book is
      // several. Asserting isFalse here was my mistake and the control
      // caught it.
      expect(g.isSure, isTrue);
      expect(g.because, contains('being payment of'));
    });

    test('but a page asking to BE paid is not a voucher', () {
      // What the `against` is actually for. No bill name here at all,
      // so nothing else settles it — a voucher records a payment made,
      // and a page carrying "amount due" is asking for one.
      final g = classifyDocument(
        text: 'Prepared by\nApproved by\nAmount due 1,080.00',
        hasTotal: true,
      );
      expect(g.kind, isNot('payment_voucher'));
    });

    test('and a real tax invoice is untouched by any of this', () {
      // The other direction, which is the one that would cost money:
      // a supplier's bill misfiled as the company's own voucher is a
      // payable that never gets entered.
      final g = classifyDocument(
        text: 'TAX INVOICE\nNo. INV-0041\nAmount due 1,080.00',
        hasTotal: true,
        hasLines: true,
      );
      expect(g.kind, 'bill');
      expect(g.isSure, isTrue);
    });

    test('a receipt is not made a voucher by saying "received by"', () {
      final g = classifyDocument(
        text: 'OFFICIAL RECEIPT\nReceived by\nTerima kasih\nRM 45.00',
        hasTotal: true,
      );
      expect(g.kind, 'receipt');
    });
  });

  group('the longest phrase wins, not the most of them', () {
    test('a bank statement is not outvoted by three weak words', () {
      // "invoice", "terms" and "amount due" can all appear on a
      // covering letter stapled to a statement. Counting matches would
      // make three of those beat one "penyata bank"; the length of the
      // phrase that matched is what decides instead.
      final g = classifyDocument(
        text: 'PENYATA BANK\nPlease see the attached invoice.\n'
            'Terms apply.\nAmount due on the account below.',
      );
      expect(g.kind, 'bank_statement');
    });
  });

  group('a paper that does not say what it is', () {
    test('a company number and no money is a card or a letterhead', () {
      final g = classifyDocument(
        text: 'SINAR TEKNOLOGI SDN BHD\n202301234567\n'
            'Lot 12, Jalan Perusahaan 3\n40000 Shah Alam\n03-1234 5678',
        hasRegistrationNo: true,
      );
      expect(g.kind, 'name_card');
      expect(g.isSure, isFalse, reason: 'it is an inference, not a reading');
    });

    test('a total and nothing else is guessed at as a receipt, weakly', () {
      final g = classifyDocument(text: 'KEDAI RUNCIT\n12.50', hasTotal: true);
      expect(g.kind, 'receipt');
      expect(
        g.isGuess,
        isTrue,
        reason: 'the screen has to say "might be" rather than "is"',
      );
    });

    test('and nothing at all is "something else", not a wrong answer', () {
      final g = classifyDocument(text: 'a b c');
      expect(g.kind, 'other');
      expect(g.confidence, 0);
    });

    test('an empty reading says so', () {
      expect(classifyDocument(text: null).kind, 'other');
      expect(classifyDocument(text: '   ').kind, 'other');
      expect(classifyDocument(text: null).because, contains('Nothing'));
    });
  });

  group('how sure it says it is', () {
    test('a document that names itself and has money is sure', () {
      final g = classifyDocument(
        text: 'TAX INVOICE',
        hasTotal: true,
      );
      expect(g.isSure, isTrue);
    });

    test('and one that names itself with nothing read is not', () {
      // The kind still stands — it says what it is — but a reading with
      // no figures on it went badly and the screen should not pretend
      // otherwise.
      final g = classifyDocument(text: 'TAX INVOICE');
      expect(g.kind, 'bill');
      expect(g.isSure, isFalse);
      expect(g.because, contains('no amounts'));
    });

    test('one supporting word is a guess, not a finding', () {
      // "Outstanding as at" appears on a statement of account and on
      // plenty of covering letters. One of them is not enough to tell
      // somebody what they are looking at.
      final g = classifyDocument(text: 'OUTSTANDING AS AT 31/03/2026');
      expect(g.kind, 'statement_of_account');
      expect(g.isSure, isFalse);
    });

    test('while several are as good as the paper saying so', () {
      // Four things that only appear together on one kind of paper
      // appeared together. A person reading it would be sure, and the
      // screen should say so rather than hedging.
      final g = classifyDocument(
        text: 'OPENING BALANCE\nWITHDRAWAL\nDEPOSIT\nCLOSING BALANCE',
      );
      expect(g.kind, 'bank_statement');
      expect(g.isSure, isTrue);
      expect(g.because, contains('other things'));
    });

    test('the reason is words, not a percentage', () {
      // "Says TAX INVOICE" reads as a reason. "87% confident" reads as
      // a machine being certain about something it cannot be certain
      // about, and invites somebody to trust it.
      final g = classifyDocument(text: 'TAX INVOICE', hasTotal: true);
      expect(g.because, contains('tax invoice'));
      expect(g.because, isNot(contains('%')));
    });
  });
}
