m("several suggestions instead of the first",
  "suggest_bank_coding",
  "     order by r.sort_order, r.id\n     limit 1;",
  "     order by r.sort_order, r.id\n     limit 10;",
  "limit 10")

m("direction read off the bank's label, not the sign",
  "bank_rule_matches",
  "          or (p_rule.direction = 'in' and p_txn.amount > 0)\n"
  "          or (p_rule.direction = 'out' and p_txn.amount < 0))",
  "          or (p_rule.direction = 'in'"
  " and p_txn.transaction_type = 'deposit')\n"
  "          or (p_rule.direction = 'out'"
  " and p_txn.transaction_type = 'withdrawal'))",
  "transaction_type = 'deposit'")

m("the amount window compared against the signed amount",
  "bank_rule_matches",
  "abs(p_txn.amount) >= p_rule.amount_min",
  "p_txn.amount >= p_rule.amount_min",
  "p_txn.amount >= p_rule.amount_min")

m("an inactive rule still fires",
  "bank_rule_matches",
  "  select p_rule.is_active\n     and (p_rule.bank_account_id is null",
  "  select true\n     and (p_rule.bank_account_id is null",
  "select true")

m("coverage counts every match, not the first",
  "bank_rule_coverage",
  "             order by r.sort_order, r.id\n             limit 1) as rule_id",
  "             order by r.sort_order desc, r.id desc\n"
  "             limit 1) as rule_id",
  "sort_order desc")

m("CONTROL a comment reworded, which cannot change behaviour",
  "bank_rule_matches",
  "     -- Against the sign, not against `transaction_type`: see the",
  "     -- Against the sign rather than `transaction_type`: see the",
  "Against the sign rather than")
