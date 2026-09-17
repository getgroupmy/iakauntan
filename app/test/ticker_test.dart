import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/dashboard/ticker.dart';

/// The day's figures, running across the top of the dashboard.
///
/// Asserted on the pure function rather than the widget, because what is
/// worth getting wrong here is not the animation: it is WHICH figures
/// appear, whether they are formatted as money, and whether each is
/// painted as good news or bad. A ticker that paints rising overdue debt
/// green is one nobody reads twice.
void main() {
  DashboardSummary summary(Map<String, dynamic> over) => DashboardSummary({
    'revenue': 0,
    'expenses': 0,
    'receivables': 0,
    'payables': 0,
    'overdue_receivables': 0,
    'bank_balance': 0,
    'draft_invoices': 0,
    'einvoice_pending': 0,
    'einvoice_invalid': 0,
    'low_stock': 0,
    ...over,
  });

  TickerItem itemFor(List<TickerItem> items, String label) =>
      items.firstWhere((i) => i.label == label);

  test('money is money, not a bare number', () {
    final items = tickerItems(
      summary({'bank_balance': 1234.5, 'receivables': 900}),
      currency: 'MYR',
    );
    expect(itemFor(items, 'Cash at bank').value, 'RM 1,234.50');
    expect(itemFor(items, 'Owed to you').value, 'RM 900.00');
  });

  test('a zero is still a figure', () {
    // "Overdue RM 0.00" is worth reading: it is the answer to a question
    // somebody has, and leaving it out makes them go and look.
    final items = tickerItems(summary({}), currency: 'MYR');
    expect(itemFor(items, 'Overdue').value, 'RM 0.00');
    expect(itemFor(items, 'Overdue').good, isTrue);
  });

  test('overdue debt is bad news when there is any', () {
    final items =
        tickerItems(summary({'overdue_receivables': 500}), currency: 'MYR');
    expect(itemFor(items, 'Overdue').good, isFalse);
  });

  test('an overdrawn account and a loss are bad news', () {
    final items = tickerItems(
      summary({'bank_balance': -20, 'revenue': 100, 'expenses': 400}),
      currency: 'MYR',
    );
    expect(itemFor(items, 'Cash at bank').good, isFalse);
    expect(itemFor(items, 'Profit this year').good, isFalse);
    // The prefix goes first and the sign lands on the number: 'RM -300.00'.
    // Asserted as it actually reads rather than as one might assume,
    // because a receipt is read by a person and this is the string.
    expect(itemFor(items, 'Profit this year').value, 'RM -300.00');
  });

  test('what a company cannot have is left out, not shown as zero', () {
    // A business with no stock module has no low-stock count, and a
    // zero there is a lie rather than good news.
    final without = tickerItems(summary({'low_stock': 0}), currency: 'MYR');
    expect(without.where((i) => i.label == 'Low stock'), isEmpty);

    final with_ = tickerItems(
      summary({'low_stock': 3}),
      currency: 'MYR',
      showStock: true,
    );
    expect(itemFor(with_, 'Low stock').value, '3');
    expect(itemFor(with_, 'Low stock').good, isFalse);
  });

  test('a rejected e-Invoice only appears for a company that files', () {
    final without =
        tickerItems(summary({'einvoice_invalid': 2}), currency: 'MYR');
    expect(without.where((i) => i.label == 'e-Invoice rejected'), isEmpty);

    final with_ = tickerItems(
      summary({'einvoice_invalid': 2}),
      currency: 'MYR',
      showEinvoice: true,
    );
    expect(itemFor(with_, 'e-Invoice rejected').value, '2');
  });

  test('drafts appear only when there are some', () {
    expect(
      tickerItems(summary({}), currency: 'MYR')
          .where((i) => i.label == 'Drafts unposted'),
      isEmpty,
    );
    expect(
      itemFor(
        tickerItems(summary({'draft_invoices': 4}), currency: 'MYR'),
        'Drafts unposted',
      ).value,
      '4',
    );
  });

  test('the to-do count says overdue only when something is', () {
    expect(
      itemFor(tickerItems(summary({}), currency: 'MYR', openTodos: 3), 'To do')
          .value,
      '3 open',
    );
    final late = itemFor(
      tickerItems(summary({}), currency: 'MYR', openTodos: 3, overdueTodos: 1),
      'To do',
    );
    expect(late.value, '3 open, 1 overdue');
    expect(late.good, isFalse);
  });

  test('a company keeping books in another currency is shown that one', () {
    final items = tickerItems(summary({'bank_balance': 10}), currency: 'SGD');
    expect(itemFor(items, 'Cash at bank').value, contains('SGD'));
  });
}
