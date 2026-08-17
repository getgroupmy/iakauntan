import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// What was said, and what happens next.
///
/// Opens on the history, because the first thing anybody needs before
/// ringing a customer is what the last person was told. The form is
/// underneath it.
Future<void> showLogAttemptSheet(
  BuildContext context,
  WidgetRef ref, {
  required String contactId,
  required String contactName,
  required num outstanding,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _LogAttemptSheet(
      contactId: contactId,
      contactName: contactName,
      outstanding: outstanding,
    ),
  );
}

class _LogAttemptSheet extends ConsumerStatefulWidget {
  const _LogAttemptSheet({
    required this.contactId,
    required this.contactName,
    required this.outstanding,
  });

  final String contactId;
  final String contactName;
  final num outstanding;

  @override
  ConsumerState<_LogAttemptSheet> createState() => _LogAttemptSheetState();
}

class _LogAttemptSheetState extends ConsumerState<_LogAttemptSheet> {
  String _channel = 'call';
  String _outcome = 'no_answer';
  DateTime? _promiseDate;
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  static const _channels = {
    'call': 'Called',
    'email': 'Emailed',
    'whatsapp': 'WhatsApp',
    'sms': 'Texted',
    'letter': 'Letter',
    'visit': 'Visited',
    'meeting': 'Met',
  };

  // Worded as what happened, not as a status code. Somebody logging a
  // call at four on a Friday should not have to translate.
  static const _outcomes = {
    'no_answer': 'No answer',
    'promised': 'Promised to pay',
    'part_paid': 'Paid something',
    'paid': 'Paid in full',
    'disputed': 'Disputes the invoice',
    'refused': 'Refused to pay',
    'unreachable': 'Cannot be reached',
    'escalated': 'Escalated',
  };

  Future<void> _save() async {
    // The database refuses `promised` with no date. Saying so here means
    // the person sees it before the round trip rather than as a raised
    // exception afterwards; the database still refuses it either way,
    // which is the half that matters.
    if (_outcome == 'promised' && _promiseDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Say which date they promised, or it will never '
            'come back round.',
          ),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .logCollectionAttempt(
            contactId: widget.contactId,
            channel: _channel,
            outcome: _outcome,
            promiseDate: _promiseDate,
            notes: _notes.text,
          ),
      successMessage: 'Logged',
      pendingMessage: 'Saving…',
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      ref.invalidate(collectionsWorklistProvider);
      ref.invalidate(collectionHistoryProvider(widget.contactId));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(collectionHistoryProvider(widget.contactId));

    return Padding(
      padding: EdgeInsets.only(
        left: Space.lg,
        right: Space.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + Space.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.contactName,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${Fmt.money(widget.outstanding)} outstanding',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),

          // What the last person was told, before anybody dials.
          history.maybeWhen(
            data: (rows) => rows.isEmpty
                ? const SizedBox.shrink()
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final h in rows.take(6))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '${Fmt.date(DateTime.parse(h['attempted_on'] as String))}'
                              ' · ${_outcomes[h['outcome']] ?? h['outcome']}'
                              '${h['notes'] == null ? '' : ' — ${h['notes']}'}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          const Divider(),

          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _channel,
                  decoration: const InputDecoration(labelText: 'How'),
                  items: [
                    for (final e in _channels.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _channel = v!),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _outcome,
                  decoration: const InputDecoration(labelText: 'What happened'),
                  items: [
                    for (final e in _outcomes.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() {
                    _outcome = v!;
                    // A promise date only belongs to "promised"; the
                    // database refuses it anywhere else, so clear it
                    // rather than let somebody submit a contradiction.
                    if (_outcome != 'promised') _promiseDate = null;
                  }),
                ),
              ),
            ],
          ),

          if (_outcome == 'promised') ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _promiseDate == null
                        ? 'No date yet'
                        : 'Promised ${Fmt.date(_promiseDate)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now().add(const Duration(days: 7)),
                      // Not before today: a promise to have paid last
                      // week is a typo, and the database refuses it.
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                    );
                    if (picked != null) setState(() => _promiseDate = picked);
                  },
                  child: const Text('Pick a date'),
                ),
              ],
            ),
          ],

          const SizedBox(height: 8),
          TextField(
            controller: _notes,
            decoration: const InputDecoration(
              labelText: 'What they said',
              hintText: 'Waiting on their own customer, cheque Friday…',
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Log it'),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
