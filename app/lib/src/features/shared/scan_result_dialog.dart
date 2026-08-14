import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/ocr_repository.dart';
import 'scan_all_data.dart';

/// What was read off a document, before anybody acts on it.
///
/// Shown rather than applied silently, because a machine reading a faded
/// thermal receipt is a good first draft and not a source document. And
/// editable, because a first draft that cannot be corrected is worse
/// than useless — it makes somebody discard the whole reading over one
/// figure picked off the wrong line.
///
/// Returns the reading, with any corrections, when [canApply] and it was
/// accepted. Null when it was discarded, or whenever it is only being
/// shown.
Future<OcrExtraction?> showScanResult(
  BuildContext context,
  OcrExtraction read, {
  bool canApply = false,
}) =>
    showDialog<OcrExtraction>(
      context: context,
      builder: (_) => _ScanResultDialog(read: read, canApply: canApply),
    );

class _ScanResultDialog extends StatefulWidget {
  const _ScanResultDialog({required this.read, required this.canApply});

  final OcrExtraction read;
  final bool canApply;

  @override
  State<_ScanResultDialog> createState() => _ScanResultDialogState();
}

class _ScanResultDialogState extends State<_ScanResultDialog> {
  late final TextEditingController _supplier;
  late final TextEditingController _taxId;
  late final TextEditingController _registrationNo;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _documentNo;
  late final TextEditingController _currency;
  late final TextEditingController _subtotal;
  late final TextEditingController _tax;
  late final TextEditingController _total;
  late DateTime? _date;
  late final List<_EditableLine> _lines;

  OcrExtraction get read => widget.read;

  @override
  void initState() {
    super.initState();
    _supplier = TextEditingController(text: read.supplierName ?? '');
    _taxId = TextEditingController(text: read.supplierTaxId ?? '');
    _registrationNo =
        TextEditingController(text: read.supplierRegistrationNo ?? '');
    _email = TextEditingController(text: read.supplierEmail ?? '');
    _phone = TextEditingController(text: read.supplierPhone ?? '');
    _address = TextEditingController(text: read.supplierAddress ?? '');
    _documentNo = TextEditingController(text: read.documentNo ?? '');
    _currency = TextEditingController(text: read.currency ?? '');
    _subtotal = TextEditingController(text: _money(read.subtotal));
    _tax = TextEditingController(text: _money(read.taxAmount));
    _total = TextEditingController(text: _money(read.totalAmount));
    _date = read.documentDate;
    _lines = [for (final line in read.lines) _EditableLine.from(line)];
  }

