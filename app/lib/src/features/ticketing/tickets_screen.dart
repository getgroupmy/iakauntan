import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import 'teams_screen.dart';

/// The queue.
///
/// Defaults to everything still owed an answer rather than to everything
/// ever raised. A service desk opened on eight hundred closed tickets is
/// a screen people learn to filter before they can read, so the filter
/// starts where the work is.
///
/// "Open" here means the four states that are still ours — new, open,
/// pending and on hold. A ticket waiting on the requester has not left
/// the queue; it is simply not moving, and hiding it is how it gets
/// forgotten.
class TicketsScreen extends ConsumerStatefulWidget {
  const TicketsScreen({super.key});

  @override
  ConsumerState<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends ConsumerState<TicketsScreen> {
  TicketQuery _q = const TicketQuery();

  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(ticketsProvider(_q));
    final teams = ref.watch(ticketTeamsProvider);
    // Names for the ids on each row. Two small lists the screen is
    // already fetching, rather than an embed on a composite key.
    final teamNames = _names(teams);
    final categoryNames = _names(ref.watch(ticketCategoriesProvider));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Service desk'),
        actions: [
          // Where a team is created and its membership filled in.
          // `ticket_teams` could be filtered by and never created, so
          // every team in existence came from a demo seed; and 0192's
          // `ticket_team_members` was written by nothing at all, which
          // made routing a label rather than a decision.
          IconButton(
            key: const ValueKey('ticket-teams'),
            tooltip: 'Support teams',
            icon: const Icon(Icons.groups_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TicketTeamsScreen(),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          // No inner scroll view: `FilterBar` already scrolls
          // horizontally, and a second horizontal viewport inside it is
          // offered unbounded width and asserts in `performResize`
          // before it draws -- so this bar has never appeared. The Row
          // alone is what the other fifteen filter bars do.
          child: FilterBar(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'open', label: Text('Open')),
                    ButtonSegment(value: 'resolved', label: Text('Resolved')),
                    ButtonSegment(value: 'closed', label: Text('Closed')),
                    ButtonSegment(value: 'all', label: Text('All')),
                  ],
                  selected: {_q.status ?? 'all'},
                  onSelectionChanged: (s) => setState(() {
                    final v = s.first;
                    _q = _q.copyWith(status: () => v == 'all' ? null : v);
                  }),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: const Text('Mine'),
                  selected: _q.onlyMine,
                  onSelected: (v) => setState(() {
                    _q = _q.copyWith(onlyMine: v);
                  }),
                ),
                const SizedBox(width: 8),
                // The one filter worth a colour: a breached ticket is
                // a promise already broken, not a ticket that is
                // merely late.
                FilterChip(
                  label: const Text('Breached'),
                  selected: _q.onlyBreached,
                  selectedColor: context.colors.danger.withValues(alpha: 0.18),
                  onSelected: (v) => setState(() {
                    _q = _q.copyWith(onlyBreached: v);
                  }),
                ),
                const SizedBox(width: 8),
                teams.maybeWhen(
                  data: (list) => list.isEmpty
                      ? const SizedBox.shrink()
                      : _TeamFilter(
                          teams: list,
                          selected: _q.teamId,
                          onChanged: (id) => setState(() {
                            _q = _q.copyWith(teamId: () => id);
                          }),
                        ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/tickets/new'),
        icon: const Icon(Icons.add),
        label: const Text('New ticket'),
      ),
      body: AsyncView(
        value: tickets,
        onRetry: () => ref.invalidate(ticketsProvider(_q)),
        skeleton: const ListSkeleton(rows: 6),
        builder: (list) {
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.support_agent_outlined,
              title: 'Nothing in this queue',
              message: 'No ticket matches these filters.',
            );
          }
          return PageBody(
            child: ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _TicketRow(
                list[i],
                teamNames: teamNames,
                categoryNames: categoryNames,
              ),
            ),
          );
        },
      ),
    );
  }
}

Map<String, String> _names(AsyncValue<List<Map<String, dynamic>>> v) => {
  for (final row in v.value ?? const <Map<String, dynamic>>[])
    row['id'] as String: (row['name'] ?? '') as String,
};

class _TeamFilter extends StatelessWidget {
  const _TeamFilter({
    required this.teams,
    required this.selected,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> teams;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: selected,
        hint: const Text('All teams'),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All teams'),
          ),
          for (final t in teams)
            DropdownMenuItem<String?>(
              value: t['id'] as String,
              child: Text((t['name'] ?? '') as String),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _TicketRow extends StatelessWidget {
  const _TicketRow(
    this.t, {
    required this.teamNames,
    required this.categoryNames,
  });

  final Map<String, dynamic> t;
  final Map<String, String> teamNames;
  final Map<String, String> categoryNames;

  @override
  Widget build(BuildContext context) {
    final breached =
        (t['response_breached'] as bool? ?? false) ||
        (t['resolution_breached'] as bool? ?? false);
    final team = teamNames[t['team_id']];
    final category = categoryNames[t['category_id']];
    final due = t['resolution_due_at'] as String?;

    return ListTile(
      onTap: () => context.go('/tickets/${t['id']}'),
      leading: _PriorityPip(t['priority'] as String? ?? 'p3'),
      title: Text(
        (t['subject'] ?? '') as String,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          t['ticket_no'],
          if (category != null) category,
          if (team != null) team,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          StatusChip((t['status'] ?? '') as String, compact: true),
          const SizedBox(height: 4),
          if (breached)
            Text(
              'SLA breached',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: context.colors.danger,
                fontWeight: FontWeight.w600,
              ),
            )
          else if (due != null)
            Text(
              'due ${Fmt.dateTime(DateTime.parse(due).toLocal())}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

/// Priority as a colour and a label rather than a number nobody reads.
/// P1 is the only one that gets to shout.
class _PriorityPip extends StatelessWidget {
  const _PriorityPip(this.priority);

  final String priority;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (priority) {
      'p1' => c.danger,
      'p2' => c.warning,
      'p3' => c.info,
      _ => const Color(0xFF94A3B8),
    };
    return CircleAvatar(
      radius: 16,
      backgroundColor: color.withValues(alpha: 0.16),
      child: Text(
        priority.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
