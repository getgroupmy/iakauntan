import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// What you have told yourself to do, at the top of the dashboard.
///
/// The work that keeps a set of books straight is mostly work that has
/// no row: chase the Ramli invoice, file the SST return, ask the client
/// for the April statements. None of it posts and none of it was
/// anywhere this system could show it.
///
/// Deliberately SHORT. This is the top of a list, not the list: five
/// items and a way through to the rest. A card that grows without limit
/// pushes the figures off the screen, and the figures are what most
/// people opened the dashboard for.
class TodoCard extends ConsumerWidget {
  const TodoCard({super.key, this.limit = 5});

  final int limit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todosProvider(false));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              'To do',
              subtitle: todos.valueOrNull == null
                  ? null
                  : _subtitle(todos.value!, DateTime.now()),
              action: TextButton(
                onPressed: () => context.go('/todos'),
                child: const Text('Open the list'),
              ),
            ),
            todos.when(
              // Outlined as the card's own rows and NOT as
              // `ListSkeleton`: a to-do is a checkbox and two short
              // lines, about forty-eight tall, where a `ListTile` with
              // a subtitle is seventy-two. Five of those is a card half
              // as tall again as the one that replaces it.
              loading: () => CardRowsSkeleton(
                rows: limit,
                leadingSize: 24,
                rowGap: Space.md,
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('The list could not be read. $e'),
              ),
              data: (items) => items.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('Nothing on your list. Add something to '
                          'come back to.'),
                    )
                  : Column(
                      children: [
                        for (final todo in items.take(limit))
                          _TodoRow(todo: todo),
                        if (items.length > limit)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'and ${items.length - limit} more',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// "4 open, 1 overdue" — and never "0 overdue", because a count of
  /// nothing is a word the eye has to read to discover it says nothing.
  static String _subtitle(List<Todo> items, DateTime today) {
    final overdue = items.where((t) => t.isOverdue(today)).length;
    final open = '${items.length} open';
    return overdue == 0 ? open : '$open, $overdue overdue';
  }
}

class _TodoRow extends ConsumerWidget {
  const _TodoRow({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overdue = todo.isOverdue(DateTime.now());
    final danger = context.colors.danger;

    return InkWell(
      onTap: todo.link == null ? null : () => context.go(todo.link!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            // Ticking it here writes it away at once. There is no undo
            // bar: putting it back is the same checkbox.
            Checkbox(
              value: todo.isDone,
              onChanged: (v) async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                await repo.setTodoDone(todo.id, v ?? false);
                ref.invalidate(todosProvider);
              },
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(todo.title, maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (todo.dueDate != null)
                    Text(
                      overdue
                          ? 'Overdue — ${Fmt.date(todo.dueDate)}'
                          : Fmt.date(todo.dueDate),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: overdue ? danger : null,
                      ),
                    ),
                ],
              ),
            ),
            if (todo.priority == 'high')
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.flag, size: 16, color: danger),
              ),
          ],
        ),
      ),
    );
  }
}