  @override
  void dispose() {
    _supplier.dispose();
    _taxId.dispose();
    _registrationNo.dispose();
    _email.dispose();
    _phone.dispose();
    _address.dispose();
    _documentNo.dispose();
    _currency.dispose();
    _subtotal.dispose();
    _tax.dispose();
    _total.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  /// Blank rather than zero for a figure the document does not carry.
  /// The distinction is the whole point of the reading — a receipt with
  /// no tax line and a receipt with RM 0.00 of tax are different
  /// documents, and typing the second when you meant the first is how a
  /// wrong return gets filed.
  static String _money(double? value) =>
      value == null ? '' : value.toStringAsFixed(2);

  /// What somebody typed, as a figure. Thousands separators and a stray
  /// `RM` are what a person copying off a bill actually types.
  static double? _parse(String raw) {
    final cleaned =
        raw.replaceAll(RegExp(r'[^0-9.\-]'), '').replaceAll(RegExp(r'(?!^)-'), '');
    if (cleaned.isEmpty || cleaned == '-' || cleaned == '.') return null;
    return double.tryParse(cleaned);
  }

  double? get _subtotalValue => _parse(_subtotal.text);
  double? get _taxValue => _parse(_tax.text);
  double? get _totalValue => _parse(_total.text);

  /// The one figure the form can check for itself.
  ///
  /// Recomputed as it is typed rather than carried over from the
  /// reading, so correcting the total clears the warning instead of
  /// leaving a complaint about figures that are no longer on screen.
  String? get _doesNotFoot {
    final net = _subtotalValue;
    final tax = _taxValue;
    final total = _totalValue;
    if (net == null || tax == null || total == null) return null;
    if ((net + tax - total).abs() < 0.005) return null;
    return 'The figures do not add up: ${Fmt.money(net)} + ${Fmt.money(tax)} '
        'is ${Fmt.money(net + tax)}, not ${Fmt.money(total)}.';
  }

  /// Whether the form can check the arithmetic itself.
  ///
  /// When it can, its answer replaces the reader's — otherwise correcting
  /// a total clears the live warning only for the reader's original
  /// complaint about that same total to appear underneath it, which is
  /// both stale and infuriating.
  bool get _allThreeFigures =>
      _subtotalValue != null && _taxValue != null && _totalValue != null;

  bool get _nothing =>
      read.supplierName == null &&
      read.totalAmount == null &&
      read.documentNo == null;

  OcrExtraction get _edited => OcrExtraction(
        supplierName: _trimmed(_supplier),
        supplierTaxId: _trimmed(_taxId),
        supplierRegistrationNo: _trimmed(_registrationNo),
        supplierEmail: _trimmed(_email),
        supplierPhone: _trimmed(_phone),
        supplierAddress: _trimmed(_address),
        documentNo: _trimmed(_documentNo),
        documentDate: _date,
        currency: _trimmed(_currency)?.toUpperCase(),
        subtotal: _subtotalValue,
        taxAmount: _taxValue,
        totalAmount: _totalValue,
        lines: [
          for (final line in _lines)
            if (!line.isEmpty) line.toLine(),
        ],
        // The reader's own note is dropped once a person has been
        // through the figures: it described what the reader saw, and
        // what is on screen now is what somebody decided.
        note: _doesNotFoot,
        // Carried through untouched. It is the document, not a reading
        // of it, so nothing on this form can change what it says — and
        // dropping it would empty the All data screen on the second
        // visit.
        rawText: read.rawText,
      );

  static String? _trimmed(TextEditingController c) {
    final text = c.text.trim();
    return text.isEmpty ? null : text;
  }

  /// Opens the whole document, and takes back whatever was assigned.
  ///
  /// The form is rebuilt from what comes back rather than merged field
  /// by field: the other screen was handed this form's state, so what it
  /// returns already contains every correction made here.
  Future<void> _openAllData() async {
    final assigned = await showAllData(context, _edited);
    if (assigned == null || !mounted) return;

    setState(() {
      _supplier.text = assigned.supplierName ?? '';
      _registrationNo.text = assigned.supplierRegistrationNo ?? '';
      _taxId.text = assigned.supplierTaxId ?? '';
      _email.text = assigned.supplierEmail ?? '';
      _phone.text = assigned.supplierPhone ?? '';
      _address.text = assigned.supplierAddress ?? '';
      _documentNo.text = assigned.documentNo ?? '';
      _currency.text = assigned.currency ?? '';
      _subtotal.text = _money(assigned.subtotal);
      _tax.text = _money(assigned.taxAmount);
      _total.text = _money(assigned.totalAmount);
      _date = assigned.documentDate;

      for (final line in _lines) {
        line.dispose();
      }
      _lines
        ..clear()
        ..addAll([for (final line in assigned.lines) _EditableLine.from(line)]);
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final foots = _doesNotFoot;

    return AlertDialog(
      title: const Text('What the document says'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_nothing)
                Text(
                  'Nothing legible came back. A sharper photograph of the '
                  'whole receipt, flat and in daylight, usually does it — '
                  'or type the figures in below.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              // Editable even when nothing was read: a reading that came
              // back empty and a form that refuses to open are the same
              // dead end, and the paper is already attached either way.
              const SizedBox(height: Space.sm),
              // Three lines, because a Malaysian company name plus its
              // two registration numbers does not fit on one and the
              // whole point of showing it is that it can be checked.
              _Field(label: 'Supplier', controller: _supplier, lines: 3),
              _Field(label: 'SSM no', controller: _registrationNo),
              _Field(label: 'Tax number', controller: _taxId),
              _Field(label: 'Email', controller: _email, email: true),
              _Field(label: 'Phone', controller: _phone, phone: true),
              _Field(label: 'Address', controller: _address, lines: 4),
              _Field(label: 'Document no', controller: _documentNo),
              _DateField(
                label: 'Date',
                value: _date,
                onPick: _pickDate,
                onClear: () => setState(() => _date = null),
              ),
              _Field(
                label: 'Currency',
                controller: _currency,
                capitals: true,
                maxLength: 3,
              ),
              _Field(
                label: 'Subtotal',
                controller: _subtotal,
                money: true,
                onChanged: (_) => setState(() {}),
              ),
              _Field(
                label: 'Tax',
                controller: _tax,
                money: true,
                onChanged: (_) => setState(() {}),
              ),
              _Field(
                label: 'Total',
                controller: _total,
                money: true,
                bold: true,
                onChanged: (_) => setState(() {}),
              ),
              const Divider(height: Space.xl),
              Row(children: [
                Expanded(
                  child: Text('Lines',
                      style: Theme.of(context).textTheme.labelLarge),
                ),
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _lines.add(_EditableLine.blank())),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                ),
              ]),
              if (_lines.isEmpty)
                Text(
                  'No lines were read.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              for (var i = 0; i < _lines.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _lines[i].description,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'Description',
                        ),
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    SizedBox(
                      width: 96,
                      child: TextField(
                        controller: _lines[i].amount,
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 13),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '0.00',
                        ),
                      ),
                    ),
                    // The reason this is here. A bill's footer reads as
                    // lines to anything working off printing alone, so a
                    // credit limit and a deposit arrive looking like
                    // charges and have to be removable.
                    IconButton(
                      tooltip: 'Remove this line',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() {
                        _lines.removeAt(i).dispose();
                      }),
                    ),
                  ]),
                ),
              if (foots != null) ...[
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(foots, style: const TextStyle(fontSize: 13)),
                      // Offered, not applied. The sum is arithmetic
                      // nobody disputes, but which of the three figures
                      // was misread is a judgement, so it takes a press.
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () => setState(() => _total.text =
                              ((_subtotalValue ?? 0) + (_taxValue ?? 0))
                                  .toStringAsFixed(2)),
                          child: Text('Set total to '
                              '${Fmt.money((_subtotalValue ?? 0) + (_taxValue ?? 0))}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ] else if (read.note != null && !_allThreeFigures) ...[
                const SizedBox(height: Space.md),
                Container(
                  padding: const EdgeInsets.all(Space.md),
                  decoration: BoxDecoration(
                    color: context.colors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(read.note!, style: const TextStyle(fontSize: 13)),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.canApply ? 'Discard' : 'Close'),
        ),
        // The way out of "the reader missed this and it is plainly
        // printed". Carries what is on this form in, so an assignment
        // made there lands beside the corrections made here rather than
        // on top of the original reading.
        TextButton(
          onPressed: _openAllData,
          child: const Text('All data'),
        ),
        if (widget.canApply)
          FilledButton(
            onPressed: () => Navigator.pop(context, _edited),
            child: const Text('Use these'),
          ),
      ],
    );
  }
}

