import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'member_panel.dart';
import 'till_screen.dart' show posNum;

/// Taking the money.
///
/// The sheet does no arithmetic that matters. It collects what was
/// handed over and asks the server what that comes to; the total, the
/// coins due, the change and the rounding all come back from
/// `complete_pos_sale`. That is deliberate — five sen rounding belongs
/// to the cash and not to the document, and a screen that worked out
/// the change itself would be a second implementation of a rule that
/// already exists, disagreeing with the receipt on the sales that round.
Future<bool?> showTenderSheet(
  BuildContext context, {
  required String saleId,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _TenderSheet(saleId: saleId),
);

class _TenderSheet extends ConsumerStatefulWidget {
  const _TenderSheet({required this.saleId});

  final String saleId;

  @override
  ConsumerState<_TenderSheet> createState() => _TenderSheetState();
}

class _TenderSheetState extends ConsumerState<_TenderSheet> {
  final _amount = TextEditingController();
  String? _tenderTypeId;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _take(double total) async {
    final type = _tenderTypeId;
    if (type == null) return;
    final given = double.tryParse(_amount.text) ?? total;
    setState(() => _busy = true);
    Map<String, dynamic>? result;
    final ok = await runWithFeedback(
      context,
      pendingMessage: 'Taking payment…',
      successMessage: null,
      action: () async {
        result = await ref.read(repoProvider)!.completePosSale(widget.saleId, [
          {'type': type, 'amount': given},
        ]);
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok || result == null) return;
    await _showReceipt(result!);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _showReceipt(Map<String, dynamic> r) => showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('${r['invoice_no']}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Row('Total', posNum(r['total'])),
          // Shown only when it is not nothing. A card sale rounds by
          // zero and a line saying so is noise on the one screen that
          // must stay readable at arm's length.
          if (posNum(r['rounding']) != 0)
            _Row('Rounding', posNum(r['rounding'])),
          if (posNum(r['cash_due']) != 0)
            _Row('Cash due', posNum(r['cash_due'])),
          const Divider(),
          _Row('Change', posNum(r['change_due']), big: true),
        ],
      ),
      actions: [
        // Offered after the money, never before. `start_membership`
        // refuses a sale that has not completed, for the reason it
        // gives: a membership that starts first is an entitlement
        // nobody paid for.
        if (moduleEnabledNow(ref, 'memberships'))
          TextButton(
            onPressed: () => _startMembership(ctx),
            child: const Text('Start membership'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Next customer'),
        ),
      ],
    ),
  );

  /// Puts the customer on the membership they just bought.
  ///
  /// Every condition is the server's: that the sale completed, that
  /// somebody is named on it, that the membership is on offer, and —
  /// the one that matters — that this sale actually contains the
  /// membership item, because otherwise "start a membership" is a
  /// button that gives one away. Those refusals arrive already written
  /// for a person, so they are shown rather than second-guessed.
  Future<void> _startMembership(BuildContext receiptCtx) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final offers = await ref.read(posMembershipsProvider.future);
    if (!mounted) return;

    final live = offers.where((o) => o['is_active'] == true).toList();
    if (live.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No memberships are on offer.')),
      );
      return;
    }

    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in live)
              ListTile(
                title: Text((o['name'] ?? '—') as String),
                subtitle: Text(
                  o['sessions_included'] == null
                      ? '${o['period']} · unlimited'
                      : '${o['period']} · ${o['sessions_included']} '
                            'per period',
                ),
                onTap: () => Navigator.of(ctx).pop(o['id'] as String),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;

    await runWithFeedback(
      context,
      successMessage: 'Membership started',
      action: () => repo.startMembership(widget.saleId, chosen),
    );
    if (mounted && receiptCtx.mounted) Navigator.of(receiptCtx).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sale = ref.watch(posSaleProvider(widget.saleId));
    final types = ref.watch(posTenderTypesProvider);
    final total = sale.maybeWhen(
      data: (row) => posNum(row?['total_amount']),
      orElse: () => 0.0,
    );

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: AsyncView<List<Map<String, dynamic>>>(
        value: types,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.payments_outlined,
              title: 'No ways to pay',
              message:
                  'Add at least one tender type — cash, card — before '
                  'taking money.',
            );
          }
          _tenderTypeId ??= rows.first['id'] as String?;
          final selected = rows.firstWhere(
            (r) => r['id'] == _tenderTypeId,
            orElse: () => rows.first,
          );
          final isCash = selected['kind'] == 'cash';

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Above the total, because a redemption changes it. Asked
              // here rather than at the basket because "do you have a
              // card?" is a question about paying, and asking it while
              // the shopping is being rung up asks it of the four
              // hundred people a day who are buying a drink.
              MemberPanel(saleId: widget.saleId),
              _Row('To pay', total, big: true),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in rows)
                    ChoiceChip(
                      label: Text('${t['name']}'),
                      selected: t['id'] == _tenderTypeId,
                      onSelected: (_) =>
                          setState(() => _tenderTypeId = t['id'] as String?),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  prefixText: Fmt.prefix('MYR'),
                  labelText: isCash ? 'Handed over' : 'Charged',
                  // What went in the drawer, not what was owed. Recording
                  // the amount due instead loses the fifty that came in,
                  // which is the only thing the cash-up is about.
                  helperText: isCash
                      ? 'Leave blank to take the exact amount'
                      : null,
                ),
              ),
              if (isCash) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final note in const [5, 10, 20, 50, 100])
                      ActionChip(
                        label: Text('RM $note'),
                        onPressed: () =>
                            setState(() => _amount.text = '$note'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy || total <= 0 ? null : () => _take(total),
                icon: const Icon(Icons.check),
                label: const Text('Take it'),
              ),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.amount, {this.big = false});

  final String label;
  final double amount;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final style = big
        ? Theme.of(context).textTheme.headlineSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(Fmt.money(amount), style: style),
        ],
      ),
    );
  }
}
