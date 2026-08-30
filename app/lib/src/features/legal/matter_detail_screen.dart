import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'matter_billing.dart';

/// A single matter: client money held, time recorded and disbursements.
///
/// The client ledger is the important half. Money here belongs to the
/// client, not the firm, and the database refuses any movement that would
/// overdraw the matter.
class MatterDetailScreen extends ConsumerStatefulWidget {
  const MatterDetailScreen({super.key, required this.matterId});

  final String matterId;

  @override
  ConsumerState<MatterDetailScreen> createState() =>
      _MatterDetailScreenState();
}

class _MatterDetailScreenState extends ConsumerState<MatterDetailScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summaries = ref.watch(matterSummaryProvider);
    final canPost = ref.watch(canPostProvider);

    return Scaffold(
      appBar: AppBar(
        title: AsyncView(
          value: summaries,
          loading: const Text('Matter'),
          builder: (list) {
            final s = list.where((e) => e.matterId == widget.matterId).firstOrNull;
            return Text(s == null ? 'Matter' : '${s.matterNo} · ${s.matterName}',
                overflow: TextOverflow.ellipsis);
          },
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Client account'),
            Tab(text: 'Time'),
            Tab(text: 'Disbursements'),
          ],
        ),
      ),
      body: Column(
        children: [
          AsyncView(
            value: summaries,
            loading: const LinearProgressIndicator(),
            builder: (list) {
              final s =
                  list.where((e) => e.matterId == widget.matterId).firstOrNull;
              if (s == null) return const SizedBox.shrink();
              return _MatterHeader(summary: s);
            },
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _ClientLedgerTab(matterId: widget.matterId, canPost: canPost),
                _TimeTab(matterId: widget.matterId),
                _DisbursementsTab(matterId: widget.matterId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MatterHeader extends StatelessWidget {
  const _MatterHeader({required this.summary});

  final MatterSummary summary;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final figures = <({String label, double value, Color? colour})>[
      (label: 'Client funds held', value: summary.clientFunds, colour: context.colors.info),
      (label: 'Unbilled time', value: summary.unbilledTime, colour: null),
      (
        label: 'Unbilled disbursements',
        value: summary.unbilledDisbursements,
        colour: null
      ),
      (
        label: 'Outstanding bills',
        value: summary.outstanding,
        colour: summary.outstanding > 0 ? context.colors.warning : null
      ),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Wrap(
        spacing: narrow ? 16 : 40,
        runSpacing: 12,
        children: [
          for (final f in figures)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(f.label, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  Fmt.money(f.value),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: f.colour,
                      ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ClientLedgerTab extends ConsumerWidget {
  const _ClientLedgerTab({required this.matterId, required this.canPost});

  final String matterId;
  final bool canPost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txns = ref.watch(clientTransactionsProvider(matterId));

    return Scaffold(
      floatingActionButton: canPost
          ? FloatingActionButton.extended(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _ClientMoneyDialog(matterId: matterId),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Client money'),
            )
          : null,
      body: AsyncView(
        value: txns,
        onRetry: () => ref.invalidate(clientTransactionsProvider(matterId)),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.account_balance_outlined,
              title: 'No client money yet',
              message: 'Record a deposit when the client places funds with '
                  'the firm. Client money is held separately from office money.',
            );
          }

          // Show a running balance so the ledger reads like a bank statement.
          var running = 0.0;
          final rows = <({ClientTransaction txn, double balance})>[];
          for (final t in list) {
            running += t.amount;
            rows.add((txn: t, balance: running));
          }

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = rows[rows.length - 1 - i];
              final t = r.txn;
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
                leading: CircleAvatar(
                  backgroundColor: (t.isMoneyIn ? context.colors.success : context.colors.warning)
                      .withValues(alpha: 0.15),
                  child: Icon(
                    t.isMoneyIn ? Icons.south_west : Icons.north_east,
                    size: 18,
                    color: t.isMoneyIn ? context.colors.success : context.colors.warning,
                  ),
                ),
                title: Text(
                  t.description ?? Fmt.label(t.transactionType),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                subtitle: Text(
                  [
                    t.transactionNo,
                    Fmt.date(t.transactionDate),
                    if ((t.payee ?? '').isNotEmpty) 'to ${t.payee}',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Money(t.amount, bold: true, colorNegative: true),
                    Text('bal ${Fmt.money(r.balance)}',
                        style: const TextStyle(fontSize: 11)),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ClientMoneyDialog extends ConsumerStatefulWidget {
  const _ClientMoneyDialog({required this.matterId});

  final String matterId;

  @override
  ConsumerState<_ClientMoneyDialog> createState() =>
      _ClientMoneyDialogState();
}

class _ClientMoneyDialogState extends ConsumerState<_ClientMoneyDialog> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _payee = TextEditingController();
  final _reference = TextEditingController();

  String _type = 'receipt';
  DateTime _date = DateTime.now();
  bool _saving = false;

  bool get _isMoneyIn => _type == 'receipt' || _type == 'transfer_in';

  @override
  void dispose() {
    for (final c in [_amount, _description, _payee, _reference]) {
      c.dispose();
    }
    super.dispose();
  }

  double get _available {
    final list = ref.read(clientTransactionsProvider(widget.matterId)).value ??
        const <ClientTransaction>[];
    return list.fold<double>(0, (sum, t) => sum + t.amount);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final entered = double.tryParse(_amount.text) ?? 0;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.recordClientTransaction(
            matterId: widget.matterId,
            transactionType: _type,
            // The ledger stores a signed amount; money out is negative.
            amount: _isMoneyIn ? entered : -entered,
            date: _date,
            description: _description.text.trim().isEmpty
                ? null
                : _description.text.trim(),
            payee: _payee.text.trim().isEmpty ? null : _payee.text.trim(),
            reference: _reference.text.trim().isEmpty
                ? null
                : _reference.text.trim(),
          ),
      successMessage: 'Client account updated and posted',
      pendingMessage: 'Posting…',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshMatter(ref, widget.matterId);
      refreshLedgerData(ref);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entered = double.tryParse(_amount.text) ?? 0;
    final wouldOverdraw = !_isMoneyIn && entered > _available;

    return AlertDialog(
      title: const Text('Client account movement'),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  value: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(
                        value: 'receipt', child: Text('Received from client')),
                    DropdownMenuItem(
                        value: 'payment',
                        child: Text('Paid out on client’s behalf')),
                    DropdownMenuItem(
                        value: 'transfer_to_office',
                        child: Text('Transfer to office (settle a bill)')),
                    DropdownMenuItem(
                        value: 'refund', child: Text('Refund to client')),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? 'receipt'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amount,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Amount *',
                    prefixText: 'RM ',
                    helperText: _isMoneyIn
                        ? null
                        : '${Fmt.money(_available)} available on this matter',
                    helperStyle: TextStyle(
                        color: wouldOverdraw ? context.colors.danger : null),
                  ),
                  validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                      ? 'Enter an amount'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                if (!_isMoneyIn) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _payee,
                    decoration: const InputDecoration(
                      labelText: 'Paid to',
                      hintText: 'e.g. Lembaga Hasil Dalam Negeri',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          suffixIcon: Icon(Icons.calendar_today, size: 18),
                        ),
                        child: Text(Fmt.date(_date)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _reference,
                      decoration: const InputDecoration(labelText: 'Reference'),
                    ),
                  ),
                ]),
                if (wouldOverdraw) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(Space.md),
                    decoration: BoxDecoration(
                      color: context.colors.danger.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: context.colors.danger.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      'This matter only holds ${Fmt.money(_available)}. Client '
                      'money held for one matter cannot fund another, so this '
                      'will be rejected.',
                      style: TextStyle(
                          color: context.colors.danger, fontSize: 12),
                    ),
                  ),
                ],
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
          onPressed: _saving || wouldOverdraw ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Record and post'),
        ),
      ],
    );
  }
}

class _TimeTab extends ConsumerWidget {
  const _TimeTab({required this.matterId});

  final String matterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(timeEntriesProvider(matterId));
    final canWrite = ref.watch(canWriteProvider);

    // What could be invoiced today. Shown on the button because the
    // question a partner asks of this screen is how much is sitting
    // here unbilled, and until now the screen could not answer it.
    final unbilled = entries.valueOrNull
            ?.where((e) => e.isBillable && !e.isBilled) ??
        const <TimeEntry>[];

    return Scaffold(
      floatingActionButton: !canWrite
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (unbilled.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.sm),
                    child: FloatingActionButton.extended(
                      key: const ValueKey('bill-time'),
                      heroTag: 'bill-time',
                      onPressed: () =>
                          showBillMatterSheet(context, matterId: matterId),
                      icon: const Icon(Icons.request_quote_outlined),
                      label: Text('Bill ${Fmt.money(billableTotal(unbilled))}'),
                    ),
                  ),
                FloatingActionButton.extended(
                  heroTag: 'record-time',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _TimeDialog(matterId: matterId),
                  ),
                  icon: const Icon(Icons.timer_outlined),
                  label: const Text('Record time'),
                ),
              ],
            ),
      body: AsyncView(
        value: entries,
        onRetry: () => ref.invalidate(timeEntriesProvider(matterId)),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.timer_outlined,
              title: 'No time recorded',
              message: 'Record time as you work. Once there is billable '
                  'time here, it can be invoiced from this tab.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = list[i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
                title: Text(e.description,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    Fmt.date(e.entryDate),
                    e.duration,
                    if (e.activityCode != null) Fmt.label(e.activityCode),
                    if (e.isBilled) 'billed',
                    if (!e.isBillable) 'non-billable',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Money(e.amount, bold: true),
              );
            },
          );
        },
      ),
    );
  }
}

