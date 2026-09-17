import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'log_attempt_sheet.dart';

/// The chasing worklist.
///
/// The order is the database's, not this screen's: broken promises,
/// then customers nobody has rung, then oldest debt. A list sorted here
/// would eventually disagree with the report it came from, and the point
/// of the ordering is that the top of the list is the money most likely
/// to be lost if nobody looks at it today.
class CollectionsScreen extends ConsumerWidget {
  const CollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worklist = ref.watch(collectionsWorklistProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Collections')),
      body: AsyncView(
        value: worklist,
        onRetry: () => ref.invalidate(collectionsWorklistProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.sentiment_satisfied_outlined,
              title: 'Nothing outstanding',
              message: 'Every invoice raised has been paid.',
            );
          }

          final owed = list.fold<num>(
            0,
            (a, r) => a + (r['outstanding'] as num? ?? 0),
          );
          final broken = list.where((r) => r['promise_broken'] == true).length;
          final cold = list.where((r) => r['never_chased'] == true).length;

          return Column(
            children: [
              _Summary(owed: owed, broken: broken, cold: cold),
              Expanded(
                child: ListView.separated(
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _CustomerTile(row: list[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.owed,
    required this.broken,
    required this.cold,
  });

  final num owed;
  final int broken;
  final int cold;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      color: (broken > 0 ? context.colors.danger : context.colors.warning)
          .withValues(alpha: 0.10),
      child: Text(
        [
          '${Fmt.money(owed)} outstanding',
          if (broken > 0) '$broken broken promise${broken == 1 ? '' : 's'}',
          if (cold > 0) '$cold never chased',
        ].join(' · '),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _CustomerTile extends ConsumerWidget {
  const _CustomerTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final broken = row['promise_broken'] == true;
    final cold = row['never_chased'] == true;
    final promise = row['promise_date'] as String?;
    final last = row['last_attempt_on'] as String?;

    // Three states, three sentences. "Never chased" is not the same as
    // "chased and got nowhere", and a credit controller decides what to
    // do next from that difference.
    final String status;
    if (broken) {
      status = 'Promised ${Fmt.date(DateTime.parse(promise!))} and did not pay';
    } else if (promise != null) {
      status = 'Promised ${Fmt.date(DateTime.parse(promise))}';
    } else if (cold) {
      status = 'Never chased';
    } else {
      status =
          'Last contacted ${Fmt.date(DateTime.parse(last!))}'
          '${row['last_outcome'] == null ? '' : ' — ${row['last_outcome']}'}';
    }

    return ListTile(
      leading: Icon(
        broken
            ? Icons.running_with_errors_outlined
            : cold
            ? Icons.phone_missed_outlined
            : Icons.schedule_outlined,
        color: broken
            ? context.colors.danger
            : cold
            ? context.colors.warning
            : null,
      ),
      title: Text(
        row['contact_name'] as String? ?? '—',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '$status\n'
        '${row['invoices']} invoice${row['invoices'] == 1 ? '' : 's'} · '
        'oldest ${row['oldest_days']} days'
        '${row['assigned_name'] == null ? '' : ' · ${row['assigned_name']}'}',
        style: TextStyle(
          fontSize: 12,
          color: broken ? context.colors.danger : null,
        ),
      ),
      isThreeLine: true,
      trailing: Money(row['outstanding'] as num?, bold: true),
      onTap: () => showLogAttemptSheet(
        context,
        ref,
        contactId: row['contact_id'] as String,
        contactName: row['contact_name'] as String? ?? '',
        outstanding: row['outstanding'] as num? ?? 0,
      ),
    );
  }
}
