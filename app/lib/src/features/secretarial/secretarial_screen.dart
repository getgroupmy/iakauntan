import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/corp_models.dart';
import 'filing_lifecycle.dart';

/// The secretarial desk: what is falling due, and for whom.
///
/// A secretarial firm's whole risk is a missed date, so the deadlines
/// come first and the client list second. Every date here is computed
/// from the company's own incorporation date and year end against the
/// section that imposes it — none of it is typed in, so none of it can
/// be typed in wrongly.
class SecretarialScreen extends ConsumerWidget {
  const SecretarialScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filings = ref.watch(corpFilingsProvider);
    final entities = ref.watch(corpEntitiesProvider);
    final canWrite = ref.watch(canWriteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Company secretarial'),
        actions: [
          // The people are a list of their own because they outlive any
          // one company: a director resigns from one board and sits on
          // another with the same NRIC and the same file.
          TextButton.icon(
            key: const ValueKey('open-people'),
            onPressed: () => context.go('/secretarial/people'),
            icon: const Icon(Icons.badge_outlined, size: 18),
            label: const Text('People'),
          ),
          if (canWrite)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: FilledButton.icon(
                onPressed: () => context.go('/secretarial/new'),
                icon: const Icon(Icons.domain_add, size: 18),
                label: const Text('Add company'),
              ),
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: PageBody(
          maxWidth: 1100,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DeadlinesCard(filings: filings),
              const SizedBox(height: Space.lg),
              _EntitiesCard(entities: entities),
              const SizedBox(height: Space.xxl),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeadlinesCard extends ConsumerWidget {
  const _DeadlinesCard({required this.filings});

  final AsyncValue<List<CorpFiling>> filings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'Falling due',
              subtitle: 'Computed from each company’s incorporation date and '
                  'year end, against the section that imposes it',
            ),
            AsyncView(
              value: filings,
              onRetry: () => ref.invalidate(corpFilingsProvider),
              skeleton: const CardRowsSkeleton(
                  rows: 4, leadingSize: 24, trailing: 2),
              builder: (list) {
                if (list.isEmpty) {
                  return const EmptyState(
                    icon: Icons.event_available_outlined,
                    title: 'Nothing due',
                    message: 'No statutory deadline falls inside the next six '
                        'months for the companies on your books.',
                  );
                }
                final overdue = list.where((f) => f.isOverdue).length;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (overdue > 0) _OverdueNotice(count: overdue),
                    for (var i = 0; i < list.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _FilingRow(filing: list[i]),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _OverdueNotice extends StatelessWidget {
  const _OverdueNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.colors.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: context.colors.danger.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(Icons.error_outline, size: 18, color: context.colors.danger),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            '$count ${count == 1 ? 'filing is' : 'filings are'} past the '
            'statutory deadline. Late lodgement carries a penalty and, for a '
            'charge under s.352, costs the security altogether.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }
}

class _FilingRow extends ConsumerWidget {
  const _FilingRow({required this.filing});

  final CorpFiling filing;

  Color _colour(BuildContext context) => filing.isOverdue
      ? context.colors.danger
      : filing.isUrgent
          ? context.colors.warning
          : context.scheme.onSurfaceVariant;

  String get _when {
    final d = filing.daysLeft;
    if (d < 0) return '${-d} days late';
    if (d == 0) return 'due today';
    return 'in $d days';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return InkWell(
      onTap: () => context.go('/secretarial/${filing.entityId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 6, right: Space.md),
              decoration: BoxDecoration(
                  color: _colour(context), shape: BoxShape.circle),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(filing.entityName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    filing.filingName +
                        (filing.legacyForm == null
                            ? ''
                            : ' (${filing.legacyForm})'),
                    style: muted,
                  ),
                  Text(
                    '${filing.statuteRef} · triggered '
                    '${Fmt.date(filing.triggerDate)}',
                    style: muted,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(Fmt.date(filing.dueDate),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(_when,
                      style: muted?.copyWith(
                        color: _colour(context),
                        fontWeight: filing.isOverdue || filing.isUrgent
                            ? FontWeight.w600
                            : null,
                      )),
                  // Whether anybody has taken this deadline up. The
                  // list is computed from the Act, so without this it
                  // shows the same filing as due for as long as the
                  // company exists, however many times it was lodged.
                  const SizedBox(height: 4),
                  _step(context, ref),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(BuildContext context, WidgetRef ref) {
    final next = filingNextStep(filing.filingId, filing.status);
    if (next == 'done') {
      return StatusChip(filing.status, compact: true);
    }
    return TextButton(
      key: ValueKey('filing-step-${filing.entityId}-${filing.filingType}'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: () => showFilingStep(context, filing: filing),
      child: Text(next == 'open' ? 'Start it' : 'Lodged?'),
    );
  }
}

class _EntitiesCard extends ConsumerWidget {
  const _EntitiesCard({required this.entities});

  final AsyncValue<List<CorpEntity>> entities;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Companies on the books'),
            AsyncView(
              value: entities,
              onRetry: () => ref.invalidate(corpEntitiesProvider),
              skeleton: const CardRowsSkeleton(rows: 4, trailing: 1),
              builder: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.domain_outlined,
                      title: 'No companies yet',
                      message: 'Add the first company you act for. Its '
                          'statutory deadlines are computed from the '
                          'incorporation date and year end.',
                    )
                  : Column(children: [
                      for (var i = 0; i < list.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _EntityTile(entity: list[i]),
                      ],
                    ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntityTile extends StatelessWidget {
  const _EntityTile({required this.entity});

  final CorpEntity entity;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: () => context.go('/secretarial/${entity.id}'),
      title: Row(children: [
        Flexible(
          child: Text(entity.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(entity.status, compact: true),
      ]),
      subtitle: Text(
        '${entity.typeLabel} · ${entity.registrationNo ?? 'no number'}'
        '${entity.incorporatedOn == null ? '' : ' · incorporated ${Fmt.date(entity.incorporatedOn)}'}'
        ' · year end ${entity.fyeLabel}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
    );
  }
}
