/// Reading a document a supplier sent, before it reaches a screen.
///
/// `received_einvoice.dart` is pure by design so that this file can
/// exist: every rule about what a received document IS, and what can be
/// done with one, asserted without a database or a widget.
///
/// Two of the groups here are about the same worry from opposite sides.
/// [draftBillProblem] repeats refusals that `0650` already enforces, so
/// the button can be drawn disabled with the reason beside it instead
/// of answering with an exception — and a rule said in two places is a
/// rule that can drift. So the type codes are asserted against the
/// exact list the migration maps, and the "not loaded yet" case is
/// asserted separately, because a screen part-way through loading must
/// not accuse an ordinary document of naming an unknown currency.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/einvoice/received_einvoice.dart';

Map<String, dynamic> row({
  String id = 'r1',
  String status = 'received',
  String? docNo = 'INV-9001',
  String? issueDate = '2026-03-15',
  String? typeCode = '01',
  String? currency = 'MYR',
  String? supplierName = 'Pembekal Jaya Sdn Bhd',
  String? supplierTin = 'C1234567890',
  Object? payable = 212.0,
  String? contactId,
  Object? contact,
  String? billId,
  List<dynamic>? problems,
  Object? lines,
}) => {
  'id': id,
  'status': status,
  'doc_no': docNo,
  'issue_date': issueDate,
  'type_code': typeCode,
  'currency': currency,
  'supplier_name': supplierName,
  'supplier_tin': supplierTin,
  'payable_amount': payable,
  'total_tax': 12,
  'contact_id': contactId,
  'contacts': contact,
  'bill_id': billId,
  'myinvois_uuid': null,
  'problems': problems ?? <dynamic>[],
  'received_einvoice_lines': lines,
};

ReceivedEinvoice parse([Map<String, dynamic>? over]) =>
    ReceivedEinvoice.fromJson(over ?? row());

