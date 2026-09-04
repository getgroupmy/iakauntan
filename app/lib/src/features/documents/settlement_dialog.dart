import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../banking/new_bank_account_dialog.dart';
import '../contacts/new_contact_dialog.dart';
import 'fx.dart';
import 'settlement_discount.dart';

/// Records a customer receipt or a supplier payment and allocates it
/// against open documents. Both directions share this dialog because the
/// only differences are wording and which table is written.
Future<void> showSettlementDialog(
  BuildContext context,
  WidgetRef ref, {
  required DocKind kind,
  String? contactId,
  String? documentId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _SettlementDialog(
      kind: kind,
      initialContactId: contactId,
      preselectDocumentId: documentId,
    ),
  );
}

class _SettlementDialog extends ConsumerStatefulWidget {
  const _SettlementDialog({
    required this.kind,
    this.initialContactId,
    this.preselectDocumentId,
  });

  final DocKind kind;
  final String? initialContactId;
  final String? preselectDocumentId;

  @override
  ConsumerState<_SettlementDialog> createState() => _SettlementDialogState();
}

class _SettlementDialogState extends ConsumerState<_SettlementDialog> {
  final _reference = TextEditingController();
  final _charges = TextEditingController();
  final _rate = TextEditingController(text: '1');

  String? _contactId;
  String? _bankAccountId;
  String _paymentMode = '03';
  DateTime _date = DateTime.now();
  bool _saving = false;

  /// Amount being applied to each open document.
  final Map<String, double> _allocations = {};

  /// Settlement discount taken on each, where the terms offer one.
  /// `0385`: this cannot be written without the journal that posts it,
  /// so it goes to the database with the allocation rather than after.
  final Map<String, double> _discounts = {};

  /// What each document's terms offer today, asked of the database
  /// because the terms and the arithmetic are its.
  final Map<String, DiscountOffer> _offers = {};

  /// Rate at which the money actually moved, which is not the rate the
  /// invoice was raised at — the difference between the two is the whole
  /// point of realised FX.
  double? _exchangeRate = 1;
  bool _resolvingRate = false;

  /// currency@date the rate in the field was fetched for, so ticking a
  /// different invoice or moving the date fetches again and nothing else
  /// does.
  String? _rateResolvedFor;

  bool get _isReceipt => widget.kind.isSales;

  String get _base =>
      ref.read(currentOrgProvider).valueOrNull?.baseCurrency ?? 'MYR';

  @override
  void initState() {
    super.initState();
    _contactId = widget.initialContactId;
  }

  @override
  void dispose() {
    _reference.dispose();
    _charges.dispose();
    _rate.dispose();
    super.dispose();
  }

  double get _allocated =>
      _allocations.values.fold(0, (sum, v) => sum + v);

  double get _bankCharges => double.tryParse(_charges.text) ?? 0;

  /// The documents money is actually being applied to.
  List<BusinessDocument> _allocatedDocs(List<BusinessDocument> open) => [
        for (final d in open)
          if ((_allocations[d.id] ?? 0) > 0) d,
      ];

