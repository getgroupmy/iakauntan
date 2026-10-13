import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/repository.dart';

/// `0858`. A bank account's balance is withheld from every client read
/// of `bank_accounts` and given by `bank_balances` to a role that reads
/// the ledger. `Repo.withBankBalances` puts the one beside the other.
void main() {
  // Ids that are nothing like the names or numbers beside them, so a
  // merge that matched on the wrong key could not pass by accident.
  const accounts = [
    {'id': 'ba-1', 'name': 'Maybank Current', 'account_id': 'gl-1'},
    {'id': 'ba-2', 'name': 'CIMB Savings', 'account_id': 'gl-2'},
  ];

  test('each account is given the balance named for it', () {
    final merged = Repo.withBankBalances(accounts, [
      {'bank_account_id': 'ba-2', 'current_balance': 840.5},
      {'bank_account_id': 'ba-1', 'current_balance': 12500},
    ]);
    expect(merged.map((a) => a['current_balance']), [12500, 840.5]);
    expect(merged.map((a) => a['name']), ['Maybank Current', 'CIMB Savings']);
  });

  test('one the balances do not name is given none, not nought', () {
    final merged = Repo.withBankBalances(accounts, [
      {'bank_account_id': 'ba-1', 'current_balance': 12500},
    ]);
    expect(merged[0]['current_balance'], 12500);
    expect(merged[1].containsKey('current_balance'), isFalse);
  });

  test('and with no balances at all -- a salesman -- none has one', () {
    final merged = Repo.withBankBalances(accounts, const []);
    expect(merged.any((a) => a.containsKey('current_balance')), isFalse);
    expect(merged, hasLength(2));
  });
}
