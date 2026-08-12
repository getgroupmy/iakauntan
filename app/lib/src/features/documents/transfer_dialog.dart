import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import 'doc_types.dart';
import 'transfer.dart';

/// Takes a document forward into the next one in its cycle.
///
/// Opens on the quantities still outstanding rather than on the original
/// ones, so the common case — "the rest of it" — is already filled in and
/// the partial case is a matter of typing over a number rather than
/// working one out.
///
/// Returns the new document's id, or null if nothing was created.
Future<String?> showTransferDialog(
  BuildContext context,
  WidgetRef ref, {
  required String sourceId,
  required String sourceType,
  required String targetType,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TransferDialog(
      sourceId: sourceId,
      sourceType: sourceType,
      targetType: targetType,
    ),
  );
}

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog({
    required this.sourceId,
    required this.sourceType,
    required this.targetType,
  });

  final String sourceId;
  final String sourceType;
  final String targetType;

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  List<TransferLine>? _lines;
  String? _loadError;
  bool _working = false;

  /// Quantity being taken from each line, seeded with everything
  /// outstanding.
  final Map<String, double> _wanted = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final lines = await ref
          .read(repoProvider)!
          .transferOutstanding(widget.sourceId, widget.targetType);
      if (!mounted) return;
      setState(() {
        _lines = lines;
        for (final l in lines) {
          _wanted[l.lineId] = l.outstanding;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = '$e');
    }
  }

  Future<void> _transfer() async {
    final lines = _lines;
    if (lines == null) return;

    final problem = transferProblem(lines, _wanted);
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }

    setState(() => _working = true);
    try {
      final id = await ref.read(repoProvider)!.transferDocument(
            sourceId: widget.sourceId,
            targetType: widget.targetType,
            lines: [
              for (final l in lines)
                if ((_wanted[l.lineId] ?? 0) > 0)
                  (lineId: l.lineId, quantity: _wanted[l.lineId]!),
            ],
          );
      ref.invalidate(documentsProvider);
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _working = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = metaFor(widget.targetType).singular;
    final lines = _lines;

    return AlertDialog(
      title: Text('Transfer to $target'),
      content: SizedBox(
        width: 560,
        child: switch (null) {
          _ when _loadError != null =>
            Text('Could not read what is outstanding: $_loadError'),
          _ when lines == null => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          _ when lines.every((l) => l.outstanding <= 0) => Text(
              'Every line has already been taken forward to a '
              '${target.toLowerCase()}.',
            ),
          _ => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'The quantities below are what is still outstanding. '
                    'Change them to transfer only part.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  for (final line in lines)
                    _LineRow(
                      line: line,
                      value: _wanted[line.lineId] ?? 0,
                      onChanged: (v) =>
                          setState(() => _wanted[line.lineId] = v),
                    ),
                ],
              ),
            ),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _working || lines == null ? null : _transfer,
          child: _working
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Create $target'),
        ),
      ],
    );
  }
}

class _LineRow extends StatefulWidget {
  const _LineRow({
    required this.line,
    required this.value,
    required this.onChanged,
  });

  final TransferLine line;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_LineRow> createState() => _LineRowState();
}

class _LineRowState extends State<_LineRow> {
  late final TextEditingController _controller =
      TextEditingController(text: Fmt.qty(widget.value));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final spent = line.outstanding <= 0;
    final over = widget.value > line.outstanding;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.description.isEmpty
                      ? 'Line ${line.lineNo}'
                      : line.description,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  spent
                      ? 'All ${Fmt.qty(line.quantity)} already taken'
                      : '${Fmt.qty(line.outstanding)} of '
                          '${Fmt.qty(line.quantity)} outstanding',
                  style: TextStyle(
                    fontSize: 11,
                    color: spent ? context.colors.warning : null,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 110,
            child: TextField(
              controller: _controller,
              enabled: !spent,
              textAlign: TextAlign.right,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                errorText: over ? 'Too many' : null,
              ),
              onChanged: (v) => widget.onChanged(double.tryParse(v) ?? 0),
            ),
          ),
        ],
      ),
    );
  }
}