  Future<void> _resolveRate(String currency, String key) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() => _resolvingRate = true);
    try {
      final rate = await repo.exchangeRateFor(currency, _date);
      if (!mounted) return;
      setState(() {
        _rateResolvedFor = key;
        _exchangeRate = rate;
        if (rate != null) _rate.text = Fmt.rate(rate);
      });
    } catch (e) {
      // Marked as resolved so the lookup is not retried on every frame,
      // and cleared so a rate fetched for another currency cannot be
      // recorded as this one's.
      if (mounted) {
        setState(() {
          _rateResolvedFor = key;
          _exchangeRate = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not read the exchange rate: $e')));
      }
    } finally {
      if (mounted) setState(() => _resolvingRate = false);
    }
  }

  Future<void> _save({
    required String currency,
    required double exchangeRate,
  }) async {
    if (_contactId == null) return;
    if (_allocated <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Allocate the payment to at least one document.'),
      ));
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recordSettlement(
            kind: widget.kind,
            contactId: _contactId!,
            amount: _allocated,
            date: _date,
            bankAccountId: _bankAccountId,
            paymentModeCode: _paymentMode,
            reference: _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
            bankCharges: _bankCharges,
            currency: currency,
            exchangeRate: exchangeRate,
            allocations: [
              for (final e in _allocations.entries)
                if (e.value > 0)
                  (
                    documentId: e.key,
                    amount: e.value,
                    discount: _discounts[e.key] ?? 0,
                  ),
            ],
          ),
      successMessage:
          _isReceipt ? 'Receipt recorded and posted' : 'Payment recorded and posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshLedgerData(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contacts = ref
            .watch(contactsProvider(
                (type: widget.kind.contactType, search: '')))
            .value ??
        const <Contact>[];
    final banks = ref.watch(bankAccountsProvider).value ?? const [];
    final modes = ref.watch(paymentModesProvider).value ?? const [];

    // The currency is not the user's to choose: it is whatever the
    // documents being settled were raised in, and the ledger refuses a
    // receipt that disagrees with them.
    final open = _contactId == null
        ? const <BusinessDocument>[]
        : ref
                .watch(outstandingProvider(
                    (kind: widget.kind, contactId: _contactId!)))
                .valueOrNull ??
            const <BusinessDocument>[];
    final allocated = _allocatedDocs(open);
    final currency = settlementCurrency(allocated, _base);
    final isForeign = currency.code != _base;

    final rateKey = '${currency.code}@${Fmt.iso(_date)}';
    if (isForeign && _rateResolvedFor != rateKey && !_resolvingRate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveRate(currency.code, rateKey);
      });
    } else if (!isForeign && _exchangeRate != 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _exchangeRate = 1;
            _rate.text = '1';
            _rateResolvedFor = null;
          });
        }
      });
    }

    final rateUsable = rateIsUsable(
        currency: currency.code, baseCurrency: _base, rate: _exchangeRate);
    final blocked = currency.isConflicting || !rateUsable;

    final fx = !isForeign || !rateUsable
        ? 0.0
        : realisedFx(
            isReceipt: _isReceipt,
            settlementRate: _exchangeRate!,
            allocations: [
              for (final d in allocated)
                (
                  amount: _allocations[d.id] ?? 0,
                  documentRate: d.exchangeRate,
                ),
            ],
          );

    return AlertDialog(
      title: Text(_isReceipt ? 'Receive payment' : 'Pay supplier'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SearchablePicker<String>(
                options: contactPickerOptions(contacts),
                value: _contactId,
                label: '${widget.kind.contactLabel} *',
                hint: 'Type a name or a code',
                // No offer to add one: a receipt settles documents that
                // already exist, and somebody created here would have
                // nothing to settle.
                onChanged: (v) => setState(() {
                  _contactId = v;
                  _allocations.clear();
                  _discounts.clear();
                  _offers.clear();
                }),
              ),
              const SizedBox(height: 14),
              if (_contactId != null) _OpenDocuments(
                kind: widget.kind,
                contactId: _contactId!,
                allocations: _allocations,
                discounts: _discounts,
                offers: _offers,
                preselect: widget.preselectDocumentId,
                onChanged: () => setState(() {}),
              ),
              if (currency.conflict != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: context.colors.danger.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    Icon(Icons.error_outline,
                        size: 18, color: context.colors.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(currency.conflict!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ]),
                ),
              ],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _date,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => _date = picked);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Date',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                      child: Text(Fmt.date(_date)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _paymentMode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Method'),
                    items: [
                      for (final m in modes)
                        DropdownMenuItem(
                          value: m['code'] as String,
                          child: Text(m['description'] as String,
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) =>
                        setState(() => _paymentMode = v ?? '03'),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: SearchablePicker<String>(
                    options: bankPickerOptions(banks),
                    createLabel: 'Add bank account',
                    // 0529 made this list writable for the first
                    // time. Until then a company that opened a
                    // second account had nowhere in the product to
                    // say so.
                    onCreate: (typed) =>
                        createBankAccountFromPicker(context, typed: typed),
                    value: _bankAccountId,
                    label: 'Bank account',
                    onChanged: (v) => setState(() => _bankAccountId = v),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _charges,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Bank charges',
                      // In the currency of the payment, because that is
                      // what post_receipt multiplies by the rate.
                      prefixText: Fmt.prefix(currency.code),
                    ),
                  ),
                ),
              ]),
              if (isForeign) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _rate,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => setState(() {
                    _exchangeRate = parseRate(v);
                    _rateResolvedFor = rateKey;
                  }),
                  decoration: InputDecoration(
                    labelText: 'Exchange rate on the day of payment',
                    helperMaxLines: 2,
                    helperText: _resolvingRate
                        ? 'Looking up the rate…'
                        : _exchangeRate == null
                            ? 'No rate on file for ${Fmt.date(_date)} — enter one'
                            : rateCaption(
                                currency: currency.code,
                                baseCurrency: _base,
                                rate: _exchangeRate!),
                    helperStyle: _exchangeRate == null && !_resolvingRate
                        ? TextStyle(color: context.colors.warning)
                        : null,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _reference,
                decoration: const InputDecoration(
                  labelText: 'Reference',
                  hintText: 'Cheque or transaction number',
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: context.colors.success.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Total being settled',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Money(_allocated, currency: currency.code, bold: true),
                  ],
                ),
              ),
              if (_bankCharges > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _isReceipt
                        ? 'Bank will be debited ${Fmt.money(_allocated - _bankCharges, currency: currency.code)} after charges.'
                        : 'Bank will be credited ${Fmt.money(_allocated + _bankCharges, currency: currency.code)} including charges.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              // What the currency movement between document and payment
              // will cost or earn. Said before the fact, because after
              // posting it is a line in the journal nobody was expecting.
              if (fx.abs() >= 0.005)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    fx > 0
                        ? 'Exchange gain of ${Fmt.money(fx, currency: _base)} will be posted.'
                        : 'Exchange loss of ${Fmt.money(-fx, currency: _base)} will be posted.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: fx > 0
                              ? context.colors.success
                              : context.colors.warning,
                        ),
                  ),
                ),
              if (isForeign && !_resolvingRate && _exchangeRate == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Enter the exchange rate before recording this payment.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.colors.warning),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _allocated <= 0 || blocked
              ? null
              : () => _save(
                    currency: currency.code,
                    exchangeRate: _exchangeRate!,
                  ),
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isReceipt ? 'Record receipt' : 'Record payment'),
        ),
      ],
    );
  }
}

