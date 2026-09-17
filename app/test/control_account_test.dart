import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/contacts/control_account.dart';

/// Which account a customer's balance may be pointed at.
void main() {
  Account acct(
    String code,
    String subtype, {
    bool group = false,
    bool active = true,
  }) => Account(
    id: code,
    code: code,
    name: code,
    accountType: subtype.contains('receivable') ? 'asset' : 'liability',
    accountSubtype: subtype,
    isGroup: group,
    isActive: active,
  );

  final chart = [
    acct('1200', 'accounts_receivable', group: true),
    acct('1210', 'accounts_receivable'),
    acct('1215', 'accounts_receivable'),
    acct('1110', 'bank'),
    acct('1300', 'inventory'),
    acct('2110', 'accounts_payable'),
    acct('2130', 'tax_payable'),
    acct('1219', 'accounts_receivable', active: false),
  ];

  test('a receivable may only be a receivables control account', () {
    // Not "any asset". Pointed at the bank, a customer's balance posts
    // into cash, and the aged listing reconciles against the control
    // account — so the two stop agreeing and neither says why.
    final ids = controlAccountChoices(chart, receivable: true).map((a) => a.code);
    expect(ids, ['1210', '1215']);
  });

  test('and a payable only a payables one', () {
    final ids = controlAccountChoices(chart, receivable: false).map((a) => a.code);
    expect(ids, ['2110']);
    // Tax payable is a liability and is not where a supplier's balance
    // goes; the SST return reads it.
    expect(ids, isNot(contains('2130')));
  });

  test('a group heading is not somewhere a balance can sit', () {
    // Nothing posts to a group: it is a heading with children, and a
    // line against one is a balance that appears in no leaf.
    expect(
      controlAccountChoices(chart, receivable: true).map((a) => a.code),
      isNot(contains('1200')),
    );
  });

  test('nor is an account somebody has retired', () {
    expect(
      controlAccountChoices(chart, receivable: true).map((a) => a.code),
      isNot(contains('1219')),
    );
  });

  test('an empty chart offers nothing rather than throwing', () {
    // The first frame, before the accounts arrive.
    expect(controlAccountChoices(const [], receivable: true), isEmpty);
  });

  test('the empty choice is named, not blank', () {
    // "None" would read as "this customer has no receivable", which is
    // the opposite of what an empty column means.
    expect(kDefaultControlAccount, isNotEmpty);
    expect(kDefaultControlAccount.toLowerCase(), isNot(contains('none')));
  });
}
