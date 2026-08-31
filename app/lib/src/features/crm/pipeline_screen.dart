import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'close_deal_dialog.dart';
import 'win_loss_dialog.dart';

/// Kanban board over the sales pipeline. Cards drag between stages; the
/// database trigger rewrites probability, status and stage history.
class PipelineScreen extends ConsumerWidget {
  const PipelineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stages = ref.watch(pipelineStagesProvider);
    final opportunities = ref.watch(opportunitiesProvider);
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales pipeline'),
        actions: [
          // The board says how much is in the pipeline. This says why it
          // keeps leaving, which is what the reasons `0373` started
          // collecting are for — a field with no reader is the same
          // failure in a different place.
          IconButton(
            key: const ValueKey('win-loss'),
            tooltip: 'Why deals closed',
            onPressed: () => showWinLoss(context),
            icon: const Icon(Icons.query_stats_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () {
              ref.invalidate(opportunitiesProvider);
              ref.invalidate(pipelineStagesProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _OpportunityDialog(),
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New deal'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: stages,
        onRetry: () => ref.invalidate(pipelineStagesProvider),
        builder: (stageList) => AsyncView(
          value: opportunities,
          onRetry: () => ref.invalidate(opportunitiesProvider),
          builder: (deals) {
            if (stageList.isEmpty) {
              return const EmptyState(
                icon: Icons.view_column_outlined,
                title: 'No pipeline configured',
                message: 'Create a pipeline with stages to start tracking deals.',
              );
            }

            final total = deals.fold<double>(0, (s, d) => s + d.amount);
            final weighted =
                deals.fold<double>(0, (s, d) => s + d.weightedAmount);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Text(
                    '${deals.length} open deals · ${Fmt.money(total)} '
                    '· ${Fmt.money(weighted)} weighted',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(Space.lg),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final stage in stageList)
                          _StageColumn(
                            stage: stage,
                            deals: deals
                                .where((d) => d.stageId == stage.id)
                                .toList(),
                            canWrite: canWrite,
                            onDrop: (deal) async {
                              if (deal.stageId == stage.id) return;
                              // Dropping on a closed column is the
                              // moment the reason is known, so it is the
                              // moment to ask. Before `0373` this was
                              // the same one-field update as any other
                              // move, and `lost_reason` stayed empty for
                              // every deal the company ever lost.
                              if (stage.stageType != 'open') {
                                final done = await showCloseDealDialog(
                                  context,
                                  deal: deal,
                                  stageType: stage.stageType,
                                );
                                if (done) {
                                  ref.invalidate(opportunitiesProvider);
                                  ref.invalidate(dashboardProvider);
                                }
                                return;
                              }
                              await ref
                                  .read(repoProvider)!
                                  .moveOpportunity(deal.id, stage.id);
                              ref.invalidate(opportunitiesProvider);
                              ref.invalidate(dashboardProvider);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StageColumn extends StatelessWidget {
  const _StageColumn({
    required this.stage,
    required this.deals,
    required this.canWrite,
    required this.onDrop,
  });

  final PipelineStage stage;
  final List<Opportunity> deals;
  final bool canWrite;
  final Future<void> Function(Opportunity) onDrop;

  Color get _color {
    final hex = stage.color;
    if (hex == null || !hex.startsWith('#') || hex.length != 7) {
      return const Color(0xFF94A3B8);
    }
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final total = deals.fold<double>(0, (s, d) => s + d.amount);

    return DragTarget<Opportunity>(
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidate, _) => Container(
        width: 280,
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: candidate.isNotEmpty
              ? _color.withValues(alpha: 0.10)
              : Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: candidate.isNotEmpty
                ? _color
                : Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: _color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stage.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('${deals.length}',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              Fmt.money(total),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (deals.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Drop deals here',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final deal in deals)
                _DealCard(deal: deal, draggable: canWrite),
          ],
        ),
      ),
    );
  }
}

class _DealCard extends StatelessWidget {
  const _DealCard({required this.deal, required this.draggable});

  final Opportunity deal;
  final bool draggable;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            deal.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          if (deal.contactName != null) ...[
            const SizedBox(height: 4),
            Text(
              deal.contactName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                Fmt.money(deal.amount, currency: deal.currency),
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const Spacer(),
              Text(
                Fmt.percent(deal.probability),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          if (deal.expectedCloseDate != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.event, size: 12),
                const SizedBox(width: 4),
                Text(
                  Fmt.date(deal.expectedCloseDate),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (!draggable) return card;

    return Draggable<Opportunity>(
      data: deal,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: 256, child: Opacity(opacity: 0.9, child: card)),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

class _OpportunityDialog extends ConsumerStatefulWidget {
  const _OpportunityDialog();

  @override
  ConsumerState<_OpportunityDialog> createState() => _OpportunityDialogState();
}

class _OpportunityDialogState extends ConsumerState<_OpportunityDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _amount = TextEditingController();

  String? _contactId;
  String? _stageId;
  DateTime? _closeDate;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final stages = ref.read(pipelineStagesProvider).value ?? const [];
    final stage = stages.firstWhere(
      (s) => s.id == _stageId,
      orElse: () => stages.first,
    );

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveOpportunity({
        'name': _name.text.trim(),
        'contact_id': _contactId,
        'pipeline_id': stage.pipelineId,
        'stage_id': stage.id,
        'amount': double.tryParse(_amount.text) ?? 0,
        'probability': stage.probability,
        'expected_close_date':
            _closeDate == null ? null : Fmt.iso(_closeDate!),
      }),
      successMessage: 'Deal created',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(opportunitiesProvider);
      ref.invalidate(dashboardProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stages = ref.watch(pipelineStagesProvider).value ?? const [];
    final contacts =
        ref.watch(contactsProvider((type: 'customer', search: ''))).value ??
            const <Contact>[];

    _stageId ??= stages.isNotEmpty ? stages.first.id : null;

    return AlertDialog(
      title: const Text('New deal'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Deal name *'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _contactId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Customer'),
                items: [
                  for (final c in contacts)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _contactId = v),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _amount,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Deal value', prefixText: 'RM '),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _stageId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Stage'),
                    items: [
                      for (final s in stages)
                        DropdownMenuItem(value: s.id, child: Text(s.name)),
                    ],
                    onChanged: (v) => setState(() => _stageId = v),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _closeDate ??
                        DateTime.now().add(const Duration(days: 30)),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) setState(() => _closeDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Expected close date',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(Fmt.date(_closeDate)),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
