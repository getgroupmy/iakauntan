import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../custom_fields/custom_fields_section.dart';
import '../items/new_item_dialog.dart';
import 'description_override_dialog.dart';
import 'line_draft.dart';
import '../stock/lot_dialog.dart';

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
    required this.sales,
    this.receiving = false,
    this.defers = false,
    this.priceFor,
  });

  final List<LineDraft> lines;
  final bool editable;
  final String currency;

  /// Which side of the trade this document is on. Only used to pick
  /// which set of a company's own line fields to draw: a field defined
  /// on a sales line is not a field on a bill.
  final bool sales;

  /// The price this customer pays for this item at this quantity, or
  /// null to keep the item's list price. Null on purchase documents,
  /// where a price level is a sales idea.
  final Future<double?> Function(String itemId, double quantity)? priceFor;
  final VoidCallback onChanged;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  /// Stock coming in rather than going out. Changes what the lot dialog
  /// is for: typing numbers off the boxes, or choosing from what is on
  /// hand.
  final bool receiving;

  /// Whether a line on this document can be earned over a period rather
  /// than on the day. True for sales documents, false for purchases:
  /// 0309 defers revenue, and a bill is not revenue.
  final bool defers;

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
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                      priceFor: priceFor,
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
                      priceFor: priceFor,
                    ),
              // Only for an item somebody has chosen to track. Everybody
              // else never sees it, which is what keeps the feature from
              // being a tax on the businesses that will never use it.
              if (_trackingOf(items, lines[i]) != 'none')
                _LotStrip(
                  line: lines[i],
                  tracking: _trackingOf(items, lines[i]),
                  itemCode: _codeOf(items, lines[i]),
                  editable: editable,
                  receiving: receiving,
                  onChanged: onChanged,
                ),
              // A field this company added to a LINE rather than to the
              // document. It draws nothing where none are defined, and
              // most companies will define none — a line-level field is
              // filled in once per line, which is a real thing to ask
              // of somebody and is why the setup screen says so.
              CustomFieldsSection(
                entity: sales ? 'sales_document_line' : 'purchase_document_line',
                heading: 'Your own fields on this line',
                values: lines[i].customFields,
                enabled: editable,
                onChanged: (v) {
                  lines[i].customFields = v;
                  onChanged();
                },
              ),
              // Offered where it could plausibly be wanted — a line
              // whose item is not stock, which is what a service is —
              // and always where one is already set, so a period stays
              // visible if the item is later changed. On every line of
              // every invoice it would be a tax on the shops that sell
              // things off a shelf and will never defer anything.
              if (defers &&
                  (lines[i].serviceStart != null ||
                      _isService(items, lines[i])))
                _ServicePeriodStrip(
                  line: lines[i],
                  editable: editable,
                  onChanged: onChanged,
                ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// A line worth offering a service period on: one that is not stock.
  /// A line with no item at all counts — a typed-in "Annual support"
  /// with no item behind it is the commonest deferred line there is.
  static bool _isService(List<Item> items, LineDraft line) {
    if (line.itemId == null) return true;
    for (final i in items) {
      if (i.id == line.itemId) return !i.trackInventory;
    }
    return false;
  }

  static String _trackingOf(List<Item> items, LineDraft line) {
    if (line.itemId == null) return 'none';
    for (final i in items) {
      if (i.id == line.itemId) return i.tracking;
    }
    return 'none';
  }

  static String _codeOf(List<Item> items, LineDraft line) {
    for (final i in items) {
      if (i.id == line.itemId) return i.code;
    }
    return '';
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
          Expanded(flex: 2, child: Text('Item no.', style: style)),
          const SizedBox(width: 8),
          Expanded(flex: 4, child: Text('Description', style: style)),
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
    this.priceFor,
  });

  final LineDraft line;
  final List<Item> items;
  final List<TaxCode> taxCodes;
  final bool editable;
  final String currency;
  final Future<double?> Function(String itemId, double quantity)? priceFor;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_WideLine> createState() => _WideLineState();
}

