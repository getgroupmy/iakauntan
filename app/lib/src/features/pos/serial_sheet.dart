import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Scanning the machines that are leaving the shop.
///
/// `0540` taught the till to sell dated stock and stopped short of
/// serials, saying why: a batch names a production run and picking one
/// is a true statement, but a serial names ONE PHYSICAL UNIT, and
/// picking one on the customer's behalf would print on their warranty
/// the number of a machine the next customer walks out with. It said
/// that wanted a scan field at the till. This is it.
///
/// ## Why the sheet, and not a box on the line
///
/// A serialised sale is two machines and two labels, held one at a
/// time, at arm's length, on a bright counter. It needs a field that
/// keeps focus between scans, a list of what has gone in so far, and a
/// way to take one off — which is a sheet, not a cell in a row.
///
/// ## Every scan goes to the server
///
/// The obvious build keeps a list locally and sends it at payment. That
/// is the build that refuses six scans deep, in front of a queue, with
/// the bag packed and no clue which label was wrong.
///
/// So each scan is a round trip, and the refusals are the server's:
/// a label read twice, a machine already sold, one sitting in the
/// basket at the next till, a serial this shop never received. Each
/// comes back naming the label in the cashier's hand.
///
/// ## The field does not validate
///
/// It trims, and it refuses to send nothing. Everything else — does
/// this serial exist, is it on THIS shelf, is it already on a bill —
/// is a question only the database can answer, and a second opinion
/// here would be a second implementation of a rule that already has
/// one.
class SerialSheet extends StatefulWidget {
  const SerialSheet({
    super.key,
    required this.description,
    required this.serials,
    required this.onScan,
    required this.onRemove,
  });

  /// What is being sold, so the sheet says which line it belongs to.
  final String description;

  /// What has been scanned onto the line already.
  final List<String> serials;

  /// Sends one scan. Returns the new list, or throws — and what it
  /// throws is shown as it arrives, because the server's sentences
  /// name the label.
  final Future<List<String>> Function(String serial) onScan;

  final Future<List<String>> Function(String serial) onRemove;

  @override
  State<SerialSheet> createState() => _SerialSheetState();
}

class _SerialSheetState extends State<SerialSheet> {
  late List<String> _serials = List.of(widget.serials);
  final _field = TextEditingController();
  final _focus = FocusNode();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final ref = _field.text.trim();
    if (ref.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await widget.onScan(ref);
      if (!mounted) return;
      setState(() {
        _serials = next;
        _field.clear();
      });
    } catch (e) {
      if (!mounted) return;
      // The whole point of scanning one at a time. The message names
      // the label, so it is shown whole rather than summarised.
      setState(() => _error = _saying(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      // A barcode scanner is a keyboard, and a keyboard that has lost
      // focus types into nothing. Taken back after every scan, wrong
      // ones included: the next thing that happens is another scan.
      _focus.requestFocus();
    }
  }

  Future<void> _remove(String serial) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await widget.onRemove(serial);
      if (!mounted) return;
      setState(() => _serials = next);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _saying(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      _focus.requestFocus();
    }
  }

  /// What the server said, without the exception's own wrapping. A
  /// cashier reading "PostgrestException(message: Serial SN-A1 is
  /// already on this line...)" at arm's length reads none of it.
  static String _saying(Object e) {
    final raw = e.toString();
    final m = RegExp(r'message:\s*([^,]+)').firstMatch(raw);
    return (m?.group(1) ?? raw).trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(widget.description),
              subtitle: Text(
                _serials.isEmpty
                    ? 'Scan the serial number on each one'
                    : '${_serials.length} scanned',
              ),
              trailing: IconButton(
                key: const ValueKey('serial-close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(_serials),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.lg,
                Space.sm,
              ),
              child: TextField(
                key: const ValueKey('serial-field'),
                controller: _field,
                focusNode: _focus,
                autofocus: true,
                enabled: !_busy,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Serial number',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.qr_code_scanner),
                  suffixIcon: IconButton(
                    key: const ValueKey('serial-add'),
                    icon: const Icon(Icons.add),
                    onPressed: _busy ? null : _send,
                  ),
                  // The scanner sends a newline, so the ordinary way
                  // this field is used never touches the button.
                  helperText: 'Scan it, or type it and press enter',
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        _error!,
                        key: const ValueKey('serial-error'),
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            if (_serials.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.sm,
                  Space.lg,
                  Space.lg,
                ),
                child: Text('Nothing scanned yet.'),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in _serials)
                      ListTile(
                        dense: true,
                        key: ValueKey('serial-$s'),
                        leading: const Icon(Icons.memory, size: 18),
                        title: Text(s),
                        trailing: IconButton(
                          key: ValueKey('serial-remove-$s'),
                          icon: const Icon(Icons.close),
                          tooltip: 'Wrong label',
                          onPressed: _busy ? null : () => _remove(s),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
