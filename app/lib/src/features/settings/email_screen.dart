import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Mail: who it comes from, when to chase, and what went out.
///
/// The app cannot send. It queues a row and the `send-email` edge
/// function — the only thing holding a provider key — drains the queue
/// on a schedule. That is why this screen has an outbox at all: a
/// message that failed is a row somebody can look at and retry rather
/// than a line in a log nobody reads.
class EmailScreen extends ConsumerWidget {
  const EmailScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Email'),
          bottom: const TabBar(tabs: [
            Tab(text: 'Settings'),
            Tab(text: 'Outbox'),
          ]),
        ),
        body: const TabBarView(children: [_SettingsTab(), _OutboxTab()]),
      ),
    );
  }
}

class _SettingsTab extends ConsumerStatefulWidget {
  const _SettingsTab();

  @override
  ConsumerState<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<_SettingsTab> {
  final _fromName = TextEditingController();
  final _replyTo = TextEditingController();
  final _minAmount = TextEditingController(text: '0');
  final _days = TextEditingController();

  bool _enabled = false;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [_fromName, _replyTo, _minAmount, _days]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(emailSettingsProvider);
    final canAdmin = ref.watch(canAdminProvider);

    return AsyncView(
      value: settings,
      onRetry: () => ref.invalidate(emailSettingsProvider),
      builder: (row) {
        if (!_loaded) {
          _loaded = true;
          _enabled = row?['is_enabled'] == true;
          _fromName.text = row?['from_name']?.toString() ?? '';
          _replyTo.text = row?['reply_to']?.toString() ?? '';
          _minAmount.text =
              Fmt.toDouble(row?['reminder_min_amount']).toStringAsFixed(2);
          _days.text = ((row?['reminder_days'] as List?) ?? const [])
              .map((e) => e.toString())
              .join(', ');
        }

        return SingleChildScrollView(
          child: PageBody(
            maxWidth: 760,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('Sending',
                            subtitle: 'Off until you turn it on, so nothing '
                                'reaches a customer by accident'),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          value: _enabled,
                          onChanged:
                              canAdmin ? (v) => setState(() => _enabled = v) : null,
                          title: const Text('Send email from this company'),
                        ),
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: _fromName,
                          enabled: canAdmin,
                          decoration: const InputDecoration(
                            labelText: 'From name',
                            helperText: 'The address itself is set on the '
                                'server, not here',
                          ),
                        ),
                        const SizedBox(height: Space.md),
                        TextField(
                          controller: _replyTo,
                          enabled: canAdmin,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'Replies go to',
                            hintText: 'accounts@yourcompany.com',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Space.lg),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionHeader('Chasing overdue invoices',
                            subtitle: 'Sent by the nightly job, once each'),
                        TextField(
                          controller: _days,
                          enabled: canAdmin,
                          decoration: const InputDecoration(
                            labelText: 'Days after the due date',
                            hintText: '0, 7, 30',
                            helperText: 'Zero is the due date itself; a '
                                'negative number is before it. Empty means '
                                'never chase.',
                          ),
                        ),
                        const SizedBox(height: Space.md),
                        TextField(
                          controller: _minAmount,
                          enabled: canAdmin,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'Only chase amounts above',
                            prefixText: 'RM ',
                            helperText: 'Chasing somebody for eight ringgit '
                                'costs more goodwill than it collects',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (canAdmin) ...[
                  const SizedBox(height: Space.lg),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Save'),
                    ),
                  ),
                ],
                const SizedBox(height: Space.xxl),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _save() async {
    // "0, 7, 30" from a text field, with whatever somebody actually
    // typed thrown away rather than sent as a null in an int array.
    final days = _days.text
        .split(RegExp(r'[^\-0-9]+'))
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet()
        .toList()
      ..sort();

    setState(() => _saving = true);
    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveEmailSettings({
        'is_enabled': _enabled,
        'from_name': _fromName.text.trim().isEmpty ? null : _fromName.text.trim(),
        'reply_to': _replyTo.text.trim().isEmpty ? null : _replyTo.text.trim(),
        'reminder_days': days,
        'reminder_min_amount': double.tryParse(_minAmount.text.trim()) ?? 0,
      }),
      successMessage: 'Saved',
    );
    if (mounted) setState(() => _saving = false);
    ref.invalidate(emailSettingsProvider);
  }
}

class _OutboxTab extends ConsumerStatefulWidget {
  const _OutboxTab();

  @override
  ConsumerState<_OutboxTab> createState() => _OutboxTabState();
}

class _OutboxTabState extends ConsumerState<_OutboxTab> {
  String _status = 'all';
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(emailOutboxProvider(_status));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _send(null),
        icon: const Icon(Icons.send),
        label: const Text('Send queued'),
      ),
      body: Column(children: [
        FilterBar(
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'all', label: Text('All')),
              ButtonSegment(value: 'queued', label: Text('Queued')),
              ButtonSegment(value: 'failed', label: Text('Failed')),
              ButtonSegment(value: 'sent', label: Text('Sent')),
            ],
            selected: {_status},
            onSelectionChanged: (s) => setState(() => _status = s.first),
          ),
        ),
        Expanded(
          child: AsyncView(
            value: rows,
            onRetry: () => ref.invalidate(emailOutboxProvider(_status)),
            builder: (list) => list.isEmpty
                ? const EmptyState(
                    icon: Icons.outbox_outlined,
                    title: 'Nothing here',
                    message: 'Messages queued from a document or by the '
                        'nightly reminder run appear here.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 96),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _MessageTile(
                      row: list[i],
                      onRetry: () => _send(list[i]['id'] as String),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Future<void> _send(String? id) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(repoProvider)!.sendQueuedEmail(id: id);
      messenger.showSnackBar(SnackBar(
        content: Text('Sent ${result['sent'] ?? 0}, '
            'failed ${result['failed'] ?? 0}'),
      ));
    } catch (err) {
      // The likeliest error by far is that nobody has set the provider
      // key yet, and the function says so in as many words.
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
    if (mounted) setState(() => _busy = false);
    ref.invalidate(emailOutboxProvider(_status));
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.row, required this.onRetry});

  final Map<String, dynamic> row;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'queued';
    final doc = row['sales_documents'];
    final error = row['last_error']?.toString();

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      title: Row(children: [
        Flexible(
          child: Text(row['subject']?.toString() ?? '',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(status, compact: true),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              row['to_email']?.toString() ?? '',
              if (doc is Map && doc['doc_no'] != null) doc['doc_no'].toString(),
              Fmt.dateTime(Fmt.parseDate(row['queued_at'])),
              if (Fmt.toInt(row['attempts']) > 1)
                '${Fmt.toInt(row['attempts'])} attempts',
            ].where((s) => s.isNotEmpty).join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          if (error != null && error.isNotEmpty)
            Text(error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: context.colors.danger)),
        ],
      ),
      isThreeLine: error != null && error.isNotEmpty,
      trailing: status == 'failed' || status == 'queued'
          ? TextButton(onPressed: onRetry, child: const Text('Send'))
          : null,
    );
  }
}