class _WideLineState extends State<_WideLine> {
  late final TextEditingController _code;
  late final FocusNode _codeFocus;
  late final TextEditingController _description;
  late final FocusNode _descriptionFocus;
  late final TextEditingController _quantity;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: _codeOf(widget.line.itemId));
    _codeFocus = FocusNode();
    _description = TextEditingController(text: widget.line.description);
    _descriptionFocus = FocusNode();
    _quantity = TextEditingController(text: Fmt.qty(widget.line.quantity));
    _price = TextEditingController(
        text: widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString());
    _discount = TextEditingController(
        text: widget.line.discountPercent == 0
            ? ''
            : Fmt.qty(widget.line.discountPercent));
  }

  /// The item list is fetched, so it is empty on the first frame and
  /// arrives on a later one. A line reopened on an item therefore has no
  /// code to show when this state is created, and would sit blank until
  /// somebody typed over it. Filled in as soon as the list can answer,
  /// and never over the top of anything already in the box.
  @override
  void didUpdateWidget(covariant _WideLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_code.text.isEmpty) {
      final code = _codeOf(widget.line.itemId);
      if (code.isNotEmpty) _code.text = code;
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _codeFocus.dispose();
    _description.dispose();
    _descriptionFocus.dispose();
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// Pulls price, tax and classification from the item master so a line
  /// is correct by default, then asks what this customer actually pays.
  ///
  /// The list price is applied first and corrected after, rather than
  /// waiting: the round trip is short but not instant, and a line that
  /// sits blank while it resolves reads as broken.
  Future<void> _applyItem(Item item) async {
    // The offer rather than an item: ask for the details, and bind the
    // line to what comes back. Declining leaves the line exactly as it
    // was, which for the description box means the free text somebody
    // typed is still there.
    if (item.id == kCreateItemId) {
      final created = await showDialog<Item>(
        context: context,
        builder: (_) => NewItemDialog(
          seedCode: item.code.isEmpty ? null : item.code,
          seedName: item.name.isEmpty ? null : item.name,
        ),
      );
      if (created == null || !mounted) return;
      return _applyItem(created);
    }
    // Ask before throwing away a description somebody wrote. Reported
    // from a bill scanned off a supplier's PDF: the reading had filled
    // four lines, an item was assigned afterwards, and every one of
    // them was replaced by the item master's name without a word.
    //
    // Only the DESCRIPTION is in question. The price, the unit, the tax
    // code and the classification come from the item whichever way it
    // is answered, because those are what binding a line to an item is
    // for.
    final description = await descriptionAfterApplying(
      context,
      current: _description.text,
      item: item,
      boundItemName: _nameOf(widget.line.itemId),
    );
    if (!mounted || description == null) return;

    setState(() {
      applyItemToLine(widget.line, item, widget.taxCodes);
      _code.text = item.code;
      // After `applyItemToLine`, which sets the description itself:
      // keeping the old one means putting it back in BOTH places, on
      // the draft that gets saved as well as in the box on screen.
      widget.line.description = description;
      _description.text = description;
      _price.text = item.unitPrice.toString();
    });
    widget.onChanged();

    final resolved =
        await widget.priceFor?.call(item.id, widget.line.quantity);
    if (!mounted || resolved == null || resolved == widget.line.unitPrice) {
      return;
    }
    setState(() {
      widget.line.unitPrice = resolved;
      _price.text = resolved.toString();
    });
    widget.onChanged();
  }


  /// The number of the item this line is already bound to, for a
  /// document being reopened rather than typed. Lines carry `item_id`,
  /// not the code, so the code is looked up in the list the editor was
  /// given; a line with no item, or one whose item has since been
  /// deleted, simply shows nothing.
  String _codeOf(String? itemId) {
    if (itemId == null) return '';
    for (final item in widget.items) {
      if (item.id == itemId) return item.code;
    }
    return '';
  }

  /// The NAME of the item this line is already bound to, or null where
  /// there is none.
  ///
  /// Not cosmetic: it is how the prompt tells text this editor put
  /// there from text a person typed. Changing item A for item B leaves
  /// A's name in the box, and asking whether to keep it would ask twice
  /// for one correction.
  String? _nameOf(String? itemId) {
    if (itemId == null) return null;
    for (final item in widget.items) {
      if (item.id == itemId) return item.name;
    }
    return null;
  }

  /// The item's own unit — what the shelf is counted in, and what the
  /// picker converts to.
  String get _baseUom {
    for (final i in widget.items) {
      if (i.id == widget.line.itemId) return i.uomCode;
    }
    return widget.line.uomCode ?? '';
  }

  /// A different unit on the same line. The quantity stays as typed —
  /// two cartons is still two — and the price follows it, because the
  /// price is per the line's own unit and a carton is not priced like a
  /// tin.
  void _unitChanged(double from, double to) {
    setState(() {
      widget.line.unitPrice = rescaleForUom(widget.line.unitPrice, from, to);
      _price.text =
          widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString();
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
            flex: 2,
            child: _ItemCodeField(
              controller: _code,
              focusNode: _codeFocus,
              items: widget.items,
              editable: widget.editable,
              onItemSelected: _applyItem,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 4,
            child: _ItemField(
              controller: _description,
              focusNode: _descriptionFocus,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _NumField(
                  controller: _quantity,
                  editable: widget.editable,
                  onChanged: (v) {
                    setState(() => widget.line.quantity = v);
                    widget.onChanged();
                  },
                ),
                _UomField(
                  line: widget.line,
                  baseUom: _baseUom,
                  editable: widget.editable,
                  onUnitChanged: _unitChanged,
                ),
              ],
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
    this.priceFor,
  });

  final int index;
  final LineDraft line;
  final List<Item> items;
  final List<TaxCode> taxCodes;
  final Future<double?> Function(String itemId, double quantity)? priceFor;
  final bool editable;
  final String currency;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  State<_NarrowLine> createState() => _NarrowLineState();
}

class _NarrowLineState extends State<_NarrowLine> {
  late final TextEditingController _code;
  late final FocusNode _codeFocus;
  late final TextEditingController _description;
  late final FocusNode _descriptionFocus;
  late final TextEditingController _quantity;
  late final TextEditingController _price;
  late final TextEditingController _discount;

  @override
  void initState() {
    super.initState();
    _code = TextEditingController(text: _codeOf(widget.line.itemId));
    _codeFocus = FocusNode();
    _description = TextEditingController(text: widget.line.description);
    _descriptionFocus = FocusNode();
    _quantity = TextEditingController(text: Fmt.qty(widget.line.quantity));
    _price = TextEditingController(
        text: widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString());
    _discount = TextEditingController(
        text: widget.line.discountPercent == 0
            ? ''
            : Fmt.qty(widget.line.discountPercent));
  }

  /// The item list is fetched, so it is empty on the first frame and
  /// arrives on a later one. A line reopened on an item therefore has no
  /// code to show when this state is created, and would sit blank until
  /// somebody typed over it. Filled in as soon as the list can answer,
  /// and never over the top of anything already in the box.
  @override
  void didUpdateWidget(covariant _NarrowLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_code.text.isEmpty) {
      final code = _codeOf(widget.line.itemId);
      if (code.isNotEmpty) _code.text = code;
    }
  }

  @override
  void dispose() {
    _code.dispose();
    _codeFocus.dispose();
    _description.dispose();
    _descriptionFocus.dispose();
    _quantity.dispose();
    _price.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// The same as the wide row: item defaults first, then what this
  /// customer actually pays.
  Future<void> _applyItem(Item item) async {
    // The offer rather than an item: ask for the details, and bind the
    // line to what comes back. Declining leaves the line exactly as it
    // was, which for the description box means the free text somebody
    // typed is still there.
    if (item.id == kCreateItemId) {
      final created = await showDialog<Item>(
        context: context,
        builder: (_) => NewItemDialog(
          seedCode: item.code.isEmpty ? null : item.code,
          seedName: item.name.isEmpty ? null : item.name,
        ),
      );
      if (created == null || !mounted) return;
      return _applyItem(created);
    }
    // Ask before throwing away a description somebody wrote. Reported
    // from a bill scanned off a supplier's PDF: the reading had filled
    // four lines, an item was assigned afterwards, and every one of
    // them was replaced by the item master's name without a word.
    //
    // Only the DESCRIPTION is in question. The price, the unit, the tax
    // code and the classification come from the item whichever way it
    // is answered, because those are what binding a line to an item is
    // for.
    final description = await descriptionAfterApplying(
      context,
      current: _description.text,
      item: item,
      boundItemName: _nameOf(widget.line.itemId),
    );
    if (!mounted || description == null) return;

    setState(() {
      applyItemToLine(widget.line, item, widget.taxCodes);
      _code.text = item.code;
      // After `applyItemToLine`, which sets the description itself:
      // keeping the old one means putting it back in BOTH places, on
      // the draft that gets saved as well as in the box on screen.
      widget.line.description = description;
      _description.text = description;
      _price.text = item.unitPrice.toString();
    });
    widget.onChanged();

    final resolved =
        await widget.priceFor?.call(item.id, widget.line.quantity);
    if (!mounted || resolved == null || resolved == widget.line.unitPrice) {
      return;
    }
    setState(() {
      widget.line.unitPrice = resolved;
      _price.text = resolved.toString();
    });
    widget.onChanged();
  }


  /// The number of the item this line is already bound to, for a
  /// document being reopened rather than typed. Lines carry `item_id`,
  /// not the code, so the code is looked up in the list the editor was
  /// given; a line with no item, or one whose item has since been
  /// deleted, simply shows nothing.
  String _codeOf(String? itemId) {
    if (itemId == null) return '';
    for (final item in widget.items) {
      if (item.id == itemId) return item.code;
    }
    return '';
  }

  /// The NAME of the item this line is already bound to, or null where
  /// there is none.
  ///
  /// Not cosmetic: it is how the prompt tells text this editor put
  /// there from text a person typed. Changing item A for item B leaves
  /// A's name in the box, and asking whether to keep it would ask twice
  /// for one correction.
  String? _nameOf(String? itemId) {
    if (itemId == null) return null;
    for (final item in widget.items) {
      if (item.id == itemId) return item.name;
    }
    return null;
  }

  /// The item's own unit — what the shelf is counted in, and what the
  /// picker converts to.
  String get _baseUom {
    for (final i in widget.items) {
      if (i.id == widget.line.itemId) return i.uomCode;
    }
    return widget.line.uomCode ?? '';
  }

  /// A different unit on the same line. The quantity stays as typed —
  /// two cartons is still two — and the price follows it, because the
  /// price is per the line's own unit and a carton is not priced like a
  /// tin.
  void _unitChanged(double from, double to) {
    setState(() {
      widget.line.unitPrice = rescaleForUom(widget.line.unitPrice, from, to);
      _price.text =
          widget.line.unitPrice == 0 ? '' : widget.line.unitPrice.toString();
    });
    widget.onChanged();
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
          _ItemCodeField(
            controller: _code,
            focusNode: _codeFocus,
            items: widget.items,
            editable: widget.editable,
            onItemSelected: _applyItem,
          ),
          const SizedBox(height: 8),
          _ItemField(
            controller: _description,
            focusNode: _descriptionFocus,
            items: widget.items,
            editable: widget.editable,
            onItemSelected: _applyItem,
            onTextChanged: (v) {
              widget.line.description = v;
              widget.onChanged();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _NumField(
                      controller: _quantity,
                      label: 'Qty',
                      editable: widget.editable,
                      onChanged: (v) {
                        setState(() => widget.line.quantity = v);
                        widget.onChanged();
                      },
                    ),
                    _UomField(
                      line: widget.line,
                      baseUom: _baseUom,
                      editable: widget.editable,
                      onUnitChanged: _unitChanged,
                    ),
                  ],
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

/// The list an item box drops down.
///
/// It is the width of the FIELD, and that is a constraint rather than a
/// choice: `RawAutocomplete` puts its options in an overlay whose
/// constraints come from the box they hang under. Widening it with an
/// `OverflowBox` does work visually — and makes the rows UNTAPPABLE,
/// because the part that hangs outside the parent's bounds is never hit
/// tested. A list you can read and cannot click is worse than a narrow
/// one, so the name wraps to two lines instead of being cut off, which
/// is what "Structured Ca…" needed.
///
/// The wide search is the DESCRIPTION box, which is twice the width and
/// runs the same query. Somebody hunting by name has a box the size of
/// the question.
Widget itemOptionsView(
  BuildContext context,
  AutocompleteOnSelected<Item> onSelected,
  Iterable<Item> options,
) {
  return Align(
    alignment: Alignment.topLeft,
    child: Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          itemCount: options.length,
          itemBuilder: (context, index) {
            final item = options.elementAt(index);
            if (item.id == kCreateItemId) {
              final typed = item.code.isNotEmpty ? item.code : item.name;
              return InkWell(
                onTap: () => onSelected(item),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.add, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Create "$typed"',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }
            return InkWell(
              onTap: () => onSelected(item),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.code,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      Fmt.money(item.unitPrice),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// The id of the row that means "this is not on the list — make it".
///
/// A sentinel rather than a separate widget because `RawAutocomplete`
/// HIDES its overlay entirely when `optionsBuilder` returns nothing.
/// The one moment somebody needs the offer is the moment nothing
/// matches, so an offer that can only be drawn alongside matches is an
/// offer that never appears. It rides in as an option instead, and the
/// row builder and `onSelected` both check for it.
const kCreateItemId = '__create__';

/// The offer, carrying what was typed and which box it was typed in.
Item createItemOption(String typed, {required bool asCode}) => Item(
  id: kCreateItemId,
  code: asCode ? typed.trim() : '',
  name: asCode ? '' : typed.trim(),
  itemType: 'stock',
);

/// What the boxes offer for what has been typed: the matches, and then
/// the offer to create one.
///
/// The offer is LAST when there are matches and alone when there are
/// none — it is a way out, not a suggestion, and putting it first would
/// have somebody creating a second ITM-100 by pressing enter too
/// quickly.
Iterable<Item> itemOptionsFor(
  List<Item> items,
  String typed, {
  required bool asCode,
}) {
  final query = typed.trim();
  if (query.isEmpty) return const Iterable<Item>.empty();
  final matches = itemsMatching(items, query).toList();
  // An EXACT hit needs no offer: somebody who typed a whole part number
  // that exists is not about to create it again.
  final exact = matches.any(
    (i) => asCode
        ? i.code.toLowerCase() == query.toLowerCase()
        : i.name.toLowerCase() == query.toLowerCase(),
  );
  return [
    ...matches,
    if (!exact) createItemOption(query, asCode: asCode),
  ];
}

/// Which items match what has been typed, code first.
///
/// Shared by both boxes on the line, because somebody typing in either
/// one is doing the same thing: looking for an item. Code matches come
/// before name matches so an exact part number is not buried under
/// everything whose name happens to contain it.
Iterable<Item> itemsMatching(List<Item> items, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const Iterable<Item>.empty();
  final byCode = <Item>[];
  final byName = <Item>[];
  for (final item in items) {
    if (item.code.toLowerCase().contains(q)) {
      byCode.add(item);
    } else if (item.name.toLowerCase().contains(q)) {
      byName.add(item);
    }
  }
  return [...byCode, ...byName].take(30);
}

/// The item's own number, with the item list behind it.
///
/// Typing here searches the item master on BOTH the code and the
/// description, because the two are how people actually look an item up:
/// a storeman knows the number and whoever wrote the order knows what
/// the thing is called. Matching only the code would make the box
/// useless to half the people who reach for it.
///
/// Selecting fills the line the same way the picker beside the
/// description does. Typing alone changes nothing but the text: a code
/// half-entered is not a choice, and a line is only bound to an item
/// when somebody picks one.
class _ItemCodeField extends StatelessWidget {
  const _ItemCodeField({
    required this.controller,
    required this.focusNode,
    required this.items,
    required this.editable,
    required this.onItemSelected,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Item> items;
  final bool editable;
  final ValueChanged<Item> onItemSelected;

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Item>(
      textEditingController: controller,
      focusNode: focusNode,
      displayStringForOption: (item) => item.code,
      optionsBuilder: (value) => editable
          ? itemOptionsFor(items, value.text, asCode: true)
          : const Iterable<Item>.empty(),
      onSelected: onItemSelected,
      fieldViewBuilder: (context, textController, node, onFieldSubmitted) {
        return TextFormField(
          controller: textController,
          focusNode: node,
          enabled: editable,
          onFieldSubmitted: (_) => onFieldSubmitted(),
          decoration: const InputDecoration(
            hintText: 'Item no.',
            isDense: true,
          ),
        );
      },
      optionsViewBuilder: itemOptionsView,
    );
  }
}

/// The description, which is also a way to find an item.
///
/// It stays FREE TEXT: a charge is often something that is not on the
/// item list at all, and a box that refused what was typed unless it
/// matched a row would make half the invoices in this system
/// un-typeable. What it adds is a search — the same one the item-number
/// box runs, on the code and the name together — so somebody who starts
/// typing "cabling" is offered the item rather than having to know it
/// exists and open the picker.
///
/// The picker beside it stays too. It answers a different question:
/// "what is on the list" rather than "is this thing on the list", and
/// somebody who does not know what to type has nothing to type.
class _ItemField extends StatelessWidget {
  const _ItemField({
    required this.controller,
    required this.focusNode,
    required this.items,
    required this.editable,
    required this.onItemSelected,
    required this.onTextChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final List<Item> items;
  final bool editable;
  final ValueChanged<Item> onItemSelected;
  final ValueChanged<String> onTextChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: RawAutocomplete<Item>(
            textEditingController: controller,
            focusNode: focusNode,
            // The description, not the code: picking an item here fills
            // the box with what the thing is called, which is what this
            // box is for and what will print on the invoice.
            displayStringForOption: (item) => item.name,
            optionsBuilder: (value) => editable
                ? itemOptionsFor(items, value.text, asCode: false)
                : const Iterable<Item>.empty(),
            onSelected: onItemSelected,
            optionsViewBuilder: itemOptionsView,
            fieldViewBuilder:
                (context, textController, node, onFieldSubmitted) =>
                    TextFormField(
            controller: textController,
            focusNode: node,
            enabled: editable,
            onChanged: onTextChanged,
            // A charge often needs more than one line to describe: a
            // part number, a period covered, a site address. The field
            // was single-line, which meant a description carrying a
            // newline could be neither read nor typed — a scanned bill
            // whose item ran to two printed lines showed one run-on
            // line and there was no way to put the break back.
            //
            // Grows to three and then scrolls, so an ordinary one-line
            // description costs the same height it always did.
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(
              hintText: 'Description',
              isDense: true,
            ),
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

/// The unit this line is written in, and what it comes to on the shelf.
///
/// `uom_code` has been a column on both line tables since 0005 and was
/// only ever copied off the item, so a shop that buys by the carton and
/// stocks by the tin had no way to say so. 0270 made the database
/// convert; this is the half that lets somebody choose.
///
/// It renders nothing at all when there is nothing to choose between —
/// no item on the line, one unit only, or an organization without the
/// inventory module, whose read of `item_uom_options` is refused. That
/// is the common case, and it should cost those businesses no pixels.
class _UomField extends ConsumerWidget {
  const _UomField({
    required this.line,
    required this.baseUom,
    required this.editable,
    required this.onUnitChanged,
  });

  final LineDraft line;
  final String baseUom;
  final bool editable;

  /// Called with the factor the line was written in and the one it is
  /// now written in, so the row can rescale the price it is showing.
  final void Function(double from, double to) onUnitChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (line.itemId == null) return const SizedBox.shrink();
    final options =
        ref.watch(itemUomOptionsProvider(line.itemId!)).valueOrNull ??
        const <Map<String, dynamic>>[];
    if (options.length < 2) return const SizedBox.shrink();

    final current = line.uomCode ?? baseUom;
    final factor = uomFactor(options, current);
    final hint = baseQuantityHint(
      quantity: line.quantity,
      uom: current,
      baseUom: baseUom,
      factor: factor,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SearchablePicker<String>(
          options: [
            for (final o in options)
              PickerOption<String>(
                value: '${o['uom_code']}',
                label: '${o['uom_name']}',
                keywords: ['${o['uom_code']}'],
              ),
          ],
          value: options.any((o) => '${o['uom_code']}' == current)
              ? current
              : null,
          label: 'Unit',
          dense: true,
          enabled: editable,
          onChanged: (v) {
            if (v == null || v == current) return;
            final to = uomFactor(options, v);
            line.uomCode = v;
            onUnitChanged(factor, to);
          },
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hint,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
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
    // The busiest tax code box in the product, and the narrowest. A
    // company that has added a rate for every service line it bills
    // has more codes than the cell is tall, so it is typed into like
    // every other one — dense, so the row keeps its height.
    return SearchablePicker<String>(
      options: [
        for (final t in taxCodes)
          PickerOption<String>(
            value: t.id,
            label: t.pickerLabel,
            sublabel: t.name,
            keywords: [t.name],
          ),
      ],
      value:
          taxCodes.any((t) => t.id == line.taxCodeId) ? line.taxCodeId : null,
      label: 'Tax',
      dense: true,
      enabled: editable,
      allowEmpty: true,
      emptyLabel: 'No tax',
      onChanged: (v) {
        // The other moment `app.calc_document_line` resolves a code:
        // changing it on a line is a new choice. Through the shared
        // function so that this and `applyItemToLine` cannot answer it
        // differently — which is exactly how the tax code went missing
        // from the narrow card once already.
        applyTaxCodeToLine(
          line,
          taxCodes.where((t) => t.id == v).firstOrNull,
        );
        onChanged();
      },
    );
  }
}


/// What this line is made of, under the line itself.
///
/// Deliberately loud when it is short. A tracked line that nobody has
/// broken down will not post, and finding that out at the posting button
/// is finding out too late — whoever presses it is rarely the person who
/// knows which boxes were picked.
class _LotStrip extends StatelessWidget {
  const _LotStrip({
    required this.line,
    required this.tracking,
    required this.itemCode,
    required this.editable,
    required this.receiving,
    required this.onChanged,
  });

  final LineDraft line;
  final String tracking;
  final String itemCode;
  final bool editable;
  final bool receiving;
  final VoidCallback onChanged;

  double get _named => line.lots.fold(
      0, (a, l) => a + (Fmt.toDouble(l['quantity']) == 0 ? 1 : Fmt.toDouble(l['quantity'])));

  @override
  Widget build(BuildContext context) {
    final short = line.quantity - _named;
    final ok = short == 0 && line.lots.isNotEmpty;
    final noun = tracking == 'serial' ? 'serial numbers' : 'batches';

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(children: [
        Icon(
          ok ? Icons.check_circle_outline : Icons.error_outline,
          size: 16,
          color: ok ? context.colors.success : context.colors.danger,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ok
                ? '${line.lots.length} $noun named'
                : line.lots.isEmpty
                    ? 'No $noun named — this line will not post'
                    : '${Fmt.qty(short)} of ${Fmt.qty(line.quantity)} still to name',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ok ? null : context.colors.danger,
                  fontWeight: ok ? null : FontWeight.w600,
                ),
          ),
        ),
        if (editable)
          TextButton(
            onPressed: () async {
              final result = await showDialog<List<Map<String, dynamic>>>(
                context: context,
                builder: (_) => LotDialog(
                  existing: line.lots,
                  itemId: line.itemId!,
                  itemCode: itemCode,
                  tracking: tracking,
                  quantity: line.quantity,
                  receiving: receiving,
                  warehouseId: line.warehouseId,
                ),
              );
              if (result != null) {
                line.lots = result;
                onChanged();
              }
            },
            child: Text(line.lots.isEmpty ? 'Name them' : 'Change'),
          ),
      ]),
    );
  }
}


/// The period this line is earned over, under the line itself.
///
/// Quiet by design, unlike `_LotStrip` above it. A missing lot stops a
/// document posting; a missing service period only means the line is
/// earned on the invoice date, which is the right answer for almost
/// every line ever typed. So this states what will happen rather than
/// warning that something is wrong.
class _ServicePeriodStrip extends StatelessWidget {
  const _ServicePeriodStrip({
    required this.line,
    required this.editable,
    required this.onChanged,
  });

  final LineDraft line;
  final bool editable;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final deferred = line.serviceStart != null;

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(children: [
        Icon(
          deferred ? Icons.event_repeat : Icons.today_outlined,
          size: 16,
          color: deferred
              ? context.colors.info
              : Theme.of(context).hintColor,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            servicePeriodLabel(line.serviceStart, line.serviceEnd),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: deferred ? null : Theme.of(context).hintColor,
                  fontWeight: deferred ? FontWeight.w600 : null,
                ),
          ),
        ),
        if (editable)
          TextButton(
            onPressed: () async {
              final picked = await showDialog<({DateTime? from, DateTime? to})>(
                context: context,
                builder: (_) => _ServicePeriodDialog(
                  from: line.serviceStart,
                  to: line.serviceEnd,
                ),
              );
              if (picked == null) return;
              line
                ..serviceStart = picked.from
                ..serviceEnd = picked.to;
              onChanged();
            },
            child: Text(deferred ? 'Change' : 'Spread it'),
          ),
      ]),
    );
  }
}

/// Two dates, or neither.
///
/// The pair is the unit: `sales_document_lines` has a check constraint
/// refusing one without the other, so Save stays disabled until both
/// are set and Clear returns both together. Whoever half-fills this
/// finds out here rather than at the posting button.
class _ServicePeriodDialog extends StatefulWidget {
  const _ServicePeriodDialog({required this.from, required this.to});

  final DateTime? from;
  final DateTime? to;

  @override
  State<_ServicePeriodDialog> createState() => _ServicePeriodDialogState();
}

class _ServicePeriodDialogState extends State<_ServicePeriodDialog> {
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _from = widget.from;
    _to = widget.to;
  }

  Future<void> _pick(bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isFrom ? _from : (_to ?? _from)) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        // A start after the end is somebody moving the period, not
        // asking for a negative one. Carry the end along rather than
        // making them fix a complaint we could have avoided.
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final complete = _from != null && _to != null;
    final backwards = complete && _to!.isBefore(_from!);

    return AlertDialog(
      title: const Text('Earned over'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A line with a period is not income on the day you invoice '
            'it. It is held as deferred revenue and released month by '
            'month across the period, in proportion to the days in each.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.md),
          _DateField(
            label: 'From',
            value: _from,
            onTap: () => _pick(true),
          ),
          const SizedBox(height: Space.sm),
          _DateField(
            label: 'To',
            value: _to,
            onTap: () => _pick(false),
          ),
          const SizedBox(height: Space.md),
          Text(
            backwards
                ? 'The period ends before it starts.'
                : complete
                    ? servicePeriodLabel(_from, _to)
                    : 'Pick both dates, or clear the period.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: backwards ? context.colors.danger : null,
                ),
          ),
        ],
      ),
      actions: [
        if (widget.from != null || _from != null || _to != null)
          TextButton(
            onPressed: () => Navigator.pop<({DateTime? from, DateTime? to})>(
              context,
              (from: null, to: null),
            ),
            child: const Text('Earn it on the invoice date'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: complete && !backwards
              ? () => Navigator.pop<({DateTime? from, DateTime? to})>(
                    context,
                    (from: _from, to: _to),
                  )
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          suffixIcon: const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(value == null ? 'Not set' : Fmt.date(value)),
      ),
    );
  }
}
