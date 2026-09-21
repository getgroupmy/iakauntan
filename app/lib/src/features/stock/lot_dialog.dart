import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';

/// Naming the units on one document line.
///
/// Two jobs that look the same and are not. On a **receipt** the numbers
/// are being created — they are printed on the boxes in front of
/// somebody and nothing in the system knows them yet. On an **issue**
/// they are being chosen from what is on hand, and picking one that was
/// never received has to fail.
///
/// So the issue side offers what is actually there, shortest-dated
/// first, and can fill the whole line in one tap. The receipt side is an
/// empty list you type into, with the expiry date beside each number
/// because that is the moment it is known and the last moment anybody
/// will bother.
class LotDialog extends ConsumerStatefulWidget {
  const LotDialog({
    super.key,
    required this.existing,
    required this.itemId,
    required this.itemCode,
    required this.tracking,
    required this.quantity,
    required this.receiving,
    this.warehouseId,
  });

  /// Works entirely in memory and hands the new allocation back. It
  /// cannot write through a line id: saving a document deletes its lines
  /// and reinserts them, so the id a dialog was opened against does not
  /// survive the next save. The editor holds the allocation and writes
  /// it once, after the lines have their final ids.
  final List<Map<String, dynamic>> existing;
  final String itemId;
  final String itemCode;

  /// `batch` or `serial`.
  final String tracking;
  final double quantity;

  /// Stock coming in, as against going out.
  final bool receiving;
  final String? warehouseId;

  bool get isSerial => tracking == 'serial';

  @override
  ConsumerState<LotDialog> createState() => _LotDialogState();
}

class _Entry {
  _Entry({String ref = '', double? qty, this.expiry})
      : ref = TextEditingController(text: ref),
        qty = TextEditingController(text: qty == null ? '' : Fmt.qty(qty));

  final TextEditingController ref;
  final TextEditingController qty;
  DateTime? expiry;

  void dispose() {
    ref.dispose();
    qty.dispose();
  }
}

class _LotDialogState extends ConsumerState<LotDialog> {
  final _entries = <_Entry>[];
  bool _loading = true;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final e in _entries) {
      e.dispose();
    }
    super.dispose();
  }

  void _load() {
    for (final r in widget.existing) {
      _entries.add(_Entry(
        ref: r['lot_ref']?.toString() ?? '',
        qty: r['quantity'] == null ? null : Fmt.toDouble(r['quantity']),
        expiry: r['expiry_date'] == null
            ? null
            : DateTime.parse(r['expiry_date'].toString()),
      ));
    }
    if (_entries.isEmpty) _entries.add(_Entry());
    _loading = false;
  }

  double get _named => _entries.fold(0, (a, e) {
        if (e.ref.text.trim().isEmpty) return a;
        return a + (widget.isSerial ? 1 : (double.tryParse(e.qty.text) ?? 0));
      });

  double get _short => widget.quantity - _named;

  /// Fills the line from what is on hand, shortest-dated first.
  Future<void> _suggest() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    try {
      final picks = await repo.suggestLots(
        itemId: widget.itemId,
        warehouseId: widget.warehouseId,
        quantity: widget.quantity,
      );
      if (!mounted) return;
      setState(() {
        for (final e in _entries) {
          e.dispose();
        }
        _entries
          ..clear()
          ..addAll(picks.map((p) => _Entry(
                ref: p['lot_ref']?.toString() ?? '',
                qty: Fmt.toDouble(p['take']),
                expiry: p['expiry_date'] == null
                    ? null
                    : DateTime.parse(p['expiry_date'].toString()),
              )));
        if (_entries.isEmpty) _entries.add(_Entry());
      });
      if (picks.isEmpty && mounted) {
        setState(() => _failure = 'Nothing of ${widget.itemCode} is on hand.');
      }
    } catch (e) {
      if (mounted) setState(() => _failure = '$e');
    }
  }

  void _save() {
    final lots = [
      for (final e in _entries)
        if (e.ref.text.trim().isNotEmpty)
          {
            'lot_ref': e.ref.text.trim(),
            if (!widget.isSerial) 'quantity': double.tryParse(e.qty.text) ?? 0,
            if (widget.receiving && e.expiry != null)
              'expiry_date': Fmt.iso(e.expiry!),
          },
    ];
    Navigator.pop(context, lots);
  }

  @override
  Widget build(BuildContext context) {
    final noun = widget.isSerial ? 'Serial numbers' : 'Batches';

    return AlertDialog(
      title: Text('$noun for ${widget.itemCode}'),
      content: SizedBox(
        width: 520,
        child: _loading
            // A heading line, then a row per batch or serial number,
            // each with a reference and a quantity box.
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: Space.md),
                child: CardRowsSkeleton(
                  rows: 4,
                  leading: false,
                  lines: 1,
                  trailing: 1,
                  trailingWidth: 110,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text(
                        _short == 0
                            ? 'All ${Fmt.qty(widget.quantity)} accounted for'
                            : _short > 0
                                ? '${Fmt.qty(_short)} of '
                                    '${Fmt.qty(widget.quantity)} still to name'
                                : '${Fmt.qty(-_short)} more than the line',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: _short == 0
                              ? context.colors.success
                              : context.colors.danger,
                        ),
                      ),
                    ),
                    if (!widget.receiving)
                      TextButton.icon(
                        onPressed: _suggest,
                        icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                        label: const Text('Fill from stock'),
                      ),
                  ]),
                  const SizedBox(height: Space.sm),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < _entries.length; i++)
                            _Line(
                              entry: _entries[i],
                              serial: widget.isSerial,
                              receiving: widget.receiving,
                              onChanged: () => setState(() {}),
                              onRemove: _entries.length == 1
                                  ? null
                                  : () => setState(() {
                                        _entries.removeAt(i).dispose();
                                      }),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _entries.add(_Entry())),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(widget.isSerial ? 'Another one' : 'Another batch'),
                    ),
                  ),
                  if (_failure != null)
                    Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(_failure!,
                          style: TextStyle(color: context.colors.danger)),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Refused here as well as in the database. The database is the
          // guarantee; this is so nobody has to press a button to be
          // told something the screen already knew.
          onPressed: _short != 0 ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.entry,
    required this.serial,
    required this.receiving,
    required this.onChanged,
    this.onRemove,
  });

  final _Entry entry;
  final bool serial;
  final bool receiving;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: entry.ref,
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              labelText: serial ? 'Serial number' : 'Batch number',
            ),
          ),
        ),
        if (!serial) ...[
          const SizedBox(width: Space.sm),
          SizedBox(
            width: 96,
            child: TextField(
              controller: entry.qty,
              onChanged: (_) => onChanged(),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Quantity',
              ),
            ),
          ),
        ],
        if (receiving) ...[
          const SizedBox(width: Space.sm),
          SizedBox(
            width: 132,
            child: OutlinedButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: entry.expiry ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  entry.expiry = picked;
                  onChanged();
                }
              },
              child: Text(
                entry.expiry == null ? 'Expiry' : Fmt.date(entry.expiry!),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
        IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 18),
        ),
      ]),
    );
  }
}
