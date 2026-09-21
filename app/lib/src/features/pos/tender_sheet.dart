import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/skeletons.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'member_panel.dart';
import 'offline_store.dart' show tenderTyped;
import 'on_account.dart';
import 'receipt_view.dart';
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

  /// Whose account this goes on, when the cashier picked one here.
  /// Null means the sale's own contact stands, which is what the
  /// database falls back to.
  String? _accountContact;
  String? _accountContactName;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _take(double total, {required bool onAccount}) async {
    final type = _tenderTypeId;
    if (type == null) return;
    // An empty box is exact money, which is the right default at a
    // counter. A box that cannot be READ is not, and this used to treat
    // the two the same: `?? total` meant a mistyped amount completed
    // the sale as though the customer had handed over the exact basket,
    // so `0209` worked the change out as nought and somebody walked
    // away short. See `tenderTyped`.
    final given = tenderTyped(_amount.text, exact: total);
    if (given == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('That is not an amount. Leave it empty for exact '
              'money.'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    Map<String, dynamic>? result;
    final ok = await runWithFeedback(
      context,
      // Not "Taking payment" when nothing is being taken. The line is
      // read by whoever is standing on the other side of the counter.
      pendingMessage: onAccount ? 'Putting it on the account…' : 'Taking payment…',
      successMessage: null,
      action: () async {
        result = await ref
            .read(repoProvider)!
            .completePosSale(
              widget.saleId,
              [
                {'type': type, 'amount': given},
              ],
              contactId: _accountContact,
            );
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok || result == null) return;
    await _showReceipt(result!, onAccount: onAccount ? given : 0);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Asks who, for a sale going on an account.
  ///
  /// The same picker the e-Invoice question uses, because it is the
  /// same question — which customer is this — and a second list of
  /// customers to keep in step would be a second list to get wrong.
  Future<void> _pickAccount() async {
    final chosen = await showModalBottomSheet<Contact>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _EinvoiceCustomerSheet(),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _accountContact = chosen.id;
      _accountContactName = chosen.name;
    });
  }

  Future<void> _showReceipt(
    Map<String, dynamic> r, {
    double onAccount = 0,
  }) => showDialog<void>(
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
          // Not "Change RM0.00". Nothing was handed over, and that
          // line reads as a completed cash sale on the one screen a
          // cashier checks before handing the bag over.
          if (onAccountNote(onAccount: onAccount) case final note?)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                note,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            )
          else
            _Row('Change', posNum(r['change_due']), big: true),
        ],
      ),
      actions: [
        // The paper, for the person on the other side of the counter.
        // The numbers above are what the cashier needs; this is what
        // the customer takes away, rendered by the same server function
        // the printer will use.
        TextButton(
          onPressed: () async {
            final text = await ref
                .read(repoProvider)!
                .posReceiptText(widget.saleId);
            if (ctx.mounted) {
              await showReceiptSheet(ctx, text: text, title: '${r['invoice_no']}');
            }
          },
          child: const Text('Receipt'),
        ),
        // Offered after the money, never before. `start_membership`
        // refuses a sale that has not completed, for the reason it
        // gives: a membership that starts first is an entitlement
        // nobody paid for.
        if (moduleEnabledNow(ref, 'memberships'))
          TextButton(
            onPressed: () => _startMembership(ctx),
            child: const Text('Start membership'),
          ),
        // "Boss, I need it under the company name." Said after the
        // money, with a card produced, which is why 0210 made this its
        // own function rather than an argument to `complete_pos_sale`:
        // a till that could only be told before tendering is a till
        // that makes people queue twice.
        if (moduleEnabledNow(ref, 'einvoice'))
          TextButton(
            onPressed: () => _requestEinvoice(ctx),
            child: const Text('Needs e-Invoice'),
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

  /// Bills this sale to somebody identifiable, so it gets its own
  /// e-Invoice instead of disappearing into the month's consolidation.
  ///
  /// The test for "asked for one" is not a checkbox — 0210 derives it
  /// from whether the sale is billed to a contact with a TIN, so that
  /// the split cannot drift from what was actually invoiced. Which
  /// means the useful thing this sheet can do is say which customers
  /// have one, rather than let a cashier pick a name and find out from
  /// a refusal.
  ///
  /// Re-billing is refused once the sale has been rolled into a
  /// consolidation, because that submission has already told LHDN this
  /// sale had no identified buyer. That refusal is the server's and is
  /// shown as it arrives.
  Future<void> _requestEinvoice(BuildContext receiptCtx) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    final chosen = await showModalBottomSheet<Contact>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _EinvoiceCustomerSheet(),
    );
    if (chosen == null || !mounted) return;

    await runWithFeedback(
      context,
      successMessage: 'Billed to them — this sale gets its own e-Invoice',
      action: () => repo.requestEinvoiceForSale(widget.saleId, chosen.id),
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
        skeleton: const FormSkeleton(fields: 3),
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
          final onAccount = isOnAccount(selected);
          final saleContact = sale.maybeWhen(
            data: (row) => row?['contact_id'] as String?,
            orElse: () => null,
          );
          final blocked = onAccountBlockedBecause(
            tenderType: selected,
            saleContact: saleContact,
            chosenContact: _accountContact,
          );

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
                  labelText: isCash
                      ? 'Handed over'
                      : onAccount
                      ? 'On the account'
                      : 'Charged',
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
              if (onAccount) ...[
                const SizedBox(height: 8),
                // Asked here rather than refused after the fact. The
                // database's refusal is correct and arrives as a red
                // banner over a queue; this is the same rule one step
                // earlier, where the answer is a button.
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickAccount,
                  icon: const Icon(Icons.person_outline),
                  label: Text(
                    _accountContactName ??
                        (saleContact == null
                            ? 'Whose account?'
                            : 'Somebody else\'s account'),
                  ),
                ),
                if (blocked != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      blocked,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _busy || total <= 0 || blocked != null
                    ? null
                    : () => _take(total, onAccount: onAccount),
                icon: Icon(onAccount ? Icons.receipt_long_outlined : Icons.check),
                label: Text(onAccount ? 'Put it on the account' : 'Take it'),
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


/// Who to bill it to.
///
/// Searches by name and says plainly which contacts carry a TIN,
/// because a contact without one does not change anything: the sale
/// would still be anonymous to LHDN and would still roll into the
/// consolidation. Showing that up front is kinder than a refusal after
/// the customer has spelled out their company name.
class _EinvoiceCustomerSheet extends ConsumerStatefulWidget {
  const _EinvoiceCustomerSheet();

  @override
  ConsumerState<_EinvoiceCustomerSheet> createState() =>
      _EinvoiceCustomerSheetState();
}

class _EinvoiceCustomerSheetState
    extends ConsumerState<_EinvoiceCustomerSheet> {
  final _search = TextEditingController();
  List<Contact> _results = const [];
  bool _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _busy = true);
    final rows = await repo.contacts(search: _search.text, type: 'customer');
    if (!mounted) return;
    setState(() {
      _results = rows;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _search,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Company or name',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: _busy ? null : _find,
              ),
            ),
            onSubmitted: (_) => _find(),
          ),
          const SizedBox(height: 8),
          if (_busy) const LinearProgressIndicator(),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in _results)
                  ListTile(
                    title: Text(c.name),
                    subtitle: Text(
                      (c.tin ?? '').trim().isEmpty
                          ? 'No TIN — this sale would still be consolidated'
                          : 'TIN ${c.tin}',
                    ),
                    // Not disabled. The server decides, and a row that
                    // cannot be tapped teaches nothing about why.
                    onTap: () => Navigator.of(context).pop(c),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
