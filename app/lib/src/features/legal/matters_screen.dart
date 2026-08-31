import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'matter_conflicts.dart';
import 'over_agreed_fee_dialog.dart';

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
          // Fixed-fee files that have gone past what the client was
          // told. `agreed_fee` was a column nothing read, so a firm
          // found out from the client.
          IconButton(
            key: const ValueKey('matters-over-fee'),
            tooltip: 'Over the agreed fee',
            icon: const Icon(Icons.price_change_outlined),
            onPressed: () => showMattersOverAgreedFee(context),
          ),
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
  final _opposing = TextEditingController();
  final _agreedFee = TextEditingController();
  final _conflictNote = TextEditingController();

  String? _clientId;
  String _matterType = 'conveyancing';
  bool _saving = false;

  /// What the firm already has that touches these parties. Asked of
  /// the database as the client and the other side are chosen, because
  /// the answer is what decides whether a written reason is required —
  /// and finding out after pressing Open is finding out too late.
  List<MatterConflict> _conflicts = const [];
  bool _checking = false;

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
    for (final c in [
      _name,
      _rate,
      _deposit,
      _courtRef,
      _opposing,
      _agreedFee,
      _conflictNote,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _recheck() async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    setState(() => _checking = true);
    try {
      final rows = await repo.checkMatterConflict(
        clientId: _clientId,
        opposingParty: _opposing.text.trim().isEmpty
            ? null
            : _opposing.text.trim(),
      );
      if (mounted) {
        setState(() => _conflicts =
            rows.map(MatterConflict.fromJson).toList());
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // One last look, in case somebody typed the other side and pressed
    // Open in the same second. The database asks again regardless; this
    // is so the answer arrives as a question rather than a refusal.
    await _recheck();
    if (!mounted) return;
    final why = matterBlockedBecause(
      name: _name.text,
      clientId: _clientId,
      conflicts: _conflicts,
      conflictNote: _conflictNote.text,
    );
    if (why != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(why)));
      return;
    }

    setState(() => _saving = true);

    final me = ref.read(currentUserProvider)?.id;
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.openMatter(
            name: _name.text.trim(),
            clientId: _clientId!,
            opposingParty: _opposing.text.trim().isEmpty
                ? null
                : _opposing.text.trim(),
            matterType: _matterType,
            feeEarner: me,
            responsible: me,
            agreedFee: double.tryParse(_agreedFee.text.trim()),
            hourlyRate: double.tryParse(_rate.text) ?? 0,
            conflictNote: _conflictNote.text.trim().isEmpty
                ? null
                : _conflictNote.text.trim(),
          ),
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
                  onChanged: (v) {
                    setState(() => _clientId = v);
                    _recheck();
                  },
                  validator: (v) => v == null ? 'Choose a client' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _opposing,
                  decoration: const InputDecoration(
                    labelText: 'Other side',
                    hintText: 'The party this file is against',
                    helperText: 'Checked against every file the firm has, '
                        'both ways round.',
                  ),
                  onEditingComplete: _recheck,
                  onTapOutside: (_) => _recheck(),
                ),
                if (_checking)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
                if (_conflicts.isNotEmpty) _ConflictPanel(
                  conflicts: _conflicts,
                  note: _conflictNote,
                  enabled: !_saving,
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
                Row(children: [
                  Expanded(
                    child: TextFormField(
                      controller: _agreedFee,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Agreed fee',
                        prefixText: 'RM ',
                        helperText: 'A fixed fee, if one was quoted.',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _courtRef,
                      decoration:
                          const InputDecoration(labelText: 'Court reference'),
                    ),
                  ),
                ]),
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

/// What the firm already has that touches these parties, and the box
/// that has to be filled in before the file can be opened anyway.
///
/// Shown rather than saved for the refusal, because Rule 3 of the Legal
/// Profession (Practice and Etiquette) Rules 1978 is a judgement a
/// solicitor makes and not one a form makes for them — but the file is
/// what is looked at afterwards, so the judgement gets written down.
class _ConflictPanel extends StatelessWidget {
  const _ConflictPanel({
    required this.conflicts,
    required this.note,
    required this.enabled,
  });

  final List<MatterConflict> conflicts;
  final TextEditingController note;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This would put the firm on both sides',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: context.colors.warning,
            ),
          ),
          const SizedBox(height: 4),
          for (final c in conflicts)
            Text('• ${describeConflict(c)}',
                style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: note,
            enabled: enabled,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Why this is clear *',
              helperText: 'Kept on the file. Consent obtained, unrelated '
                  'retainer, information barrier in place.',
            ),
          ),
        ],
      ),
    );
  }
}
