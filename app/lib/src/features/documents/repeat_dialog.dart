import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';

/// Turns the document on screen into a schedule that raises a copy of
/// it on a cadence.
///
/// The document is copied, not pointed at. Editing this invoice
/// afterwards does not change what gets billed next month, which is
/// deliberate: a schedule that changes because somebody tidied up an old
/// document is a schedule nobody can trust.
Future<void> showRepeatDialog(
  BuildContext context,
  String documentId,
  String docNo,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RepeatDialog(documentId: documentId, docNo: docNo),
  );
}

class _RepeatDialog extends ConsumerStatefulWidget {
  const _RepeatDialog({required this.documentId, required this.docNo});

  final String documentId;
  final String docNo;

  @override
  ConsumerState<_RepeatDialog> createState() => _RepeatDialogState();
}

class _RepeatDialogState extends ConsumerState<_RepeatDialog> {
  late final TextEditingController _name =
      TextEditingController(text: 'Repeat of ${widget.docNo}');
  final _count = TextEditingController();

  String _frequency = 'monthly';
  int _interval = 1;
  DateTime _start = DateTime.now().add(const Duration(days: 1));
  DateTime? _end;
  bool _autoPost = false;
  bool _autoEmail = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _count.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.createRecurringDocument(
            documentId: widget.documentId,
            name: _name.text.trim(),
            frequency: _frequency,
            startDate: _start,
            intervalCount: _interval,
            endDate: _end,
            maxOccurrences: int.tryParse(_count.text.trim()),
            autoPost: _autoPost,
            // Emailing a draft would send a customer a document with no
            // number they can pay against, so the database ignores it
            // unless the schedule also posts. Keeping the two in step
            // here stops the switch looking like it did nothing.
            autoEmail: _autoEmail && _autoPost,
          ),
      successMessage: 'It will repeat from ${Fmt.date(_start)}',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(recurringDocumentsProvider);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Repeat this document'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'What this schedule is, on the Recurring list',
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                SizedBox(
                  width: 96,
                  child: TextFormField(
                    initialValue: '$_interval',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Every'),
                    onChanged: (v) =>
                        _interval = int.tryParse(v.trim()) ?? 1,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: _frequency,
                    decoration: const InputDecoration(labelText: 'Period'),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('Day')),
                      DropdownMenuItem(value: 'weekly', child: Text('Week')),
                      DropdownMenuItem(value: 'monthly', child: Text('Month')),
                      DropdownMenuItem(
                          value: 'quarterly', child: Text('Quarter')),
                      DropdownMenuItem(value: 'yearly', child: Text('Year')),
                    ],
                    onChanged: (v) =>
                        setState(() => _frequency = v ?? 'monthly'),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              _DateRow(
                label: 'First one on',
                value: _start,
                onPick: (d) => setState(() => _start = d),
              ),
              _DateRow(
                label: 'Stop after',
                value: _end,
                emptyLabel: 'No end date',
                onPick: (d) => setState(() => _end = d),
                onClear: () => setState(() => _end = null),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _count,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Or stop after this many',
                  hintText: 'Leave empty to keep going',
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoPost,
                onChanged: (v) => setState(() => _autoPost = v),
                title: const Text('Post it automatically'),
                subtitle: const Text(
                    'Off leaves a draft for somebody to check first'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _autoEmail,
                // Nothing is worth emailing until it is posted, so this
                // stays unavailable rather than silently doing nothing.
                onChanged:
                    _autoPost ? (v) => setState(() => _autoEmail = v) : null,
                title: const Text('Email it to the customer'),
                subtitle: Text(_autoPost
                    ? 'Needs email switched on in Settings'
                    : 'Only once it posts automatically'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Repeat'),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.value,
    required this.onPick,
    this.emptyLabel,
    this.onClear,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onPick;
  final String? emptyLabel;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        TextButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: value ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) onPick(picked);
          },
          child: Text(value == null ? emptyLabel ?? '—' : Fmt.date(value)),
        ),
        if (onClear != null && value != null)
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClear,
          ),
      ]),
    );
  }
}
