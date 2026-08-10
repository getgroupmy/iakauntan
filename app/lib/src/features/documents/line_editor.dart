import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'line_draft.dart';

/// Editable document lines. Wide screens get a spreadsheet-style grid;
/// phones get one card per line so every field stays reachable.
class LineEditorCard extends ConsumerWidget {
  const LineEditorCard({
    super.key,
    required this.lines,
    required this.editable,
    required this.currency,
    required this.onChanged,
    required this.onAdd,
    required this.onRemove,
  });

  final List<LineDraft> lines;
  final bool editable;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final items = ref.watch(itemsProvider('')).value ?? const <Item>[];
    final taxCodes = ref.watch(taxCodesProvider).value ?? const <TaxCode>[];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Lines',
              subtitle: '${lines.length} line${lines.length == 1 ? '' : 's'}',
              action: editable
                  ? TextButton.icon(
                      onPressed: onAdd,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add line'),
                    )
                  : null,
            ),
            if (wide) _wideHeader(context),
            for (var i = 0; i < lines.length; i++)
              wide
                  ? _WideLine(
                      key: ObjectKey(lines[i]),
                      line: lines[i],
                      items: items,
                      taxCodes: taxCodes,
                      editable: editable,
                      currency: currency,
                      onChanged: onChanged,
                      onRemove: () => onRemove(i),
                    )
                  : _NarrowLine(
                      key: ObjectKey(lines[i]),
                      index: i,
                      line: lines[i],
                      items: items,
                      taxCodes: taxCodes,
                      editable: editable,
                      currency: currency,
                      onChanged: onChanged,
                      onRemove: () => onRemove(i),
                    ),
          ],
        ),
      ),
    );
  }

  Widget _wideHeader(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Expanded(flex: 4, child: Text('Item / description', style: style)),
          Expanded(flex: 2, child: Text('Qty', style: style)),
          Expanded(flex: 2, child: Text('Unit price', style: style)),
          Expanded(flex: 2, child: Text('Disc %', style: style)),
          Expanded(flex: 3, child: Text('Tax', style: style)),
          Expanded(
            flex: 3,
            child: Text('Amount', style: style, textAlign: TextAlign.right),
          ),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _WideLine extends StatefulWidget {
  const _WideLine({
    super.key,
    required this.line,
    required this.items,
    required this.taxCodes,
    required this.editable,
    required this.currency,
    required this.onChanged,
    required this.onRemove,
  });

  final LineDraft line;
  final List<Item> items;
  final List<TaxCode> taxCodes;
  final bool editable;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_WideLine> createState() => _WideLineState();
}

class _WideLineState extends State<_WideLine> {
  late final TextEditingController _description;
  late final TextEditingController _quantity;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.line.description);
    _quantity = TextEditingController(text: Fmt.qty(widget.line.quantity));
    _price = TextEditingController(
        text: widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString());
    _discount = TextEditingController(
        text: widget.line.discountPercent == 0
            ? ''
            : Fmt.qty(widget.line.discountPercent));
  }

  @override
  void dispose() {
    _description.dispose();
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// Pulls price, tax and classification from the item master so a line
  /// is correct by default.
  void _applyItem(Item item) {
    setState(() {
      widget.line
        ..itemId = item.id
        ..description = item.name
        ..unitPrice = item.unitPrice
        ..uomCode = item.uomCode
        ..classificationCode = item.classificationCode;
      _description.text = item.name;
      _price.text = item.unitPrice.toString();

      final tax = widget.taxCodes
          .where((t) => t.id == item.salesTaxCodeId)
          .firstOrNull ??
          widget.taxCodes.where((t) => t.isDefault).firstOrNull;
      if (tax != null) {
        widget.line
          ..taxCodeId = tax.id
          ..taxRate = tax.rate;
      }
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final totals = widget.line.totals;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: _ItemField(
              controller: _description,
              items: widget.items,
              editable: widget.editable,
              onItemSelected: _applyItem,
              onTextChanged: (v) {
                widget.line.description = v;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _NumField(
              controller: _quantity,
              editable: widget.editable,
              onChanged: (v) {
                setState(() => widget.line.quantity = v);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _NumField(
              controller: _price,
              editable: widget.editable,
              onChanged: (v) {
                setState(() => widget.line.unitPrice = v);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _NumField(
              controller: _discount,
              editable: widget.editable,
              onChanged: (v) {
                setState(() => widget.line.discountPercent = v);
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: _TaxField(
              line: widget.line,
              taxCodes: widget.taxCodes,
              editable: widget.editable,
              onChanged: () {
                setState(() {});
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Money(totals.total, currency: widget.currency, bold: true),
                if (totals.tax > 0)
                  Text(
                    'incl. ${Fmt.money(totals.tax, currency: widget.currency)} tax',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 40,
            child: widget.editable
                ? IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: widget.onRemove,
                    tooltip: 'Remove line',
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

class _NarrowLine extends StatefulWidget {
  const _NarrowLine({
    super.key,
    required this.index,
    required this.line,
    required this.items,
    required this.taxCodes,
    required this.editable,
    required this.currency,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final LineDraft line;
  final List<Item> items;
  final List<TaxCode> taxCodes;
  final bool editable;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_NarrowLine> createState() => _NarrowLineState();
}

class _NarrowLineState extends State<_NarrowLine> {
  late final TextEditingController _description;
  late final TextEditingController _quantity;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  @override
  void initState() {
    super.initState();
    _description = TextEditingController(text: widget.line.description);
    _quantity = TextEditingController(text: Fmt.qty(widget.line.quantity));
    _price = TextEditingController(
        text: widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString());
    _discount = TextEditingController(
        text: widget.line.discountPercent == 0
            ? ''
            : Fmt.qty(widget.line.discountPercent));
  }

  @override
  void dispose() {
    _description.dispose();
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totals = widget.line.totals;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text('Line ${widget.index + 1}',
                  style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              Money(totals.total, currency: widget.currency, bold: true),
              if (widget.editable)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onRemove,
                ),
            ],
          ),
          const SizedBox(height: 8),
          _ItemField(
            controller: _description,
            items: widget.items,
            editable: widget.editable,
            onItemSelected: (item) {
              setState(() {
                widget.line
                  ..itemId = item.id
                  ..description = item.name
                  ..unitPrice = item.unitPrice
                  ..uomCode = item.uomCode
                  ..classificationCode = item.classificationCode;
                _description.text = item.name;
                _price.text = item.unitPrice.toString();
              });
              widget.onChanged();
            },
            onTextChanged: (v) {
              widget.line.description = v;
              widget.onChanged();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _NumField(
                  controller: _quantity,
                  label: 'Qty',
                  editable: widget.editable,
                  onChanged: (v) {
                    setState(() => widget.line.quantity = v);
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _NumField(
                  controller: _price,
                  label: 'Price',
                  editable: widget.editable,
                  onChanged: (v) {
                    setState(() => widget.line.unitPrice = v);
                    widget.onChanged();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _NumField(
                  controller: _discount,
                  label: 'Disc %',
                  editable: widget.editable,
                  onChanged: (v) {
                    setState(() => widget.line.discountPercent = v);
                    widget.onChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TaxField(
            line: widget.line,
            taxCodes: widget.taxCodes,
            editable: widget.editable,
            onChanged: () {
              setState(() {});
              widget.onChanged();
            },
          ),
        ],
      ),
    );
  }
}

/// Free-text description that also offers the item master as suggestions.
class _ItemField extends StatelessWidget {
  const _ItemField({
    required this.controller,
    required this.items,
    required this.editable,
    required this.onItemSelected,
    required this.onTextChanged,
  });

  final TextEditingController controller;
  final List<Item> items;
  final bool editable;
  final ValueChanged<Item> onItemSelected;
  final ValueChanged<String> onTextChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextFormField(
            controller: controller,
            enabled: editable,
            onChanged: onTextChanged,
            decoration: const InputDecoration(
              hintText: 'Description',
              isDense: true,
            ),
          ),
        ),
        if (editable && items.isNotEmpty)
          PopupMenuButton<Item>(
            tooltip: 'Pick from items',
            icon: const Icon(Icons.inventory_2_outlined, size: 18),
            onSelected: onItemSelected,
            itemBuilder: (_) => [
              for (final item in items.take(50))
                PopupMenuItem(
                  value: item,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(item.name,
                          style: const TextStyle(fontWeight: FontWeight.w500)),
                      Text(
                        '${item.code} · ${Fmt.money(item.unitPrice)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _NumField extends StatelessWidget {
  const _NumField({
    required this.controller,
    required this.editable,
    required this.onChanged,
    this.label,
  });

  final TextEditingController controller;
  final bool editable;
  final ValueChanged<double> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: editable,
      textAlign: TextAlign.right,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (v) => onChanged(double.tryParse(v) ?? 0),
    );
  }
}

class _TaxField extends StatelessWidget {
  const _TaxField({
    required this.line,
    required this.taxCodes,
    required this.editable,
    required this.onChanged,
  });

  final LineDraft line;
  final List<TaxCode> taxCodes;
  final bool editable;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      value:
          taxCodes.any((t) => t.id == line.taxCodeId) ? line.taxCodeId : null,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true, hintText: 'Tax'),
      items: [
        for (final t in taxCodes)
          DropdownMenuItem(
            value: t.id,
            child: Text(
              t.rate == 0 ? t.code : '${t.code} (${Fmt.percent(t.rate)})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: editable
          ? (v) {
              final tax = taxCodes.where((t) => t.id == v).firstOrNull;
              line
                ..taxCodeId = v
                ..taxRate = tax?.rate ?? 0;
              onChanged();
            }
          : null,
    );
  }
}
