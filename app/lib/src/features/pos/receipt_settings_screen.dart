import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';
import 'receipt_view.dart';
import '../settings/tax_code_dialog.dart';

/// What goes on the paper, chosen by the shop.
///
/// The preview is the point of the screen. It renders through the same
/// server function the printer uses, against the last bill this outlet
/// actually settled — so what is on screen is the paper, not a mock-up
/// of it. A shop that has sold nothing yet is told to ring one up
/// rather than shown an invented basket that will not match.
class ReceiptSettingsScreen extends ConsumerStatefulWidget {
  const ReceiptSettingsScreen({super.key});

  @override
  ConsumerState<ReceiptSettingsScreen> createState() =>
      _ReceiptSettingsScreenState();
}

class _ReceiptSettingsScreenState
    extends ConsumerState<ReceiptSettingsScreen> {
  String? _outletId;
  final _header = TextEditingController();
  final _footer = TextEditingController();

  // Loaded once per outlet, then owned by the form. Re-reading the
  // provider into the controllers on every rebuild would fight the
  // person typing.
  String? _loadedFor;
  int _paperMm = 80;
  int _copies = 1;
  String _language = 'en';
  bool _itemCodes = false;
  bool _cashier = true;
  bool _table = true;
  bool _channel = false;
  bool _tax = true;
  bool _customer = true;
  bool _points = true;
  bool _qr = true;

  // The service charge is not a printing choice — it changes what the
  // customer pays — but it lands on the same paper and is set per
  // outlet, so it is set here rather than on a screen of its own that
  // would hold one field.
  final _serviceCharge = TextEditingController();
  String? _serviceTaxCode;
  bool _savingCharge = false;

  @override
  void dispose() {
    _header.dispose();
    _footer.dispose();
    _serviceCharge.dispose();
    super.dispose();
  }

  void _load(Map<String, dynamic> row) {
    _header.text = '${row['header'] ?? ''}';
    _footer.text = '${row['footer'] ?? ''}';
    _paperMm = (row['paper_mm'] as num?)?.toInt() ?? 80;
    _copies = (row['copies'] as num?)?.toInt() ?? 1;
    _language = '${row['language'] ?? 'en'}';
    _itemCodes = row['show_item_codes'] == true;
    _cashier = row['show_cashier'] != false;
    _table = row['show_table'] != false;
    _channel = row['show_channel'] == true;
    _tax = row['show_tax_summary'] != false;
    _customer = row['show_customer'] != false;
    _points = row['show_points'] != false;
    _qr = row['show_einvoice_qr'] != false;
  }

  Future<void> _saveCharge(String outletId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final typed = double.tryParse(_serviceCharge.text.trim());
    if (_serviceCharge.text.trim().isNotEmpty && typed == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That is not a percentage')),
        );
      }
      return;
    }
    setState(() => _savingCharge = true);
    await runWithFeedback(
      context,
      action: () => repo.savePosServiceCharge(
        outletId: outletId,
        percent: typed ?? 0,
        // A charge with no tax on it is what an outlet that is not
        // registered for service tax has, so an empty choice is a real
        // answer rather than a missing one.
        taxCodeId: (typed ?? 0) == 0 ? null : _serviceTaxCode,
      ),
      successMessage: 'Service charge saved',
    );
    if (mounted) setState(() => _savingCharge = false);
    ref.invalidate(posOutletsProvider);
    ref.invalidate(posRecentSaleProvider(outletId));
  }

  Future<void> _save(String outletId) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosReceiptSettings(
        outletId: outletId,
        header: _header.text.trim().isEmpty ? null : _header.text.trim(),
        footer: _footer.text.trim().isEmpty ? null : _footer.text.trim(),
        paperMm: _paperMm,
        copies: _copies,
        language: _language,
        itemCodes: _itemCodes,
        cashier: _cashier,
        table: _table,
        channel: _channel,
        tax: _tax,
        customer: _customer,
        points: _points,
        qr: _qr,
      ),
    );
    if (!ok || !mounted) return;
    ref.invalidate(posReceiptSettingsProvider(outletId));
    // The preview is the whole point, so it is re-rendered rather than
    // left showing the paper from before the change.
    final sale = await ref.read(posRecentSaleProvider(outletId).future);
    if (sale != null && mounted) ref.invalidate(posReceiptTextProvider(sale));
  }

  @override
  Widget build(BuildContext context) {
    final outlets = ref.watch(posOutletsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: outlets,
        onRetry: () => ref.invalidate(posOutletsProvider),
        skeleton: const ListSkeleton(rows: 3, subtitle: false),
        builder: (shops) {
          if (shops.isEmpty) {
            return const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No outlets',
              message: 'Set a shop up before deciding what its paper says.',
            );
          }
          if (_outletId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() => _outletId = shops.first['id'] as String?);
              }
            });
            return const Center(child: CircularProgressIndicator());
          }
          final outlet = _outletId!;
          final settings = ref.watch(posReceiptSettingsProvider(outlet));

          return AsyncView<Map<String, dynamic>>(
            value: settings,
            onRetry: () => ref.invalidate(posReceiptSettingsProvider(outlet)),
            skeleton: const FormSkeleton(fields: 6),
            builder: (row) {
              if (_loadedFor != outlet) {
                _loadedFor = outlet;
                _load(row);
                final shop = shops.firstWhere(
                  (s) => s['id'] == outlet,
                  orElse: () => const <String, dynamic>{},
                );
                final pct = (shop['service_charge_percent'] as num?) ?? 0;
                _serviceCharge.text = pct == 0 ? '' : '$pct';
                _serviceTaxCode = shop['service_charge_tax_code_id'] as String?;
              }
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (shops.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        spacing: 4,
                        children: [
                          for (final s in shops)
                            ChoiceChip(
                              label: Text('${s['name']}'),
                              selected: s['id'] == outlet,
                              onSelected: (_) => setState(() {
                                _outletId = s['id'] as String?;
                                _loadedFor = null;
                              }),
                            ),
                        ],
                      ),
                    ),
                  TextField(
                    controller: _header,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Top of the receipt',
                      helperText: 'One line each. Centred on the paper.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _footer,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Bottom of the receipt',
                      hintText: 'Terima kasih',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      // Millimetres, because that is what a shop buys.
                      // The columns are the server's arithmetic.
                      Expanded(
                        child: SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(value: 58, label: Text('58mm')),
                            ButtonSegment(value: 80, label: Text('80mm')),
                          ],
                          selected: {_paperMm},
                          onSelectionChanged: (v) =>
                              setState(() => _paperMm = v.first),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'en', label: Text('English')),
                            ButtonSegment(value: 'ms', label: Text('Melayu')),
                          ],
                          selected: {_language},
                          onSelectionChanged: (v) =>
                              setState(() => _language = v.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Copies'),
                      const SizedBox(width: 12),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('1')),
                          ButtonSegment(value: 2, label: Text('2')),
                          ButtonSegment(value: 3, label: Text('3')),
                        ],
                        selected: {_copies},
                        onSelectionChanged: (v) =>
                            setState(() => _copies = v.first),
                      ),
                    ],
                  ),
                  const Divider(height: 32),
                  // Only the things a shop may leave off. There is no
                  // switch here for a discount, a promotion, a delivery
                  // fee or a tender: a receipt that can be configured
                  // not to mention money that changed hands is a
                  // receipt that can be used to hide it.
                  const SectionHeader('What to put on it'),
                  SwitchListTile(
                    dense: true,
                    value: _cashier,
                    onChanged: (v) => setState(() => _cashier = v),
                    title: const Text("Who served them"),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _table,
                    onChanged: (v) => setState(() => _table = v),
                    title: const Text('The table and how many were on it'),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _customer,
                    onChanged: (v) => setState(() => _customer = v),
                    title: const Text("The customer's name"),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _channel,
                    onChanged: (v) => setState(() => _channel = v),
                    title: const Text('How the order arrived'),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _itemCodes,
                    onChanged: (v) => setState(() => _itemCodes = v),
                    title: const Text('Item codes'),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _tax,
                    onChanged: (v) => setState(() => _tax = v),
                    title: const Text('The tax line'),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _points,
                    onChanged: (v) => setState(() => _points = v),
                    title: const Text('Points earned and the balance'),
                  ),
                  SwitchListTile(
                    dense: true,
                    value: _qr,
                    onChanged: (v) => setState(() => _qr = v),
                    title: const Text('The e-Invoice square'),
                    subtitle: const Text(
                      'Only printed when the company has e-Invoice on',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => _save(outlet),
                    child: const Text('Save'),
                  ),
                  const Divider(height: 32),
                  const SectionHeader(
                    'Service charge',
                    subtitle:
                        'Ten per cent is the Malaysian norm. Service tax is '
                        'charged on the bill after the charge, so this '
                        'changes what the customer pays and not only what '
                        'the paper says.',
                  ),
                  _ServiceCharge(
                    outletId: outlet,
                    controller: _serviceCharge,
                    taxCodeId: _serviceTaxCode,
                    saving: _savingCharge,
                    onTaxCode: (v) => setState(() => _serviceTaxCode = v),
                    onSave: () => _saveCharge(outlet),
                  ),
                  const Divider(height: 32),
                  const SectionHeader('The paper'),
                  _Preview(outletId: outlet),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.outletId});

  final String outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sale = ref.watch(posRecentSaleProvider(outletId));
    return AsyncView<String?>(
      value: sale,
      onRetry: () => ref.invalidate(posRecentSaleProvider(outletId)),
      builder: (saleId) {
        if (saleId == null) {
          return const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'Nothing to show yet',
            message: 'Ring a sale up and its receipt appears here, rendered '
                'exactly as the printer will produce it.',
          );
        }
        final text = ref.watch(posReceiptTextProvider(saleId));
        return AsyncView<String>(
          value: text,
          onRetry: () => ref.invalidate(posReceiptTextProvider(saleId)),
          skeleton: const CardRowsSkeleton(
              rows: 8, leading: false, lines: 1),
          builder: (paper) => Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ReceiptPaper(paper),
            ),
          ),
        );
      },
    );
  }
}

/// The percentage and the tax that rides it.
///
/// Split out so the form above stays readable, and stateless because
/// the two values live on the screen's state where the outlet picker
/// can reset them.
class _ServiceCharge extends ConsumerWidget {
  const _ServiceCharge({
    required this.outletId,
    required this.controller,
    required this.taxCodeId,
    required this.saving,
    required this.onTaxCode,
    required this.onSave,
  });

  final String outletId;
  final TextEditingController controller;
  final String? taxCodeId;
  final bool saving;
  final ValueChanged<String?> onTaxCode;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 140,
              child: TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Charge',
                  suffixText: '%',
                  hintText: '0',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TaxCodePicker(
                value: taxCodeId,
                label: 'Tax on the charge',
                allowEmpty: true,
                onChanged: onTaxCode,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonal(
            onPressed: saving ? null : onSave,
            child: const Text('Save the charge'),
          ),
        ),
      ],
    );
  }
}
