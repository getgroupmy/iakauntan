/// One to-do, read rather than edited.
///
/// Asked for as: the to-do list page should show the list AND the
/// details of the item.
///
/// ## Why a detail at all, when the dialog exists
///
/// Before this, tapping an item opened the edit dialog. That is fine
/// for changing something and wrong for looking at it: a form shows
/// every field as a box, and the two things somebody actually wants
/// from a to-do — what it says, and what it is about — are the two the
/// old dialog clipped. The notes were a three-line box in a form and
/// two ellipsised lines in the list, so a to-do longer than a sentence
/// could not be read anywhere at all.
///
/// So: the list stays a list, and the detail says everything, with the
/// notes given as much room as they need. Editing is still the dialog,
/// one button away.
///
/// ## The facts are a list, not a paragraph
///
/// [todoFacts] returns the labelled lines the panel draws, which is
/// what makes them assertable — "an item with no due date does not show
/// an empty Due row" is a sentence about a list of pairs and nothing at
/// all about a widget tree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

/// One labelled line of the detail panel.
typedef TodoFact = ({String label, String value});

/// What is known about [todo], as labelled lines.
///
/// Absent facts are ABSENT rather than shown empty. A panel with "Due:
/// —" and "About: —" on every item teaches somebody that most of it is
/// blank and to stop reading; a panel with two lines on a bare item and
/// six on a full one is read every time.
///
/// [now] is passed rather than read, so "overdue" can be asserted
/// without waiting for a particular Tuesday.
List<TodoFact> todoFacts(Todo todo, DateTime now) {
  final overdue = todo.isOverdue(now);
  return [
    (
      label: 'Status',
      value: todo.isDone
          ? (todo.doneAt == null
                ? 'Done'
                : 'Done ${Fmt.date(todo.doneAt)}')
          : overdue
          ? 'Overdue'
          : 'Open',
    ),
    if (todo.dueDate != null)
      (
        label: 'Due',
        value: overdue
            ? '${Fmt.date(todo.dueDate)} — past'
            : Fmt.date(todo.dueDate),
      ),
    // Only where it says something. `normal` is what every item is
    // unless somebody chose otherwise, and a row saying so on all of
    // them is a row nobody reads.
    if (todo.priority != 'normal')
      (label: 'Priority', value: Fmt.label(todo.priority)),
    if (todo.contactId != null)
      (
        label: 'About',
        // A party whose name has not been read yet still gets a row:
        // the fact that this is about somebody is true, and hiding it
        // until a second query lands would make the panel flicker.
        value: todo.contactName ?? 'A contact',
      ),
    if (todo.link != null && todo.link!.isNotEmpty)
      (label: 'Goes to', value: todo.link!),
  ];
}

/// The detail panel: everything about one item, and the ways to act.
///
/// Told its item rather than fetching one, so the wide layout can draw
/// it beside the list from a row it already has, and the narrow one can
/// push it as a page.
class TodoDetail extends ConsumerWidget {
  const TodoDetail({
    super.key,
    required this.todo,
    required this.onEdit,
    required this.onChanged,
  });

  final Todo todo;

  /// Open the editor. The detail READS; changing anything is the
  /// dialog, which is the one place the fields are described.
  final VoidCallback onEdit;

  /// Something was written — refetch the list, and on a phone, leave.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = context.colors;
    final facts = todoFacts(todo, DateTime.now());

    return ListView(
      key: const ValueKey('todo-detail'),
      padding: const EdgeInsets.all(Space.lg),
      children: [
        Text(
          todo.title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            decoration: todo.isDone ? TextDecoration.lineThrough : null,
          ),
        ),
        const SizedBox(height: Space.md),
        for (final fact in facts)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 92,
                  child: Text(
                    fact.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    fact.value,
                    style: TextStyle(
                      color: fact.value.endsWith('past') || fact.value ==
                              'Overdue'
                          ? colors.danger
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // The notes, in full and across as many lines as they take.
        // This is the half the old screen could not show at all: three
        // lines in a dialog box, two ellipsised in the list, and no
        // third place.
        if ((todo.notes ?? '').trim().isNotEmpty) ...[
          const Divider(height: Space.lg),
          Text(
            'Notes',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            todo.notes!,
            key: const ValueKey('todo-notes'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
        const SizedBox(height: Space.lg),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('todo-toggle-done'),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                await repo.setTodoDone(todo.id, !todo.isDone);
                onChanged();
              },
              icon: Icon(
                todo.isDone ? Icons.undo : Icons.check,
                size: 18,
              ),
              label: Text(todo.isDone ? 'Put it back' : 'Mark done'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('todo-edit'),
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
            if (todo.contactId != null)
              OutlinedButton.icon(
                key: const ValueKey('todo-open-contact'),
                onPressed: () => context.go('/contacts/${todo.contactId}'),
                icon: const Icon(Icons.person_outline, size: 18),
                label: Text(todo.contactName ?? 'Open the contact'),
              ),
            if ((todo.link ?? '').isNotEmpty)
              OutlinedButton.icon(
                key: const ValueKey('todo-open-link'),
                onPressed: () => context.go(todo.link!),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open what this is about'),
              ),
            TextButton.icon(
              key: const ValueKey('todo-delete'),
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                await repo.deleteTodo(todo.id);
                onChanged();
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Remove'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The detail as a page of its own, for a window with no room beside
/// the list.
class TodoDetailPage extends StatelessWidget {
  const TodoDetailPage({
    super.key,
    required this.todo,
    required this.onEdit,
    required this.onChanged,
  });

  final Todo todo;
  final VoidCallback onEdit;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('To do')),
    body: TodoDetail(todo: todo, onEdit: onEdit, onChanged: onChanged),
  );
}
