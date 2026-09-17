import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/financials/fs_mapping.dart';

Account account(
  String id, {
  String code = '5100',
  String name = 'Staff costs',
  String type = 'expense',
  String subtype = 'payroll_expense',
  bool isGroup = false,
}) => Account(
  id: id,
  code: code,
  name: name,
  accountType: type,
  accountSubtype: subtype,
  isGroup: isGroup,
);

void main() {
  group('the default mapping', () {
    // Every arm of app.fs_default_element, because the whole point of
    // mirroring it in Dart is that the screen shows what the export
    // will do, and a drifted copy shows the wrong thing confidently.
    const bySubtype = {
      'fixed_asset': 'PropertyPlantAndEquipment',
      'accumulated_depreciation': 'PropertyPlantAndEquipment',
      'other_asset': 'OtherNonCurrentAssets',
      'inventory': 'Inventories',
      'accounts_receivable': 'TradeAndOtherReceivables',
      'bank': 'CashAndCashEquivalents',
      'cash': 'CashAndCashEquivalents',
      'current_asset': 'OtherCurrentAssets',
      'accounts_payable': 'TradeAndOtherPayables',
      'tax_payable': 'CurrentTaxLiabilities',
      'current_liability': 'OtherCurrentLiabilities',
      'long_term_liability': 'LoansAndBorrowings',
      'other_liability': 'OtherNonCurrentLiabilities',
      'share_capital': 'ShareCapital',
      'reserves': 'Reserves',
      'retained_earnings': 'RetainedEarnings',
      'drawings': 'RetainedEarnings',
      'sales': 'Revenue',
      'cost_of_sales': 'CostOfSales',
      'other_income': 'OtherIncome',
      'operating_expense': 'AdministrativeExpenses',
      'payroll_expense': 'StaffCosts',
      'depreciation_expense': 'DepreciationAndAmortisation',
      'finance_cost': 'FinanceCosts',
      'other_expense': 'OtherOperatingExpenses',
      'tax_expense': 'TaxExpense',
    };

    bySubtype.forEach((subtype, element) {
      test('$subtype reports as $element', () {
        expect(fsDefaultElement('asset', subtype), element);
      });
    });

    test('accumulated depreciation lands where the cost it relieves does', () {
      // The face of the statement shows carrying amount; the split is
      // a note.
      expect(
        fsDefaultElement('asset', 'accumulated_depreciation'),
        fsDefaultElement('asset', 'fixed_asset'),
      );
    });

    test('drawings land on retained earnings', () {
      // Debit-natural equity, so it comes back negative and correctly
      // reduces retained earnings rather than needing its own sign.
      expect(
        fsDefaultElement('equity', 'drawings'),
        fsDefaultElement('equity', 'retained_earnings'),
      );
    });

    test('the subtype decides, not the type', () {
      // fs_default_element reads the subtype first and only falls back
      // on the type, so a mistyped account still lands where its
      // subtype says.
      expect(fsDefaultElement('expense', 'bank'), 'CashAndCashEquivalents');
    });
  });

  group('an account with no subtype', () {
    test('still lands somewhere defensible', () {
      // Rather than vanishing off the face of the statement.
      expect(fsDefaultElement('asset', null), 'OtherCurrentAssets');
      expect(fsDefaultElement('liability', null), 'OtherCurrentLiabilities');
      expect(fsDefaultElement('equity', null), 'Reserves');
      expect(fsDefaultElement('revenue', null), 'OtherIncome');
      expect(fsDefaultElement('expense', null), 'OtherOperatingExpenses');
    });

    test('an unknown subtype falls through to the type', () {
      expect(fsDefaultElement('revenue', 'not_a_subtype'), 'OtherIncome');
    });

    test('and an unknown type reports nowhere', () {
      expect(fsDefaultElement('imaginary', null), isNull);
    });
  });

  group('what an account actually reports under', () {
    test('the default when nothing was said', () {
      expect(
        fsElementFor(type: 'expense', subtype: 'payroll_expense'),
        'StaffCosts',
      );
    });

    test('the override when there is one', () {
      expect(
        fsElementFor(
          type: 'expense',
          subtype: 'payroll_expense',
          override: 'CostOfSales',
        ),
        'CostOfSales',
      );
    });

    test('an override wins even where there is no default to beat', () {
      expect(
        fsElementFor(type: 'imaginary', override: 'Reserves'),
        'Reserves',
      );
    });
  });

  group('whether an override is doing anything', () {
    test('one that moves the account is', () {
      expect(
        fsOverrideChangesAnything('CostOfSales', 'expense', 'payroll_expense'),
        isTrue,
      );
    });

    test('one that names the default is not', () {
      // A row saying what would have happened anyway is a row somebody
      // has to read and reason about for no gain.
      expect(
        fsOverrideChangesAnything('StaffCosts', 'expense', 'payroll_expense'),
        isFalse,
      );
    });

    test('no override is not', () {
      expect(
        fsOverrideChangesAnything(null, 'expense', 'payroll_expense'),
        isFalse,
      );
    });
  });

  group('finding an override', () {
    final map = [
      {'account_id': 'a1', 'element_code': 'CostOfSales'},
      {'account_id': 'a2', 'element_code': 'FinanceCosts'},
    ];

    test('by account', () {
      expect(fsOverrideFor(map, 'a2'), 'FinanceCosts');
    });

    test('nothing for an account that was never moved', () {
      expect(fsOverrideFor(map, 'a3'), isNull);
    });

    test('an empty table means the standard chart, not an unmapped one', () {
      expect(fsOverrideFor(const [], 'a1'), isNull);
      expect(
        fsElementFor(
          type: 'expense',
          subtype: 'payroll_expense',
          override: fsOverrideFor(const [], 'a1'),
        ),
        'StaffCosts',
      );
    });
  });

  group('which accounts can be mapped', () {
    test('not a heading, which carries no balance of its own', () {
      final list = mappableAccounts([
        account('a1', code: '5000', isGroup: true),
        account('a2', code: '5100'),
      ]);
      expect(list.map((a) => a.id), ['a2']);
    });

    test('a retired account stays, because last year came from it', () {
      final list = mappableAccounts([account('a1')]);
      expect(list, hasLength(1));
    });
  });
}
