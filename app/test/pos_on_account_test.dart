import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/pos/on_account.dart';

/// The one question the tender sheet has to answer before it lets a
/// cashier press Take it: is there a customer for this to go on?
void main() {
  Map<String, dynamic> tender(String kind) => {'id': 't', 'kind': kind};

  group('whether a sale may go on an account', () {
    test('cash and card are never blocked, whoever the customer is', () {
      // The guard belongs to one tender kind. Applied to all of them it
      // would stop every anonymous sale in the shop.
      for (final k in const ['cash', 'card', 'ewallet', 'loyalty']) {
        expect(
          onAccountBlockedBecause(
            tenderType: tender(k),
            saleContact: null,
            chosenContact: null,
          ),
          isNull,
          reason: k,
        );
      }
    });

    test('an account sale with nobody on it is blocked, and says why', () {
      final why = onAccountBlockedBecause(
        tenderType: tender('on_account'),
        saleContact: null,
        chosenContact: null,
      );
      expect(why, isNotNull);
      // The sentence, not just its presence. It is what a cashier reads
      // while somebody waits, and "invalid input" would send them to
      // find a manager.
      expect(why, contains('whose account'));
    });

    test('and unblocked by a customer from either place', () {
      // The basket was already billed to somebody.
      expect(
        onAccountBlockedBecause(
          tenderType: tender('on_account'),
          saleContact: 'c1',
          chosenContact: null,
        ),
        isNull,
      );
      // Or the cashier picked one at the tender sheet.
      expect(
        onAccountBlockedBecause(
          tenderType: tender('on_account'),
          saleContact: null,
          chosenContact: 'c2',
        ),
        isNull,
      );
    });

    test('a tender that has not loaded blocks nothing', () {
      // Null is the first frame, not an error. Blocking on it would
      // grey out Take it every time the sheet opened.
      expect(
        onAccountBlockedBecause(
          tenderType: null,
          saleContact: null,
          chosenContact: null,
        ),
        isNull,
      );
    });
  });

  group('what the receipt says', () {
    test('nothing at all when money changed hands', () {
      expect(onAccountNote(onAccount: 0), isNull);
    });

    test('and names it when none did', () {
      // "Change RM0.00" reads as a completed cash sale on the one screen
      // a cashier checks before handing the bag over.
      expect(onAccountNote(onAccount: 20), 'On account');
    });
  });

  test('the kind is spelled the way the enum spells it', () {
    // A typo here does not fail — `isOnAccount` simply never matches, and
    // the guard silently stops guarding.
    expect(kOnAccount, 'on_account');
    expect(isOnAccount({'kind': 'on_account'}), isTrue);
    expect(isOnAccount({'kind': 'onaccount'}), isFalse);
    expect(isOnAccount(null), isFalse);
  });
}