class _TimeDialog extends ConsumerStatefulWidget {
  const _TimeDialog({required this.matterId});

  final String matterId;

  @override
  ConsumerState<_TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends ConsumerState<_TimeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _hours = TextEditingController();
  final _rate = TextEditingController();

  String _activity = 'drafting';
  DateTime _date = DateTime.now();
  bool _billable = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Default the rate to the matter's agreed hourly rate.
    final matters = ref.read(mattersProvider((status: 'all', search: ''))).value;
    final matter = matters?.where((m) => m.id == widget.matterId).firstOrNull;
    if (matter != null && matter.hourlyRate > 0) {
      _rate.text = matter.hourlyRate.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    for (final c in [_description, _hours, _rate]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final hours = double.tryParse(_hours.text) ?? 0;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.addTimeEntry(
            matterId: widget.matterId,
            description: _description.text.trim(),
            minutes: (hours * 60).round(),
            hourlyRate: double.tryParse(_rate.text) ?? 0,
            date: _date,
            activityCode: _activity,
            billable: _billable,
          ),
      successMessage: 'Time recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshMatter(ref, widget.matterId);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hours = double.tryParse(_hours.text) ?? 0;
    final rate = double.tryParse(_rate.text) ?? 0;

    return AlertDialog(
      title: const Text('Record time'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _description,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'What did you do? *',
                  hintText: 'e.g. Drafting sale and purchase agreement',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _hours,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Hours *', hintText: '1.5'),
                    validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                        ? 'Enter hours'
                        : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _rate,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                        labelText: 'Rate', prefixText: 'RM '),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _activity,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Activity'),
                items: const [
                  DropdownMenuItem(value: 'drafting', child: Text('Drafting')),
                  DropdownMenuItem(
                      value: 'attendance', child: Text('Attendance')),
                  DropdownMenuItem(value: 'research', child: Text('Research')),
                  DropdownMenuItem(value: 'court', child: Text('Court')),
                  DropdownMenuItem(
                      value: 'correspondence', child: Text('Correspondence')),
                  DropdownMenuItem(value: 'travel', child: Text('Travel')),
                ],
                onChanged: (v) => setState(() => _activity = v ?? 'drafting'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(Fmt.date(_date)),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _billable,
                onChanged: (v) => setState(() => _billable = v),
                title: const Text('Billable'),
              ),
              if (hours > 0 && rate > 0)
                Row(children: [
                  const Expanded(child: Text('Value')),
                  Money(hours * rate, bold: true),
                ]),
            ],
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
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _DisbursementsTab extends ConsumerWidget {
  const _DisbursementsTab({required this.matterId});

  final String matterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(disbursementsProvider(matterId));
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      floatingActionButton: canWrite
          ? FloatingActionButton.extended(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => _DisbursementDialog(matterId: matterId),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Disbursement'),
            )
          : null,
      body: AsyncView(
        value: items,
        onRetry: () => ref.invalidate(disbursementsProvider(matterId)),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.receipt_outlined,
              title: 'No disbursements',
              message: 'Costs paid on the client’s behalf — search fees, '
                  'stamp duty, filing fees — belong here.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = list[i];
              return ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.xs),
                title: Text(d['description']?.toString() ?? '—',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  [
                    Fmt.date(Fmt.parseDate(d['disbursement_date'])),
                    'paid from ${d['paid_from']}',
                    if (d['is_billed'] == true) 'billed',
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Money(
                  Fmt.toDouble(d['amount']) + Fmt.toDouble(d['tax_amount']),
                  bold: true,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _DisbursementDialog extends ConsumerStatefulWidget {
  const _DisbursementDialog({required this.matterId});

  final String matterId;

  @override
  ConsumerState<_DisbursementDialog> createState() =>
      _DisbursementDialogState();
}

class _DisbursementDialogState extends ConsumerState<_DisbursementDialog> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();

  String _paidFrom = 'office';
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.addDisbursement(
            matterId: widget.matterId,
            description: _description.text.trim(),
            amount: double.tryParse(_amount.text) ?? 0,
            date: _date,
            paidFrom: _paidFrom,
          ),
      successMessage: 'Disbursement recorded',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      refreshMatter(ref, widget.matterId);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Record a disbursement'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _description,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Description *',
                  hintText: 'e.g. Land search fees',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Amount *', prefixText: 'RM '),
                validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                    ? 'Enter an amount'
                    : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _paidFrom,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Paid from',
                  helperText: 'Office money is recoverable from the client',
                ),
                items: const [
                  DropdownMenuItem(
                      value: 'office', child: Text('Office account')),
                  DropdownMenuItem(
                      value: 'client', child: Text('Client account')),
                ],
                onChanged: (v) => setState(() => _paidFrom = v ?? 'office'),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Date',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(Fmt.date(_date)),
                ),
              ),
            ],
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
              : const Text('Save'),
        ),
      ],
    );
  }
}
