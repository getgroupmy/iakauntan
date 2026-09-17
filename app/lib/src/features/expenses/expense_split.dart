/// A charge divided across several accounts, decided apart from the
/// form that collects it.
///
/// The database treats the split as the expense: `set_expense_split`
/// writes the header's amount, tax and account from the lines rather
/// than checking one against the other, so there is no state in which
/// the parts and the total disagree. That makes the total a derived
/// figure here too — the form shows it, it is never typed — and leaves
/// this class with one real job: saying whether a split is ready to be
/// sent, and why not when it is not.
library;

import 'package:flutter/foundation.dart';

@immutable
class SplitLine {
  const SplitLine({this.accountId, this.amount = 0, this.description});

  final String? accountId;
  final double amount;
  final String? description;

  SplitLine copyWith({
    Object? accountId = _keep,
    double? amount,
    Object? description = _keep,
  }) =>
      SplitLine(
        accountId:
            accountId == _keep ? this.accountId : accountId as String?,
        amount: amount ?? this.amount,
        description:
            description == _keep ? this.description : description as String?,
      );

  static const Object _keep = Object();
}

@immutable
class ExpenseSplit {
  const ExpenseSplit(this.lines);

  const ExpenseSplit.none() : lines = const [];

  final List<SplitLine> lines;

  bool get isOn => lines.isNotEmpty;

  /// What the expense comes to. Added up, not typed.
  double get total =>
      lines.fold<double>(0, (sum, line) => sum + line.amount);

  /// Why this cannot be sent yet, in the words the person needs, or
  /// null when it can.
  String? get problem {
    if (lines.isEmpty) return null;
    // One line is not a split; it is the expense as it always was, and
    // sending it as a split would only bury the account one level down.
    if (lines.length < 2) {
      return 'A split needs at least two accounts';
    }
    if (lines.any((l) => l.accountId == null)) {
      return 'Every line needs an account';
    }
    if (lines.any((l) => l.amount <= 0)) {
      return 'Every line needs an amount';
    }
    return null;
  }

  bool get isReady => problem == null;

  /// What `set_expense_split` is given. Empty when there is no split,
  /// which is what takes one off again.
  List<Map<String, dynamic>> toJson() => [
        for (final line in lines)
          {
            'account_id': line.accountId,
            'amount': line.amount,
            if (line.description != null && line.description!.trim().isNotEmpty)
              'description': line.description!.trim(),
          }
      ];

  ExpenseSplit withLine(SplitLine line) =>
      ExpenseSplit([...lines, line]);

  ExpenseSplit replace(int index, SplitLine line) =>
      ExpenseSplit([
        for (var i = 0; i < lines.length; i++)
          if (i == index) line else lines[i]
      ]);

  ExpenseSplit without(int index) =>
      ExpenseSplit([
        for (var i = 0; i < lines.length; i++)
          if (i != index) lines[i]
      ]);
}
