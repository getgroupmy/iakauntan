import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/module_offer.dart';
import 'package:iakauntan/src/features/settings/subscription_summary.dart';

/// What the settings screen says about the bill.
///
/// 0488 told an owner "RM 39.00 a month is added to this company from
/// today" and nothing billed it. 0489 raises the invoice on the first
/// of the following month, which leaves a month in which the price has
/// been agreed to and there is nothing to look at. These are the
/// sentences that fill it, and the arithmetic behind the figure beside
/// them.
void main() {
  ModuleSurface mod({String name = 'Multi-Company', double price = 39}) =>
      ModuleSurface(
        code: 'multi_company',
        name: name,
        isCore: false,
        monthlyPrice: price,
        entitled: false,
        hidden: false,
        visible: true,
      );

  Map<String, dynamic> chargeMap({
    String code = 'multi_company',
    String name = 'Multi-Company',
    int days = 12,
    int daysInMonth = 31,
    double amount = 15.10,
  }) => {
    'module_code': code,
    'name': name,
    'days': days,
    'days_in_month': daysInMonth,
    'monthly_price': 39,
    'amount': amount,
  };

  SubscriptionMonth month({
    String on = '2026-01-01',
    List<Map<String, dynamic>>? lines,
    double subtotal = 15.10,
  }) => SubscriptionMonth.fromMap({
    'month': on,
    'lines': lines ?? [chargeMap()],
    'subtotal': subtotal,
  });

  group('the month in progress', () {
    test('the server\'s figures come across as they are', () {
      final s = month();
      expect(s.month, DateTime(2026, 1, 1));
      expect(s.subtotal, 15.10);
      expect(s.lines.single.code, 'multi_company');
      expect(s.lines.single.days, 12);
      expect(s.lines.single.daysInMonth, 31);
    });

    test('a payload with nothing in it is not an error', () {
      final s = SubscriptionMonth.fromMap(const {});
      expect(s.lines, isEmpty);
      expect(s.subtotal, 0);
      expect(s.month, isNull);
    });

    test('holding nothing is said in words, not shown as RM 0.00', () {
      // A zero where a price belongs reads as a fault in the figure
      // rather than as an absence of one.
      expect(
        subscriptionRunningTotal(month(lines: const [], subtotal: 0)),
        'Nothing this month',
      );
      expect(subscriptionRunningTotal(month()), 'RM 15.10');
    });

    test('the figure is dated, and said not to be an invoice yet', () {
      final line = subscriptionRunningLine(month());
      expect(line, contains('Jan 2026'));
      expect(line, contains('first of next month'));
    });

    test('and a company holding nothing is told why it is nothing', () {
      final line = subscriptionRunningLine(month(lines: const [], subtotal: 0));
      expect(line, contains('No paid add-ons'));
      expect(line, contains('Jan 2026'));
    });

    test('the days are shown only where they explain the amount', () {
      // A part month needs them; a whole month is simply its price, and
      // "31 of 31 days" beside it is noise.
      expect(
        subscriptionChargeLine(ModuleCharge.fromMap(chargeMap())),
        'Multi-Company · 12 of 31 days',
      );
      expect(
        subscriptionChargeLine(
          ModuleCharge.fromMap(chargeMap(days: 31, amount: 39)),
        ),
        'Multi-Company',
      );
    });
  });

  group('the invoices', () {
    Map<String, dynamic> inv(String status, double total) => {
      'id': status,
      'invoice_no': 'KH-2026-0001',
      'status': status,
      'total_amount': total,
    };

    test('only what is issued is owed', () {
      expect(subscriptionInvoiceOwing(inv('issued', 10)), isTrue);
      expect(subscriptionInvoiceOwing(inv('paid', 10)), isFalse);
      // Withdrawn, not settled: it counts towards neither.
      expect(subscriptionInvoiceOwing(inv('void', 10)), isFalse);
    });

    test('the outstanding total leaves out what is paid and what is void', () {
      expect(
        subscriptionOutstanding([
          inv('issued', 16.31),
          inv('paid', 39.00),
          inv('void', 99.00),
          inv('issued', 3.69),
        ]),
        20.0,
      );
    });

    test('the word beside each one', () {
      expect(subscriptionInvoiceStatus(inv('issued', 1)), 'Due');
      expect(subscriptionInvoiceStatus(inv('paid', 1)), 'Paid');
      expect(subscriptionInvoiceStatus(inv('void', 1)), 'Cancelled');
    });
  });

  group('taking an add-on off', () {
    // 0488's own copy said "you can take it off here too" and there was
    // no way to do it. What the confirmation has to settle is the two
    // things somebody is actually afraid of.
    test('the charge stops, and the records do not go with it', () {
      final prompt = removeModulePrompt(mod());
      expect(prompt, contains('RM 39.00 a month stops'));
      expect(prompt, contains('billed for the days it was on'));
      expect(prompt, contains('Nothing already recorded is deleted'));
    });

    test('a module with no price does not talk about money', () {
      final prompt = removeModulePrompt(mod(name: 'Chat', price: 0));
      expect(prompt, isNot(contains('RM')));
      expect(prompt, contains('Nothing already recorded is deleted'));
    });

    test('the title names the module', () {
      expect(removeModuleTitle(mod()), 'Remove Multi-Company?');
    });
  });
}