/// Open documents for the chosen contact, each with an editable amount.
class _OpenDocuments extends ConsumerStatefulWidget {
  const _OpenDocuments({
    required this.kind,
    required this.contactId,
    required this.allocations,
    required this.discounts,
    required this.offers,
    required this.onChanged,
    this.preselect,
  });

  final DocKind kind;
  final String contactId;
  final Map<String, double> allocations;
  final Map<String, double> discounts;
  final Map<String, DiscountOffer> offers;
  final VoidCallback onChanged;
  final String? preselect;

  @override
  ConsumerState<_OpenDocuments> createState() => _OpenDocumentsState();
}

class _OpenDocumentsState extends ConsumerState<_OpenDocuments> {
  bool _seeded = false;
  final Set<String> _asked = {};

  /// What each document's terms offer, asked once per document. The
  /// terms and the arithmetic are the database's — a screen that
  /// offered a discount the ledger would refuse is worse than one that
  /// offered none.
  Future<void> _askOffers(List<BusinessDocument> docs) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    for (final d in docs) {
      if (!_asked.add(d.id)) continue;
      final row = await repo.settlementDiscount(d.id);
      if (row == null || !mounted) continue;
      final offer = DiscountOffer.fromJson(row);
      if (offer.isOffered) {
        setState(() => widget.offers[d.id] = offer);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(outstandingProvider(
        (kind: widget.kind, contactId: widget.contactId)));

    return AsyncView(
      value: docs,
      loading: const Padding(
        padding: EdgeInsets.all(Space.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      builder: (list) {
        if (list.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Nothing outstanding for this '
              '${widget.kind.contactLabel.toLowerCase()}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }

        WidgetsBinding.instance
            .addPostFrameCallback((_) => _askOffers(list));

        // Preselect the document the user came from, once.
        if (!_seeded) {
          _seeded = true;
          final target = widget.preselect;
          if (target != null) {
            final match = list.where((d) => d.id == target).firstOrNull;
            if (match != null) {
              widget.allocations[match.id] = match.balanceAmount;
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => widget.onChanged());
            }
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader('Apply to'),
            for (final doc in list)
              _AllocationRow(
                doc: doc,
                amount: widget.allocations[doc.id] ?? 0,
                discount: widget.discounts[doc.id] ?? 0,
                offer: widget.offers[doc.id],
                onChanged: (value) {
                  if (value <= 0) {
                    widget.allocations.remove(doc.id);
                    widget.discounts.remove(doc.id);
                  } else {
                    widget.allocations[doc.id] =
                        value.clamp(0, doc.balanceAmount);
                  }
                  widget.onChanged();
                },
                onDiscount: (value) {
                  if (value <= 0) {
                    widget.discounts.remove(doc.id);
                  } else {
                    widget.discounts[doc.id] = value;
                  }
                  widget.onChanged();
                },
              ),
          ],
        );
      },
    );
  }
}

class _AllocationRow extends StatefulWidget {
  const _AllocationRow({
    required this.doc,
    required this.amount,
    required this.discount,
    required this.offer,
    required this.onChanged,
    required this.onDiscount,
  });

  final BusinessDocument doc;
  final double amount;
  final double discount;

  /// What this document's terms offer today, as the database works it
  /// out. Null where they offer nothing, which is the ordinary case.
  final DiscountOffer? offer;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onDiscount;

  @override
  State<_AllocationRow> createState() => _AllocationRowState();
}

class _AllocationRowState extends State<_AllocationRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
        text: widget.amount == 0 ? '' : widget.amount.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(covariant _AllocationRow old) {
    super.didUpdateWidget(old);
    // Reflect a programmatic change (preselect, or clamping) without
    // fighting the user while they type.
    final shown = double.tryParse(_controller.text) ?? 0;
    if ((shown - widget.amount).abs() > 0.001) {
      _controller.text =
          widget.amount == 0 ? '' : widget.amount.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.doc;
    final selected = widget.amount > 0;
    final offer = widget.offer;
    final said = describeOffer(
        offer, (v) => Fmt.money(v, currency: doc.currency));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [
      Row(
        children: [
          Checkbox(
            value: selected,
            onChanged: (v) =>
                widget.onChanged(v == true ? doc.balanceAmount : 0),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(doc.docNo,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  '${Fmt.money(doc.balanceAmount, currency: doc.currency)} open'
                  '${doc.dueDate != null ? ' · due ${Fmt.date(doc.dueDate)}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: doc.isOverdue ? context.colors.danger : null,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 130,
            child: TextField(
              controller: _controller,
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  isDense: true, prefixText: Fmt.prefix(doc.currency)),
              onChanged: (v) => widget.onChanged(double.tryParse(v) ?? 0),
            ),
          ),
        ],
      ),
      // Only where the terms actually offer one, and only on a document
      // being settled. A line on every row saying no discount is
      // available is noise pretending to be information.
      if (said != null && selected)
        Padding(
          padding: const EdgeInsets.only(left: 48, top: 2, bottom: 4),
          child: Row(children: [
            Expanded(
              child: Text(
                said,
                style: TextStyle(
                  fontSize: 11,
                  color: offer!.stillOpen ? context.colors.success : null,
                ),
              ),
            ),
            if (offer.stillOpen)
              TextButton(
                onPressed: widget.discount > 0
                    ? () => widget.onDiscount(0)
                    : () {
                        // Both figures at once: the cash is what is
                        // left after the discount, and setting one
                        // without the other is how the allocation comes
                        // to more than is owed.
                        widget.onDiscount(offer.discount);
                        widget.onChanged(doc.balanceAmount - offer.discount);
                      },
                child: Text(widget.discount > 0 ? 'Undo' : 'Take it'),
              ),
          ]),
        ),
      ]),
    );
  }
}