/// One line of the document, while somebody is editing it.
class _EditableLine {
  _EditableLine({
    required this.description,
    required this.amount,
    this.quantity,
    this.unitPrice,
  });

  factory _EditableLine.from(OcrLine line) => _EditableLine(
        description: TextEditingController(text: line.description ?? ''),
        amount: TextEditingController(
            text: line.amount == null ? '' : line.amount!.toStringAsFixed(2)),
        quantity: line.quantity,
        unitPrice: line.unitPrice,
      );

  factory _EditableLine.blank() => _EditableLine(
        description: TextEditingController(),
        amount: TextEditingController(),
      );

  final TextEditingController description;
  final TextEditingController amount;

  /// Carried through untouched. Neither is shown — a bill's quantity and
  /// unit price are rarely what needs correcting, and two more boxes per
  /// line would make the common case worse to serve the rare one.
  final double? quantity;
  final double? unitPrice;

  bool get isEmpty =>
      description.text.trim().isEmpty && amount.text.trim().isEmpty;

  OcrLine toLine() => OcrLine(
        description: description.text.trim().isEmpty
            ? null
            : description.text.trim(),
        quantity: quantity,
        unitPrice: unitPrice,
        amount: _ScanResultDialogState._parse(amount.text),
      );

  void dispose() {
    description.dispose();
    amount.dispose();
  }
}

/// `myr` is not a currency anywhere it is compared against ISO codes,
/// and a lower-case one matching nothing is a silent wrong answer rather
/// than an error. Fixed as it is typed, on a phone keyboard that offers
/// no capitals of its own in this field.
class _Upper extends TextInputFormatter {
  const _Upper();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue _, TextEditingValue next) =>
      next.copyWith(text: next.text.toUpperCase());
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.money = false,
    this.bold = false,
    this.capitals = false,
    this.email = false,
    this.phone = false,
    this.lines = 1,
    this.maxLength,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final bool money;
  final bool bold;
  final bool capitals;
  final bool email;
  final bool phone;

  /// How tall the box may grow. One for a figure; more for a company
  /// name or an address, which wrap and are the fields somebody most
  /// needs to read in full before accepting them.
  final int lines;

  final int? maxLength;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(
          crossAxisAlignment:
              lines > 1 ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
        SizedBox(
          width: 110,
          child: Padding(
            padding: EdgeInsets.only(top: lines > 1 ? 10 : 0),
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        Expanded(
          child: TextField(
            // Named so a test can reach a figure by what it is rather
            // than by where it happens to sit in the column.
            key: ValueKey('scan-$label'),
            controller: controller,
            onChanged: onChanged,
            maxLength: maxLength,
            textCapitalization: capitals
                ? TextCapitalization.characters
                : TextCapitalization.none,
            inputFormatters: capitals ? const [_Upper()] : null,
            minLines: 1,
            maxLines: lines,
            keyboardType: money
                ? const TextInputType.numberWithOptions(decimal: true)
                : email
                    ? TextInputType.emailAddress
                    : phone
                        ? TextInputType.phone
                        : lines > 1
                            ? TextInputType.multiline
                            : null,
            style: TextStyle(
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            ),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              // What the reader could not find, said in the box rather
              // than in a row that looks filled in.
              hintText: 'Not on the document',
              prefixText: money ? Fmt.prefix('MYR') : null,
            ),
          ),
        ),
      ]),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPick,
    required this.onClear,
  });

  final String label;
  final DateTime? value;
  final VoidCallback onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(children: [
        SizedBox(
          width: 110,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: InkWell(
            onTap: onPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Text(
                    value == null ? 'Not on the document' : Fmt.date(value),
                    style: TextStyle(
                      color: value == null
                          ? context.scheme.onSurfaceVariant
                          : null,
                      fontStyle: value == null ? FontStyle.italic : null,
                    ),
                  ),
                ),
                if (value != null)
                  IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: onClear,
                  ),
                const Icon(Icons.calendar_today_outlined, size: 16),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
