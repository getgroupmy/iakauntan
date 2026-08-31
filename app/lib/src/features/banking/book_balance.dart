/// The number on the bank account, and rebuilding it from the ledger.
///
/// `bank_accounts.current_balance` is a running total. Twenty-three
/// statements across thirteen migrations add to it or take from it — a
/// payment, a receipt, a transfer, a cheque dated next month,
/// withholding tax, a realised FX settlement, client money moving out
/// of the office account — and a running total maintained from
/// twenty-three places is one that drifts. `resync_bank_balance` in `0175` rebuilds it from
/// what the ledger actually holds:
///
///     opening_balance + sum(debit - credit) over posted lines on the
///     bank's own GL account
///
/// It has been asserted since `bank_balance_resync.sql` and called by
/// nothing in the app. `BankAccount.currentBalance` was parsed out of
/// every row and never drawn, so a company looking at a balance that
/// had drifted could neither see the disagreement nor repair it.
///
/// What is deliberate here: the rebuild **says whether the number
/// moved**. A repair that silently corrects a figure teaches nobody
/// that the figure was wrong, and this one is wrong for a reason —
/// something posted against the bank's GL account without going
/// through the path that keeps the total. That is worth noticing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';

/// Two figures are the same money when they round to the same sen.
///
/// `current_balance` is `numeric(18, 2)` and arrives through a JSON
/// double, so comparing with `==` compares a rounding artefact. There
/// is no tolerance beyond the column's own scale on purpose: a sen out
/// is out.
bool balanceMoved(double before, double after) =>
    (before * 100).round() != (after * 100).round();

/// What to say once the rebuild has run.
///
/// Three sentences, because there are three different things to do
/// next: nothing, look at what posted, or look at what posted and
/// wonder where the money went.
String resyncOutcome({required double before, required double after}) {
  if (!balanceMoved(before, after)) {
    return 'The balance already matched the ledger. Nothing moved.';
  }
  final by = after - before;
  final direction = by > 0 ? 'up' : 'down';
  return 'Rebuilt from the ledger: ${Fmt.money(before)} → '
      '${Fmt.money(after)}, $direction by ${Fmt.money(by.abs())}. '
      'Something posted to this account without going through the '
      'running total — worth looking at what.';
}

/// What the button offers before it is pressed.
///
/// Named rather than inlined so the wording is asserted: it has to be
/// clear that this reads the ledger and writes the account, and not the
/// other way round. Somebody who thinks it might rewrite the ledger
/// will not press it.
const String kResyncBlurb =
    'Rebuilds this account’s balance from posted ledger entries. '
    'The ledger is not changed.';

/// What this account says, and an offer to rebuild it.
///
/// Opened from the reconciliation screen, which is where somebody is
/// already comparing a balance against a statement and is therefore the
/// place they notice it is wrong.
Future<bool> showBookBalance(
  BuildContext context, {
  required Map<String, dynamic> account,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _BookBalanceDialog(account: account),
    ) ??
    false;

class _BookBalanceDialog extends ConsumerStatefulWidget {
  const _BookBalanceDialog({required this.account});

  final Map<String, dynamic> account;

  @override
  ConsumerState<_BookBalanceDialog> createState() => _BookBalanceState();
}

class _BookBalanceState extends ConsumerState<_BookBalanceDialog> {
  bool _busy = false;
  String? _said;
  bool _changed = false;

  double get _before => Fmt.toDouble(widget.account['current_balance']);

  Future<void> _rebuild() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    try {
      final after = await repo.resyncBankBalance('${widget.account['id']}');
      if (!mounted) return;
      setState(() {
        _said = resyncOutcome(before: _before, after: after);
        // Whether the *account list* needs reloading, which is a
        // different question from whether the balance was wrong: the row
        // in hand is stale either way once the RPC has written to it.
        _changed = true;
      });
      ref.invalidate(bankAccountsProvider);
    } catch (e) {
      if (!mounted) return;
      setState(() => _said = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPost = ref.watch(canPostProvider);
    return AlertDialog(
      title: Text('${widget.account['name']}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            Fmt.money(_before, currency: '${widget.account['currency'] ?? 'MYR'}'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'What this account says it holds.',
            style: TextStyle(fontSize: 12),
          ),
          if (canPost) ...[
            const SizedBox(height: 12),
            const Text(kResyncBlurb, style: TextStyle(fontSize: 12)),
          ],
          if (_said != null) ...[
            const SizedBox(height: 12),
            Text(_said!, style: const TextStyle(fontSize: 13)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(_changed),
          child: const Text('Close'),
        ),
        if (canPost)
          FilledButton(
            onPressed: _busy ? null : _rebuild,
            child: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Rebuild from the ledger'),
          ),
      ],
    );
  }
}
