import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/customer_portal_summary.dart';

/// What a customer reads when they open their own account.
///
/// These are the words of a stranger's system talking to somebody about
/// money they owe, read by a person with no account and no support
/// channel except replying to the email. Getting them wrong is not a
/// cosmetic failure.
void main() {
  Map<String, dynamic> inv({
    String id = 'i1',
    String no = 'INV-1',
    double balance = 1000,
    double total = 1000,
    bool overdue = false,
    String? due = '2026-02-01',
  }) => {
    'id': id,
    'doc_no': no,
    'balance_amount': balance,
    'total_amount': total,
    'overdue': overdue,
    'due_date': due,
    'doc_date': '2026-01-15',
  };

  PortalAccount account({
    String state = 'open',
    List<Map<String, dynamic>>? invoices,
    double outstanding = 1000,
  }) => PortalAccount.fromMap({
    'state': state,
    'company': {'name': 'Sinar Teknologi Sdn Bhd', 'email': 'ar@sinar.test'},
    'contact': {'name': 'Buyer Bhd'},
    'currency': 'MYR',
    'total_outstanding': outstanding,
    'invoices': invoices ?? [inv()],
  });

  group('what comes back', () {
    test("the server's figures come across as they are", () {
      final a = account();
      expect(a.isOpen, isTrue);
      expect(a.companyName, 'Sinar Teknologi Sdn Bhd');
      expect(a.contactName, 'Buyer Bhd');
      expect(a.outstanding, 1000);
      expect(a.invoices.single.docNo, 'INV-1');
    });

    test('an empty payload is a state, not a crash', () {
      final a = PortalAccount.fromMap(const {});
      expect(a.isOpen, isFalse);
      expect(a.state, 'invalid');
      expect(a.invoices, isEmpty);
    });

    test('overdue is the server\'s answer, not the device\'s', () {
      // A phone in another time zone must not tell somebody they are
      // late when they are not: `open_customer_portal` decides this
      // against Malaysian time and the page repeats it.
      expect(PortalInvoice.fromMap(inv(overdue: true)).overdue, isTrue);
      expect(
        PortalInvoice.fromMap(inv(overdue: false, due: '2020-01-01')).overdue,
        isFalse,
      );
    });
  });

  group('the figure at the top', () {
    test('owing nothing is said in words', () {
      // "RM 0.00" beside "outstanding" reads like a system that has
      // lost their payments.
      expect(
        portalOutstandingLine(account(invoices: const [], outstanding: 0)),
        'Nothing outstanding',
      );
    });

    test('and anything else is the money', () {
      expect(portalOutstandingLine(account()), 'RM 1,000.00');
    });

    test('a settled account is thanked, not left blank', () {
      final line =
          portalSummaryLine(account(invoices: const [], outstanding: 0));
      expect(line, contains('settled'));
      expect(line, contains('Sinar Teknologi Sdn Bhd'));
    });
  });

  group('the sentence under it', () {
    test('one invoice is singular', () {
      expect(portalSummaryLine(account()), startsWith('1 invoice '));
    });

    test('several are counted', () {
      expect(
        portalSummaryLine(account(invoices: [inv(), inv(id: 'i2', no: 'INV-2')])),
        startsWith('2 invoices '),
      );
    });

    test('nothing overdue says nothing about being late', () {
      expect(portalSummaryLine(account()), isNot(contains('due')));
    });

    test('some overdue says how many', () {
      final line = portalSummaryLine(account(invoices: [
        inv(overdue: true),
        inv(id: 'i2', no: 'INV-2'),
      ]));
      expect(line, contains('1 of them past due'));
    });

    test('all overdue says so rather than counting them twice', () {
      final line = portalSummaryLine(account(invoices: [
        inv(overdue: true),
        inv(id: 'i2', no: 'INV-2', overdue: true),
      ]));
      expect(line, contains('all of them past due'));
      expect(line, isNot(contains('2 of them')));
    });
  });

  group('each row', () {
    test('says when it was due, in the past tense once it is late', () {
      expect(
        portalInvoiceLine(PortalInvoice.fromMap(inv(overdue: true))),
        'INV-1 · was due 01/02/2026',
      );
      expect(
        portalInvoiceLine(PortalInvoice.fromMap(inv())),
        'INV-1 · due 01/02/2026',
      );
    });

    test('and just its number when nothing is due', () {
      expect(
        portalInvoiceLine(PortalInvoice.fromMap(inv(due: null))),
        'INV-1',
      );
    });

    test('a part-paid invoice says what the whole one was', () {
      // Otherwise the figure shown reads as the whole invoice, and a
      // customer reconciling against their own records finds a
      // difference that is not there.
      expect(
        portalPartPaidNote(
          PortalInvoice.fromMap(inv(balance: 150, total: 250)),
        ),
        'of RM 250.00',
      );
    });

    test('and one paid in full says nothing extra', () {
      expect(portalPartPaidNote(PortalInvoice.fromMap(inv())), isNull);
    });
  });

  group('when it does not open', () {
    test('each state is named, and none of them blames the reader', () {
      for (final state in const ['expired', 'revoked', 'withdrawn', 'nonsense']) {
        final m = portalStateMessage(state);
        expect(m.title, isNotEmpty);
        expect(m.body, isNotEmpty);
        // The customer's one route back is the company that sent it.
        expect(m.body.toLowerCase(), contains('company'));
      }
    });

    test('and they say different things', () {
      expect(portalStateMessage('expired').title,
          isNot(portalStateMessage('revoked').title));
    });
  });

  group('what the company is told about the link', () {
    Map<String, dynamic> link({
      String? revoked,
      String expires = '2099-01-01',
      String? lastOpened,
      int opens = 0,
    }) => {
      'revoked_at': revoked,
      'expires_at': expires,
      'last_opened_at': lastOpened,
      'open_count': opens,
      'sent_to_email': 'buyer@example.test',
    };

    test('no rows at all is no link', () {
      expect(PortalLinkState.fromRows(const []).live, isFalse);
    });

    test('a revoked one is not a live one', () {
      expect(
        PortalLinkState.fromRows([link(revoked: '2026-01-01')]).live,
        isFalse,
      );
    });

    test('nor is an expired one', () {
      expect(
        PortalLinkState.fromRows([link(expires: '2020-01-01')]).live,
        isFalse,
      );
    });

    test('the live one is found past the dead ones', () {
      // The table keeps every link ever issued, newest first, and only
      // one of them is the door that opens.
      final s = PortalLinkState.fromRows([
        link(revoked: '2026-01-01'),
        link(opens: 3, lastOpened: '2026-02-02'),
      ]);
      expect(s.live, isTrue);
      expect(s.openCount, 3);
    });

    test('never opened is said, because it is the useful part', () {
      // A link sent and never opened is a conversation that has not
      // happened, and knowing that is the difference between chasing
      // and waiting.
      final line = portalLinkStatusLine(PortalLinkState.fromRows([link()]));
      expect(line, contains('has not been opened yet'));
    });

    test('and once opened, when', () {
      final line = portalLinkStatusLine(
        PortalLinkState.fromRows([link(opens: 2, lastOpened: '2026-02-02')]),
      );
      expect(line, contains('last opened 02/02/2026'));
      expect(line, isNot(contains('not been opened')));
    });

    test('with none open, it says how to start one', () {
      expect(
        portalLinkStatusLine(const PortalLinkState(live: false)),
        contains('No link is open'),
      );
    });
  });

  group('the confirmation before sending one', () {
    test('says what the customer will see', () {
      final p = portalIssuePrompt(replacing: false, sendingTo: 'a@b.test');
      expect(p, contains('every invoice still outstanding'));
      expect(p, contains('pay any of it'));
      expect(p, contains('a@b.test'));
    });

    test('and warns when it replaces one already out there', () {
      expect(
        portalIssuePrompt(replacing: true, sendingTo: 'a@b.test'),
        contains('stops working'),
      );
      expect(
        portalIssuePrompt(replacing: false, sendingTo: 'a@b.test'),
        isNot(contains('stops working')),
      );
    });

    test('with no address it says the link is shown rather than sent', () {
      // The link is the deliverable; the email is the delivery. A
      // contact with no address is not a reason to refuse.
      final p = portalIssuePrompt(replacing: false, sendingTo: null);
      expect(p, contains('no address on this contact'));
      expect(p, contains('shown here'));
    });
  });
}
