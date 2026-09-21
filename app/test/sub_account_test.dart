/// Filing an account under another one — the app's half.
///
/// The rule lives in the database: `0655` refuses to put a child under
/// an account that has postings, an opening balance, or a number the
/// ledger resolves by, and `supabase/tests/sub_accounts.sql` asserts
/// every one of those with the reasons written down.
///
/// What is asserted here is what somebody is TOLD, and the depth of the
/// chart they end up looking at:
///
///   * the promotion note, which has to appear exactly when the parent
///     is about to stop being postable and not otherwise — a warning
///     that shows on every account is a warning people learn to skip;
///   * the indent, read from the code, which is what makes four levels
///     of chart read as a shape rather than as a column of
///     increasingly long numbers.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/sub_account_dialog.dart';

void main() {
  Account account({
    String code = '1120',
    String name = 'Bank accounts',
    bool isGroup = false,
  }) => Account(
    id: 'a-$code',
    code: code,
    name: name,
    accountType: 'asset',
    accountSubtype: 'bank',
    isGroup: isGroup,
  );

  group('what somebody is warned about', () {
    test('a posting account is about to stop being one', () {
      final note = promotionNote(account());
      expect(note, isNotNull);
      expect(note, contains('1120'));
      expect(note, contains('Bank accounts'));
      expect(note!.toLowerCase(), contains('heading'));
      // The consequence, not just the word. "Becomes a heading" means
      // nothing to somebody who has not read `0014`.
      expect(note.toLowerCase(), contains('cannot be posted to'));
    });

    test('and a heading is not, because nothing changes', () {
      // The half that keeps the warning worth reading. A note on every
      // account is a note nobody reads, and on a heading it would be
      // describing something that happened long ago.
      expect(promotionNote(account(isGroup: true)), isNull);
    });

    test('the note says no report moves, which is why it is allowed', () {
      // The reassurance is load-bearing: "this account stops being
      // postable" sounds like data loss, and the reason `0655` permits
      // it at all is that the balance is zero.
      expect(
        promotionNote(account())!.toLowerCase(),
        contains('no report changes'),
      );
    });

    test('and the dialog says where the new account is going', () {
      expect(subAccountBlurb(account()), 'Filed under 1120 Bank accounts.');
    });

    test('and what happens if the number is left empty', () {
      expect(codeHint(account()), contains('1120'));
    });
  });

  group('how deep a code sits', () {
    test('a top-level account is not indented', () {
      expect(chartIndentDepth('1120'), 0);
    });

    test('and each level of the request\'s example is one deeper', () {
      expect(chartIndentDepth('1120-1000'), 1);
      expect(chartIndentDepth('1120-1000-1000'), 2);
      expect(chartIndentDepth('1120-1000-1000-1000'), 3);
      expect(chartIndentDepth('1120-1000-1000-1000-1000'), 4);
    });

    test('a hand-typed code indents by its shape, like any other', () {
      expect(chartIndentDepth('9500-JALAN'), 1);
    });

    test('and nothing odd sends the row off the side of the screen', () {
      // A blank code, a stray hyphen, trailing space. The chart is a
      // table somebody may have imported, and an indent computed from
      // a bad string must not be a negative padding — which throws —
      // or a hundred pixels of nothing.
      expect(chartIndentDepth(''), 0);
      expect(chartIndentDepth('-'), 0);
      expect(chartIndentDepth('---'), 0);
      expect(chartIndentDepth('  1120  '), 0);
      expect(chartIndentDepth('1120-'), 0);
      for (final code in ['', '-', '---', '1120-', '  ']) {
        expect(chartIndentDepth(code), greaterThanOrEqualTo(0), reason: code);
      }
    });
  });
}
