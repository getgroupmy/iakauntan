import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/chat/chat_screen.dart';

/// What a thread shows once a message has been edited or taken back.
///
/// The rules are in 0144 and asserted in `supabase/tests/chat.sql`,
/// where they belong — the database is what refuses an edit past the
/// window, and a screen that merely hides the button proves nothing.
/// What is asserted here is the half a person reads: that a deleted
/// message keeps its place and says what happened rather than vanishing
/// out of the middle of a conversation somebody has already read, and
/// that its words and its attachment are not on screen.
void main() {
  Map<String, dynamic> message({
    required String id,
    String? body,
    bool mine = true,
    bool deleted = false,
    String? editedAt,
    List<Map<String, dynamic>> attachments = const [],
    Duration age = const Duration(minutes: 1),
  }) => {
    'id': id,
    'sender_id': mine ? 'me' : 'them',
    'sender_name': mine ? 'Me' : 'Siti Nurhaliza',
    'sender_org_id': 'o1',
    'body': body,
    'kind': 'text',
    'created_at': DateTime.now().subtract(age).toIso8601String(),
    'edited_at': editedAt,
    'deleted': deleted,
    'is_mine': mine,
    'state': 'read',
    'attachments': attachments,
  };

  Widget harness(List<Map<String, dynamic>> rows) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(null),
      // Null, so `chatLiveProvider` returns without opening a socket.
      // Otherwise it reaches `supabaseProvider`, and there is no
      // Supabase instance in a widget test.
      currentUserProvider.overrideWithValue(null),
      // The call buttons in the thread's app bar read the company and
      // throw while it is loading. This is a test of the bubbles, so it
      // is handed one.
      currentOrgProvider.overrideWith(
        (ref) async => Organization(
          id: 'o1',
          name: 'Sinar Teknologi Sdn Bhd',
          slug: 'sinar',
          baseCurrency: 'MYR',
        ),
      ),
      chatConversationsProvider.overrideWith(
        (ref) async => [
          {'conversation_id': 'c1', 'is_direct': true, 'other_name': 'Siti'},
        ],
      ),
      // No call in progress. Without this the buttons read an errored
      // provider and rethrow while the company is still loading.
      chatActiveCallProvider('c1').overrideWith((ref) async => null),
      chatThreadProvider('c1').overrideWith((ref) async => rows),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ChatScreen()),
  );

  /// The thread lives behind the conversation list on a narrow screen,
  /// so the test drives a wide one and opens the row.
  Future<void> open(
    WidgetTester tester,
    List<Map<String, dynamic>> rows,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(rows));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('chat-c1')));
    await tester.pumpAndSettle();
  }

  testWidgets('a deleted message keeps its place and says what happened', (
    tester,
  ) async {
    await open(tester, [
      message(id: 'm2', body: null, deleted: true),
      message(id: 'm1', body: 'still here'),
    ]);

    expect(find.text('Message deleted'), findsOneWidget);
    expect(
      find.text('still here'),
      findsOneWidget,
      reason: 'the rest of the conversation is untouched — the control',
    );
  });

  testWidgets('and shows neither its words nor its attachment', (tester) async {
    // The database blanks the body and drops the attachment rows, so
    // neither should arrive — but if a stale cache ever handed them over
    // the screen must still not draw them.
    await open(tester, [
      message(
        id: 'm1',
        body: 'the account number is 1234',
        deleted: true,
        attachments: [
          {
            'id': 'a1',
            'file_name': 'payslip.pdf',
            'storage_path': 'c1/payslip.pdf',
            'mime_type': 'application/pdf',
            'file_size': 10,
          },
        ],
      ),
    ]);

    expect(find.textContaining('account number'), findsNothing);
    expect(find.text('payslip.pdf'), findsNothing);
  });

  testWidgets('an edited message is marked, and a deleted one is not marked '
      'twice', (tester) async {
    await open(tester, [
      message(
        id: 'm1',
        body: 'corrected',
        editedAt: DateTime.now().toIso8601String(),
      ),
    ]);
    expect(find.textContaining('edited'), findsOneWidget);
  });

  testWidgets('a deleted message says deleted rather than edited', (
    tester,
  ) async {
    // Deleting stamps nothing, but a message edited and *then* deleted
    // carries both marks in the row. "edited" beside "Message deleted"
    // reads as though the deletion were the edit.
    await open(tester, [
      message(
        id: 'm1',
        body: null,
        deleted: true,
        editedAt: DateTime.now().toIso8601String(),
      ),
    ]);

    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.textContaining('edited'), findsNothing);
  });

  testWidgets('the menu offers an edit on a fresh message of your own', (
    tester,
  ) async {
    await open(tester, [message(id: 'm1', body: 'typo')]);

    await tester.longPress(find.text('typo'));
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('and says why it does not on an old one, rather than offering '
      'an edit the database refuses', (tester) async {
    await open(tester, [
      message(
        id: 'm1',
        body: 'said an hour ago',
        age: const Duration(hours: 1),
      ),
    ]);

    await tester.longPress(find.text('said an hour ago'));
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsNothing);
    expect(find.text('Too old to edit'), findsOneWidget);
    expect(
      find.text('Delete'),
      findsOneWidget,
      reason:
          'deleting has no window — it takes something out of the '
          'record rather than changing what the record says',
    );
  });

  testWidgets('there is no menu on somebody else\'s message', (tester) async {
    await open(tester, [message(id: 'm1', body: 'their words', mine: false)]);

    await tester.longPress(find.text('their words'));
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('and none on one already deleted', (tester) async {
    await open(tester, [message(id: 'm1', body: null, deleted: true)]);

    await tester.longPress(find.text('Message deleted'));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsNothing);
  });
}
