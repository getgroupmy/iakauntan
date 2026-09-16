import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';
import 'package:iakauntan/src/features/mail/inbox_screen.dart';

/// Mail at the company's own addresses.
///
/// The helpers underneath this screen are pure and asserted elsewhere —
/// `mail_compose_test.dart` has `replySubject` and `deliveryNote`,
/// `mail_attachments_test.dart` has the size and kind labels. What had
/// no test at all is the screen, and three things live only in it.
///
/// WHICH LIST IS ON THE SCREEN. There are three sources — everything
/// that arrived, one address's conversation, and a search — and the
/// screen picks between them on two variables at once. A query BEATS a
/// chosen address rather than being ignored by it, and it is scoped TO
/// that address, which is the whole reason `search_mail` takes a
/// `p_mailbox_id` that can be null.
///
/// THE TWO LISTS CARRY DIFFERENT COLUMN NAMES FOR THE SAME FACTS.
/// `inboxProvider` selects `received_at` and `read_at` off
/// `inbound_emails`; `mailbox_thread` calls them `at` and `handled_at`,
/// because in the other direction the same column is when the message
/// left. `_Row` reads both, and if it read only one, a whole list
/// renders with no dates on it and every message bold.
///
/// SOMETHING THAT LEFT IS NOT SOMETHING TO READ. An outgoing row has no
/// `read_at` ever — `handled_at` is `sent_at` — so without the
/// direction guard every message the person wrote themselves comes back
/// as unread mail, offers a Reply to their own address, and shows an
/// attachments section reading a table it is not in.
void main() {
  /// A row the way `inboxProvider` selects one: `inbound_emails`
  /// straight out, which carries no `direction` column at all.
  Map<String, dynamic> arrived({
    String id = 'e1',
    String? mailboxId = 'mb-sales',
    String fromEmail = 'aminah@kedai.example',
    String? fromName = 'Puan Aminah',
    String subject = 'About invoice INV-0042',
    String body = 'When is this due?',
    String receivedAt = '2026-09-10T08:30:00Z',
    String? readAt,
  }) => {
    'id': id,
    'mailbox_id': mailboxId,
    'from_email': fromEmail,
    'from_name': fromName,
    'to_email': 'sales@iakauntan.com',
    'subject': subject,
    'body_text': body,
    'received_at': receivedAt,
    'read_at': readAt,
  };

  /// A row the way `mailbox_thread` returns one.
  ///
  /// The names are the function's: `at` rather than `received_at`,
  /// `handled_at` rather than `read_at`, and NO `mailbox_id` — the
  /// thread is one mailbox, so the function does not repeat it on every
  /// line and the screen has to supply it from the chip that was
  /// chosen.
  Map<String, dynamic> threadRow({
    String id = 't1',
    String direction = 'in',
    String fromEmail = 'aminah@kedai.example',
    String? fromName = 'Puan Aminah',
    String toEmail = 'sales@iakauntan.com',
    String subject = 'About invoice INV-0042',
    String body = 'When is this due?',
    String at = '2026-09-10T08:30:00Z',
    String? handledAt,
    String status = 'received',
  }) => {
    'id': id,
    'direction': direction,
    'from_email': fromEmail,
    'from_name': fromName,
    'to_email': toEmail,
    'subject': subject,
    'body_text': body,
    'at': at,
    'handled_at': handledAt,
    'status': status,
  };

  Map<String, dynamic> mailbox({
    String id = 'mb-sales',
    String localPart = 'sales',
    bool personal = false,
  }) => {'id': id, 'local_part': localPart, 'is_personal': personal};

  /// Every search the screen asked for, in order, with its key.
  ///
  /// Recorded rather than inferred from what is on the screen: the two
  /// searches that matter here return the SAME rows, so the only thing
  /// that tells them apart is the mailbox on the key.
  late List<MailSearch> asked;

  setUp(() => asked = <MailSearch>[]);

  Widget wrap({
    List<Map<String, dynamic>> inbox = const [],
    List<Map<String, dynamic>> boxes = const [],
    List<Map<String, dynamic>> thread = const [],
    List<Map<String, dynamic>> found = const [],
    List<Map<String, dynamic>> attachments = const [],
    String domain = 'iakauntan.com',
  }) => ProviderScope(
    overrides: [
      inboxProvider.overrideWith((ref) async => inbox),
      myMailboxesProvider.overrideWith((ref) async => boxes),
      mailDomainProvider.overrideWith((ref) async => domain),
      mailboxThreadProvider.overrideWith((ref, id) async => thread),
      mailSearchProvider.overrideWith((ref, MailSearch search) async {
        asked.add(search);
        return found;
      }),
      inboundAttachmentsProvider.overrideWith((ref, id) async => attachments),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const InboxScreen()),
  );

  /// Types into the search box and SUBMITS, which is the only thing
  /// that runs a query.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  group('which list is on the screen', () {
    testWidgets('everything that arrived, until an address is chosen', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          inbox: [arrived(subject: 'Everything list')],
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [threadRow(subject: 'One address')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Everything list'), findsOneWidget);
      expect(find.text('One address'), findsNothing);

      await tester.tap(find.text('aisyah@iakauntan.com'));
      await tester.pumpAndSettle();

      expect(find.text('One address'), findsOneWidget);
      expect(find.text('Everything list'), findsNothing);
    });

    testWidgets('a search beats the address, and is scoped to it', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          inbox: [arrived(subject: 'Everything list')],
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [threadRow(subject: 'One address')],
          found: [arrived(subject: 'What the search found')],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('aisyah@iakauntan.com'));
      await tester.pumpAndSettle();
      await search(tester, 'invoice');

      // The conversation is gone, not filtered underneath.
      expect(find.text('What the search found'), findsOneWidget);
      expect(find.text('One address'), findsNothing);

      // And the address went WITH the query. Searching everything from
      // inside one address would show a colleague's shared mail on a
      // screen the person had narrowed to their own.
      expect(asked, [(mailboxId: 'mb-aisyah', query: 'invoice')]);
    });

    testWidgets('and spans every address when none is chosen', (tester) async {
      await tester.pumpWidget(
        wrap(
          boxes: [mailbox()],
          found: [arrived(subject: 'What the search found')],
        ),
      );
      await tester.pumpAndSettle();
      await search(tester, 'invoice');

      expect(asked, [(mailboxId: null, query: 'invoice')]);
    });

    testWidgets('typing is not searching', (tester) async {
      // Every keystroke would be a full-text query over every body in
      // the company, and the word somebody is halfway through is not a
      // search anybody asked for.
      await tester.pumpWidget(
        wrap(
          inbox: [arrived(subject: 'Everything list')],
          boxes: [mailbox()],
          found: [arrived(subject: 'What the search found')],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'invo');
      await tester.pumpAndSettle();

      expect(asked, isEmpty);
      expect(find.text('Everything list'), findsOneWidget);
    });

    testWidgets('clearing a search puts the list back', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbox: [arrived(subject: 'Everything list')],
          boxes: [mailbox()],
          found: [arrived(subject: 'What the search found')],
        ),
      );
      await tester.pumpAndSettle();
      await search(tester, 'invoice');
      expect(find.text('Everything list'), findsNothing);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();

      expect(find.text('Everything list'), findsOneWidget);
      expect(find.text('What the search found'), findsNothing);
    });

    testWidgets('a search that matched nothing quotes what was asked', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(boxes: [mailbox()]));
      await tester.pumpAndSettle();
      await search(tester, 'perakuan');

      // Quoted back because the box may have been cleared by then, and
      // "nothing matched" on its own does not say matched WHAT.
      expect(find.text('No message here says "perakuan".'), findsOneWidget);
    });
  });

  group('the chips', () {
    testWidgets('are not drawn for a single address', (tester) async {
      // One address is not a choice. A chip row offering "everything"
      // and the only thing there is says the same thing twice.
      await tester.pumpWidget(wrap(inbox: [arrived()], boxes: [mailbox()]));
      await tester.pumpAndSettle();

      expect(find.text('Everything that arrived'), findsNothing);
      expect(find.text('sales@iakauntan.com'), findsNothing);
    });

    testWidgets('are drawn for two', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbox: [arrived()],
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Everything that arrived'), findsOneWidget);
      expect(find.text('sales@iakauntan.com'), findsOneWidget);
      expect(find.text('aisyah@iakauntan.com'), findsOneWidget);
    });

    testWidgets('carry the domain the database gave, not a literal', (
      tester,
    ) async {
      // `0328` made the domain a setting so a deployment under another
      // name would not need a migration edited; a literal in the app is
      // the same mistake one layer up.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          domain: 'kira.example',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('sales@kira.example'), findsOneWidget);
      expect(find.text('sales@iakauntan.com'), findsNothing);
    });
  });

  group('writing', () {
    testWidgets('is not offered to somebody with no address', (tester) async {
      // There is nothing to send FROM. `send_from_mailbox` would refuse
      // it, and a compose box that cannot be sent is worse than no
      // button.
      await tester.pumpWidget(wrap(inbox: [arrived()]));
      await tester.pumpAndSettle();

      expect(find.text('Write'), findsNothing);
    });

    testWidgets('is offered to somebody with one', (tester) async {
      await tester.pumpWidget(wrap(boxes: [mailbox()]));
      await tester.pumpAndSettle();

      expect(find.text('Write'), findsOneWidget);
    });
  });

  group('one line in the list', () {
    testWidgets('names who sent it, and who it went to', (tester) async {
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(id: 'in', subject: 'What came in'),
            threadRow(
              id: 'out',
              direction: 'out',
              subject: 'What went out',
              fromEmail: 'sales@iakauntan.com',
              fromName: 'Aisyah',
              toEmail: 'aminah@kedai.example',
              status: 'sent',
              handledAt: '2026-09-10T09:00:00Z',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      // Incoming: who sent it.
      expect(find.text('Puan Aminah'), findsOneWidget);
      // Outgoing: who it went TO. "From sales@" on every one of her own
      // sent messages says nothing at all.
      expect(find.text('To aminah@kedai.example · Sent'), findsOneWidget);
      expect(find.textContaining('To sales@iakauntan.com'), findsNothing);
    });

    testWidgets('falls back to the address when nobody signed it', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(inbox: [arrived(fromName: null)]));
      await tester.pumpAndSettle();

      expect(find.text('aminah@kedai.example'), findsOneWidget);
    });

    testWidgets('and to the address when the name is an empty string', (
      tester,
    ) async {
      // Not the same case. An ingest path that wrote '' rather than
      // null would leave the line blank on a `!= null` test.
      await tester.pumpWidget(wrap(inbox: [arrived(fromName: '')]));
      await tester.pumpAndSettle();

      expect(find.text('aminah@kedai.example'), findsOneWidget);
    });

    testWidgets('says so when there is no subject', (tester) async {
      await tester.pumpWidget(wrap(inbox: [arrived(subject: '')]));
      await tester.pumpAndSettle();

      expect(find.text('(no subject)'), findsOneWidget);
    });

    testWidgets('dates a row the everything-list gave', (tester) async {
      // `inbound_emails` is selected column by column, so the date on
      // one of its rows is `received_at`.
      await tester.pumpWidget(wrap(inbox: [arrived()]));
      await tester.pumpAndSettle();

      expect(find.text('10/09/2026'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('and one a conversation gave', (tester) async {
      // `mailbox_thread` calls the same fact `at`, because in the other
      // direction the column is when the message LEFT. Reading only one
      // of the two names leaves a whole list dated "—".
      //
      // A second `pumpWidget` inside the test above would have been the
      // obvious way to write this, and it is lesson 10 in
      // docs/widget-tests.md: the ProviderScope element is REUSED, so
      // the second scope's overrides never take and the chip the second
      // case needs is not on the screen. It was written that way first,
      // and failed on a missing chip rather than a missing date.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [threadRow(at: '2026-09-11T08:30:00Z')],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      expect(find.text('11/09/2026'), findsOneWidget);
      expect(find.text('—'), findsNothing);
    });

    testWidgets('says what became of something that left', (tester) async {
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(
              direction: 'out',
              toEmail: 'aminah@kedai.example',
              status: 'failed',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      final line = find.text('To aminah@kedai.example · Could not be sent');
      expect(line, findsOneWidget);

      // And in the error colour, because a queue that gave up is the
      // one line on this screen somebody has to act on.
      final scheme = AppTheme.light().colorScheme;
      expect(tester.widget<Text>(line).style?.color, scheme.error);
    });

    testWidgets('and colours an ordinary line ordinarily', (tester) async {
      // The control for the line above: without it, "red when failed"
      // passes against a screen that draws every line red.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(
              direction: 'out',
              toEmail: 'aminah@kedai.example',
              status: 'sent',
              handledAt: '2026-09-10T09:00:00Z',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      final scheme = AppTheme.light().colorScheme;
      final style = tester
          .widget<Text>(find.text('To aminah@kedai.example · Sent'))
          .style;
      expect(style?.color, scheme.onSurfaceVariant);
      expect(style?.color, isNot(scheme.error));
    });
  });

  group('what has been read', () {
    /// The weight on a subject line, which is the whole of the unread
    /// signal on this screen.
    FontWeight? weightOf(WidgetTester tester, String subject) =>
        tester.widget<Text>(find.text(subject)).style?.fontWeight;

    testWidgets('an unread message is heavier than a read one', (tester) async {
      // Both on one screen: a weight asserted against nothing beside it
      // passes against a list that draws every line the same.
      await tester.pumpWidget(
        wrap(
          inbox: [
            arrived(id: 'a', subject: 'Not yet read', readAt: null),
            arrived(
              id: 'b',
              subject: 'Read last Tuesday',
              readAt: '2026-09-09T10:00:00Z',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(weightOf(tester, 'Not yet read'), FontWeight.w700);
      expect(weightOf(tester, 'Read last Tuesday'), FontWeight.w500);
    });

    testWidgets('read is read under either column name', (tester) async {
      // `mailbox_thread` calls it `handled_at`. Reading only `read_at`
      // leaves every line of every conversation bold forever.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(id: 'a', subject: 'Not yet read'),
            threadRow(
              id: 'b',
              subject: 'Read last Tuesday',
              handledAt: '2026-09-09T10:00:00Z',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      expect(weightOf(tester, 'Not yet read'), FontWeight.w700);
      expect(weightOf(tester, 'Read last Tuesday'), FontWeight.w500);
    });

    testWidgets('and something that left is never unread', (tester) async {
      // A queued message has no `handled_at` until it is sent, and no
      // `read_at` ever. Without the direction guard everything the
      // person wrote comes back at them as unread mail.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(
              direction: 'out',
              subject: 'Still in the outbox',
              status: 'queued',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      expect(weightOf(tester, 'Still in the outbox'), FontWeight.w500);
    });
  });

  group('opening one', () {
    testWidgets('shows the plain text and offers a reply', (tester) async {
      await tester.pumpWidget(wrap(inbox: [arrived()]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.text('When is this due?'), findsOneWidget);
      expect(
        find.text('From aminah@kedai.example\nTo sales@iakauntan.com'),
        findsOneWidget,
      );
      expect(find.text('Reply'), findsOneWidget);
    });

    testWidgets('says so when there was no plain-text part', (tester) async {
      // Deliberately not the HTML. Rendering a stranger's markup is how
      // a reader becomes an attack surface; a blank dialog is how
      // somebody concludes the message is broken.
      await tester.pumpWidget(wrap(inbox: [arrived(body: '   ')]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.text('This message had no plain-text part.'), findsOneWidget);
    });

    testWidgets('offers no reply to something that left', (tester) async {
      // Replying to your own sent message means writing to yourself.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(
              direction: 'out',
              subject: 'What went out',
              fromEmail: 'sales@iakauntan.com',
              toEmail: 'aminah@kedai.example',
              status: 'sent',
              handledAt: '2026-09-10T09:00:00Z',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('What went out'));
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
    });

    testWidgets('offers no reply when nothing says which address to '
        'send from', (tester) async {
      // A row from before `0328` carried no mailbox. `send_from_mailbox`
      // takes the mailbox and not the address, so there is nothing to
      // call it with — and a Reply button that raises "there is no such
      // mailbox" is worse than none.
      await tester.pumpWidget(wrap(inbox: [arrived(mailboxId: null)]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Reply'), findsNothing);
    });

    testWidgets('takes the address from the chip in a conversation', (
      tester,
    ) async {
      // `mailbox_thread` returns no `mailbox_id` — the thread is one
      // mailbox and the function does not repeat it on every line. So
      // the screen supplies it, and without that every conversation
      // loses its Reply button.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [threadRow()],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.text('Reply'), findsOneWidget);
    });
  });

  group('what came attached', () {
    testWidgets('is listed under something that arrived', (tester) async {
      await tester.pumpWidget(
        wrap(
          inbox: [arrived()],
          attachments: [
            {
              'filename': 'invoice.pdf',
              'content_type': 'application/pdf',
              'size_bytes': 20480,
              'storage_path': 'org/mail/e1/invoice.pdf',
            },
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.text('1 attachment'), findsOneWidget);
      expect(find.text('invoice.pdf'), findsOneWidget);
      expect(find.text('PDF · 20 KB'), findsOneWidget);
    });

    testWidgets('and no section at all when there is nothing', (tester) async {
      await tester.pumpWidget(wrap(inbox: [arrived()]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('About invoice INV-0042'));
      await tester.pumpAndSettle();

      expect(find.textContaining('attachment'), findsNothing);
    });

    testWidgets('and is not read for something that left', (tester) async {
      // `inbound_attachments` takes the id of an INBOUND email. An
      // outgoing row's id is an `email_outbox` id, so asking for its
      // attachments is asking the wrong table about the wrong row --
      // and a fixture that answers anyway is exactly how that goes
      // unnoticed.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
          thread: [
            threadRow(
              direction: 'out',
              subject: 'What went out',
              toEmail: 'aminah@kedai.example',
              status: 'sent',
              handledAt: '2026-09-10T09:00:00Z',
            ),
          ],
          attachments: [
            {
              'filename': 'invoice.pdf',
              'content_type': 'application/pdf',
              'size_bytes': 20480,
              'storage_path': 'org/mail/t1/invoice.pdf',
            },
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sales@iakauntan.com'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('What went out'));
      await tester.pumpAndSettle();

      expect(find.text('invoice.pdf'), findsNothing);
      expect(find.textContaining('attachment'), findsNothing);
    });
  });

  group('when there is nothing', () {
    testWidgets('the everything-list says where mail comes from', (
      tester,
    ) async {
      await tester.pumpWidget(wrap(boxes: [mailbox()]));
      await tester.pumpAndSettle();

      expect(find.text('Nothing has arrived yet'), findsOneWidget);
      expect(
        find.textContaining('Ask for an address in Settings'),
        findsOneWidget,
      );
    });

    testWidgets('and an empty conversation says both directions', (
      tester,
    ) async {
      // Different words from the list above, on purpose: this address
      // has neither received nor sent, and "nothing has arrived" alone
      // would leave somebody looking for their sent items.
      await tester.pumpWidget(
        wrap(
          boxes: [
            mailbox(),
            mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('aisyah@iakauntan.com'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('Nothing has arrived yet'), findsNothing);
    });
  });

  testWidgets('renders at phone width', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(393, 852);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(
        inbox: [
          arrived(
            subject: 'A subject long enough to need the ellipsis it has',
            fromName: 'Puan Aminah binti Abdul Rahman Sdn Bhd',
          ),
        ],
        boxes: [
          mailbox(),
          mailbox(id: 'mb-aisyah', localPart: 'aisyah'),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(InboxScreen), findsOneWidget);
  });
}
