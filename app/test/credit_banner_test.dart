import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/documents/credit_banner_state.dart';

/// Say a customer is on hold before the invoice is typed.
///
/// `enforce_credit_limit` refuses a held customer above the credit
/// control mode and above the limit arithmetic. The banner did not: it
/// returned early when no limit was set, when control was off, and when
/// the balance was not yet near the limit — and a customer on hold
/// usually has no limit at all, because the hold *is* the decision. So
/// the whole invoice got typed and Post said no.
void main() {
  Map<String, dynamic> status({
    String control = 'warn',
    num limit = 0,
    num outstanding = 0,
    num? available,
    bool over = false,
    bool? hold,
    String? name = 'Pelanggan Tertahan',
  }) => {
    'control': control,
    'credit_limit': limit,
    'outstanding': outstanding,
    'available': available,
    'over_limit': over,
    if (hold != null) 'credit_hold': hold,
    'contact_name': name,
  };

  test('nothing loaded yet says nothing', () {
    expect(creditBannerFor(null).shows, isFalse);
  });

  group('a customer on hold', () {
    test('is shown even with no limit set at all', () {
      // The case the defect was about. Every reason to stay quiet
      // applies at once.
      final s = creditBannerFor(status(hold: true, limit: 0));
      expect(s.kind, CreditBannerKind.hold);
      expect(s.contactName, 'Pelanggan Tertahan');
    });

    test('is shown with credit control off', () {
      // The trigger raises before it reads the mode, so this banner
      // must not be gated on one.
      expect(
        creditBannerFor(status(hold: true, control: 'off')).kind,
        CreditBannerKind.hold,
      );
    });

    test('is shown with plenty of credit left', () {
      // Nowhere near the limit, which is the third thing that used to
      // silence it.
      final s = creditBannerFor(
        status(hold: true, control: 'block', limit: 10000, available: 9000),
      );
      expect(s.kind, CreditBannerKind.hold);
    });

    test('outranks being over the limit', () {
      // Both true. The hold is the one to say, because it is the one
      // with a different answer — somebody takes it off, rather than
      // raising a limit or taking a payment.
      final s = creditBannerFor(
        status(
          hold: true,
          control: 'block',
          limit: 1000,
          outstanding: 5000,
          available: -4000,
          over: true,
        ),
      );
      expect(s.kind, CreditBannerKind.hold);
    });

    test('survives the key being missing, as silence not as a hold', () {
      // An older server that does not send `credit_hold` must not draw
      // a hold banner against everybody.
      expect(creditBannerFor(status(limit: 0)).shows, isFalse);
    });
  });

  group('the limit, which still behaves as it did', () {
    test('no limit set says nothing', () {
      expect(creditBannerFor(status(limit: 0, hold: false)).shows, isFalse);
    });

    test('control off says nothing', () {
      expect(
        creditBannerFor(
          status(control: 'off', limit: 1000, available: 0, over: true),
        ).shows,
        isFalse,
      );
    });

    test('plenty of room says nothing', () {
      expect(
        creditBannerFor(status(limit: 10000, available: 9000)).shows,
        isFalse,
      );
    });

    test('close to the limit warns', () {
      final s = creditBannerFor(
        status(limit: 10000, outstanding: 9500, available: 500),
      );
      expect(s.kind, CreditBannerKind.near);
      expect(s.available, 500);
      expect(s.outstanding, 9500);
      expect(s.blocked, isFalse);
    });

    test('over the limit is over, and says whether posting is blocked', () {
      final s = creditBannerFor(
        status(
          control: 'block',
          limit: 1000,
          outstanding: 4000,
          available: -3000,
          over: true,
        ),
      );
      expect(s.kind, CreditBannerKind.over);
      expect(s.blocked, isTrue);
      expect(s.available, -3000);
    });

    test('over the limit in warn mode is not blocked', () {
      // Two different sentences on the screen; a warn-mode banner that
      // says posting is blocked is a lie that costs a phone call.
      final s = creditBannerFor(
        status(limit: 1000, outstanding: 4000, available: -3000, over: true),
      );
      expect(s.kind, CreditBannerKind.over);
      expect(s.blocked, isFalse);
    });
  });
}