void main() {
  group('reading a row', () {
    test('the ordinary case', () {
      final doc = parse();
      expect(doc.id, 'r1');
      expect(doc.docNo, 'INV-9001');
      expect(doc.issueDate, DateTime(2026, 3, 15));
      expect(doc.payableAmount, 212.0);
      expect(doc.supplierTin, 'C1234567890');
      expect(doc.isBilled, isFalse);
    });

    test('every field of the row may be absent', () {
      // The document was written by somebody else's system and `0650`
      // stores what could be read rather than refusing what could not.
      // A model that threw on a null would undo that at the last step.
      final doc = ReceivedEinvoice.fromJson({'id': 'x'});
      expect(doc.status, 'received');
      expect(doc.docNo, isNull);
      expect(doc.issueDate, isNull);
      expect(doc.supplierName, isNull);
      expect(doc.payableAmount, 0);
      expect(doc.problems, isEmpty);
      expect(doc.lineCount, 0);
    });

    test('a date the producer mangled is null, not an exception', () {
      expect(parse(row(issueDate: '15 March')).issueDate, isNull);
      expect(parse(row(issueDate: null)).issueDate, isNull);
    });

    test('an amount sent as a string is still an amount', () {
      // PostgREST hands numerics back as strings often enough that a
      // model which only took `num` would report every bill as zero.
      expect(parse(row(payable: '212.00')).payableAmount, 212.0);
      expect(parse(row(payable: 'later')).payableAmount, 0);
    });

    test('an empty string is not a value', () {
      final doc = parse(row(docNo: '  ', supplierName: ''));
      expect(doc.docNo, isNull);
      expect(doc.supplierName, isNull);
    });

    test('the supplier comes off the embed when there is one', () {
      final doc = parse(row(contactId: 'c1', contact: {'name': 'Jaya'}));
      expect(doc.contactId, 'c1');
      expect(doc.contactName, 'Jaya');
    });

    test('a line count arrives either as a count or as the lines', () {
      // `received_einvoice_lines(count)` answers with one object holding
      // a count; asking for the lines answers with the lines. A screen
      // that has the lines should not have to ask again how many.
      expect(parse(row(lines: [
        {'count': 3},
      ])).lineCount, 3);
      expect(parse(row(lines: [
        {'line_no': 1},
        {'line_no': 2},
      ])).lineCount, 2);
      expect(parse(row(lines: null)).lineCount, 0);
    });
  });

  group('what can become a bill', () {
    test('the three a supplier sends', () {
      // Exactly the list `0650` maps. A fourth added here without the
      // migration would offer a button the database refuses.
      expect(receivedBillableTypes.keys.toSet(), {'01', '02', '03'});
    });

    test('an ordinary invoice with a supplier linked is ready', () {
      expect(draftBillProblem(parse(row(contactId: 'c1'))), isNull);
    });

    test('a refund note and a self-billed document are not', () {
      // `04` is a refund note; `11`-`14` are issued by THIS company, so
      // neither has a purchase document to become and guessing one
      // would post the wrong sign.
      for (final code in ['04', '11', '12', '13', '14']) {
        final said = draftBillProblem(
          parse(row(contactId: 'c1', typeCode: code)),
        );
        expect(said, isNotNull, reason: code);
        expect(said, contains('no purchase document'), reason: code);
        // And it names the thing, so the sentence is about this
        // document rather than about a rule.
        expect(said, contains(receivedTypeLabels[code]!), reason: code);
      }
    });

    test('a type nobody has heard of is refused without pretending', () {
      final said = draftBillProblem(parse(row(contactId: 'c1', typeCode: '99')));
      expect(said, contains('Type 99'));
    });

    test('no supplier is the first thing it says', () {
      // Before the type and before the currency, because it is the one
      // the person can act on immediately and the others may not even
      // apply once it is fixed.
      final said = draftBillProblem(parse(row(typeCode: '04')));
      expect(said, contains('Link a supplier'));
    });

    test('an already billed document says so', () {
      final said = draftBillProblem(parse(row(contactId: 'c1', billId: 'b1')));
      expect(said, contains('already been drafted'));
    });

    test('a document set aside has to come back first', () {
      final said = draftBillProblem(
        parse(row(contactId: 'c1', status: 'ignored')),
      );
      expect(said, contains('set aside'));
    });

    test('an unknown currency is refused when the list is known', () {
      final said = draftBillProblem(
        parse(row(contactId: 'c1', currency: 'ZZZ')),
        knownCurrencies: {'MYR', 'USD'},
      );
      expect(said, contains('ZZZ'));
    });

    test('and NOT refused when the list has not loaded', () {
      // The case that would otherwise put a false accusation in front
      // of somebody for the first second of every page load.
      expect(
        draftBillProblem(parse(row(contactId: 'c1', currency: 'ZZZ'))),
        isNull,
      );
    });

    test('a document with no currency at all says that instead', () {
      final said = draftBillProblem(
        parse(row(contactId: 'c1', currency: null)),
        knownCurrencies: {'MYR'},
      );
      expect(said, contains('does not say what currency'));
    });

    test('each type names the document it would become', () {
      expect(draftBillKindLabel('01'), 'bill');
      expect(draftBillKindLabel('02'), 'purchase credit note');
      expect(draftBillKindLabel('03'), 'purchase debit note');
      expect(draftBillKindLabel('04'), 'purchase document');
    });
  });

  group('what the list says', () {
    test('a summary names the supplier and the document', () {
      expect(
        receivedSummaryLine(parse()),
        'Pembekal Jaya Sdn Bhd · INV-9001',
      );
    });

    test('and says so when the supplier is not named', () {
      expect(
        receivedSummaryLine(parse(row(supplierName: null, docNo: null))),
        'Supplier not named',
      );
    });

    test('an unlinked supplier or a parser problem wants attention', () {
      expect(receivedNeedsAttention(parse()), isTrue);
      expect(
        receivedNeedsAttention(
          parse(row(contactId: 'c1', problems: ['The document has no lines.'])),
        ),
        isTrue,
      );
    });

    test('but simply not being billed yet does not', () {
      // That is the ordinary state of everything that has just arrived,
      // and a list where every row is flagged is a list with no flags.
      expect(receivedNeedsAttention(parse(row(contactId: 'c1'))), isFalse);
    });

    test('nor does a document already dealt with', () {
      expect(
        receivedNeedsAttention(parse(row(status: 'billed', billId: 'b1'))),
        isFalse,
      );
      expect(receivedNeedsAttention(parse(row(status: 'ignored'))), isFalse);
    });

    test('the supplier prompt carries the TIN to search for', () {
      // `0650` never matches on the name, so somebody has to make the
      // link -- and the TIN is what they will search the contact list
      // with.
      expect(supplierPrompt(parse()), contains('C1234567890'));
    });

    test('and says plainly when there is nothing to match on', () {
      final said = supplierPrompt(parse(row(supplierTin: null)));
      expect(said, contains('no TIN'));
    });

    test('a linked supplier is just its name', () {
      expect(
        supplierPrompt(parse(row(contactId: 'c1', contact: {'name': 'Jaya'}))),
        'Jaya',
      );
    });
  });

  group('what the import answers', () {
    test('a new document is named', () {
      expect(
        importOutcome({
          'duplicate': false,
          'docNo': 'INV-9001',
          'supplierName': 'Pembekal Jaya',
        }),
        'Imported Pembekal Jaya INV-9001.',
      );
    });

    test('the same file twice says nothing new arrived', () {
      // `record_received_einvoice` is idempotent on a hash of the raw
      // document, so a second import returns the FIRST row rather than
      // raising. That is right, and it is the wrong SILENCE: somebody
      // who has just pressed import will press it again.
      final said = importOutcome({
        'duplicate': true,
        'docNo': 'INV-9001',
        'supplierName': 'Pembekal Jaya',
      });
      expect(said, contains('already here'));
      expect(said, contains('Nothing new'));
      expect(said, contains('INV-9001'));
    });

    test('a document naming nobody still gets a sentence', () {
      expect(importOutcome({'duplicate': false}), 'Document imported.');
      expect(
        importOutcome({'duplicate': true}),
        contains('already here'),
      );
    });

    test('being addressed elsewhere is said first and loudest', () {
      // Three different questions, and the first changes what the other
      // two mean: a document that is not ours at all does not need its
      // arithmetic checked.
      final warnings = importWarnings({
        'addressedTo': 'Syarikat Lain Sdn Bhd',
        'totalsProblem': 'the lines add up to 100.00 but the document '
            'states 250.00, a difference of 150.00',
        'problems': ['The document has no issue date.'],
      });
      expect(warnings, hasLength(3));
      expect(warnings.first, contains('Syarikat Lain Sdn Bhd'));
      expect(warnings.first, contains('not to this company'));
      expect(warnings[1], contains('250.00'));
      expect(warnings[2], contains('issue date'));
    });

    test('an ordinary import warns about nothing', () {
      expect(
        importWarnings({
          'duplicate': false,
          'addressedTo': null,
          'totalsProblem': null,
          'problems': <dynamic>[],
        }),
        isEmpty,
      );
    });

    test('a result missing every field does not throw', () {
      // The screen shows whatever comes back, and a response shape that
      // changed must not take out the dialog explaining what arrived.
      expect(importWarnings(const {}), isEmpty);
      expect(importOutcome(const {}), 'Document imported.');
    });
  });
}
