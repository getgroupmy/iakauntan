import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Matter list for a law firm. The headline figure is client funds held,
/// because that is the number a firm is answerable for.
class MattersScreen extends ConsumerStatefulWidget {
  const MattersScreen({super.key});

  @override
  ConsumerState<MattersScreen> createState() => _MattersScreenState();
}

class _MattersScreenState extends ConsumerState<MattersScreen> {
  String _status = 'open';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final matters = ref.watch(mattersProvider((status: _status, search: _search)));
    final summaries = ref.watch(matterSummaryProvider).value ?? const [];
    final canWrite = ref.watch(canWriteProvider);

    final byId = {for (final s in summaries) s.matterId: s};
    final totalHeld = summaries.fold<double>(0, (sum, s) => sum + s.clientFunds);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Matters'),
        actions: [
          if (canWrite)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _MatterDialog(),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New matter'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
            child: Row(children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: const InputDecoration(
                    hintText: 'Search matter name or number',
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'open', label: Text('Open')),
                  ButtonSegment(value: 'closed', label: Text('Closed')),
                  ButtonSegment(value: 'all', label: Text('All')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
            ]),
          ),
        ),
      ),
      body: AsyncView(
        value: matters,
        onRetry: () => ref.invalidate(mattersProvider),
        builder: (list) {
          if (list.isEmpty) {
            return EmptyState(
              icon: Icons.gavel_outlined,
              title: 'No matters yet',
              message: 'Open a file to start recording time, disbursements '
                  'and client money against it.',
              action: canWrite
                  ? FilledButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _MatterDialog(),
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('New matter'),
                    )
                  : null,
            );
          }

          return Column(
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
                color: context.colors.info.withValues(alpha: 0.10),
                child: Row(children: [
                  const Icon(Icons.account_balance_outlined, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${list.length} matters · ${Fmt.money(totalHeld)} '
                      'held in the client account',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                ]),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _MatterTile(
                    matter: list[i],
                    summary: byId[list[i].id],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MatterTile extends StatelessWidget {
  const _MatterTile({required this.matter, this.summary});

  final Matter matter;
  final MatterSummary? summary;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: () => context.go('/legal/${matter.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
      title: Row(children: [
        Text(matter.matterNo,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 10),
        StatusChip(matter.status, compact: true),
      ]),
      subtitle: Text(
        '${matter.name} · ${matter.clientName ?? '—'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Money(summary?.clientFunds ?? 0, bold: true),
          Text(
            summary == null || summary!.workInProgress == 0
                ? 'client funds'
                : '${Fmt.money(summary!.workInProgress)} unbilled',
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _MatterDialog extends ConsumerStatefulWidget {
  const _MatterDialog();

  @override
  ConsumerState<_MatterDialog> createState() => _MatterDialogState();
}

class _MatterDialogState extends ConsumerState<_MatterDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _rate = TextEditingController(text: '450');
  final _deposit = TextEditingController();
  final _courtRef = TextEditingController();

  String? _clientId;
  String _matterType = 'conveyancing';
  bool _saving = false;

  static const _types = {
    'conveyancing': 'Conveyancing',
    'litigation': 'Litigation',
    'corporate': 'Corporate & Commercial',
    'probate': 'Probate & Estate',
    'family': 'Family',
    'employment': 'Employment',
    'intellectual_property': 'Intellectual Property',
    'other': 'Other',
  };

  @override
  void dispose() {
    for (final c in [_name, _rate, _deposit, _courtRef]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.createMatter({
        'name': _name.text.trim(),
        'client_id': _clientId,
        'matter_type': _matterType,
        'court_reference': _courtRef.text.trim().isEmpty
            ? null
            : _courtRef.text.trim(),
        'hourly_rate': double.tryParse(_rate.text) ?? 0,
        'deposit_required': double.tryParse(_deposit.text) ?? 0,
        'responsible_solicitor': ref.read(currentUserProvider)?.id,
      }),
      successMessage: 'Matter opened',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(mattersProvider);
      ref.invalidate(matterSummaryProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final clients =
        ref.watch(contactsProvider((type: 'customer', search: ''))).value ??
            const <Contact>[];

    return AlertDialog(
      title: const Text('Open a matter'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Matter name *',
                    hintText: 'e.g. Sale of 12 Jalan Bukit',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _clientId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Client *'),
                  items: [
                    for (final c in clients)
                      DropdownMenuItem(value: c.id, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() => _clientId = v),
                  validator: (v) => v == null ? 'Choose a client' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _matterType,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Matter type'),
                  items: [
                    for (final e in _types.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) =>
                      setState(() => _matterType = v ?? 'other'),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _rate,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                          labelText: 'Hourly rate', prefixText: 'RM '),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _deposit,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Deposit required',
                        prefixText: 'RM ',
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _courtRef,
                  decoration:
                      const InputDecoration(labelText: 'Court reference'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Open matter'),
        ),
      ],
    );
  }
}
