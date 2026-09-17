import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';

/// The whole list, rather than the top of it.
///
/// Two tabs and no filters: open, and what has been cleared. A to-do
/// list that needs configuring before it can be read is one people stop
/// opening, and the only question anybody asks of a finished item is
/// "when did I do that", which the second tab answers by itself.
class TodosScreen extends ConsumerWidget {
  const TodosScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('To do'),
          bottom: const TabBar(
            tabs: [Tab(text: 'Open'), Tab(text: 'Done')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(context, ref, null),
          icon: const Icon(Icons.add),
          label: const Text('Add'),
        ),
        body: const TabBarView(
          children: [_TodoList(done: false), _TodoList(done: true)],
        ),
      ),
    );
  }
}

Future<void> _edit(BuildContext context, WidgetRef ref, Todo? existing) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _TodoDialog(existing: existing),
  );
  if (saved == true) ref.invalidate(todosProvider);
}

class _TodoList extends ConsumerWidget {
  const _TodoList({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todosProvider(done));

    return AsyncView(
      value: todos,
      onRetry: () => ref.invalidate(todosProvider),
      builder: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: done ? Icons.done_all : Icons.checklist_outlined,
            title: done ? 'Nothing cleared yet' : 'Nothing on your list',
            message: done
                ? 'What you tick off shows up here, with the day you did it.'
                : 'Chase an invoice, file a return, ring a client back. '
                      'Add the things that have no other row.',
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(todosProvider);
            await ref.read(todosProvider(done).future);
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(Space.lg),
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) =>
                _TodoTile(todo: items[i], done: done),
          ),
        );
      },
    );
  }
}

class _TodoTile extends ConsumerWidget {
  const _TodoTile({required this.todo, required this.done});

  final Todo todo;
  final bool done;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overdue = todo.isOverdue(DateTime.now());
    final colors = context.colors;

    return ListTile(
      leading: Checkbox(
        value: todo.isDone,
        onChanged: (v) async {
          final repo = ref.read(repoProvider);
          if (repo == null) return;
          await repo.setTodoDone(todo.id, v ?? false);
          ref.invalidate(todosProvider);
        },
      ),
      title: Text(
        todo.title,
        style: todo.isDone
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: _subtitle(context, overdue, colors),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (todo.priority == 'high' && !todo.isDone)
            Icon(Icons.flag, size: 18, color: colors.danger),
          if (todo.link != null)
            IconButton(
              tooltip: 'Open what this is about',
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: () => context.go(todo.link!),
            ),
          IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () async {
              final repo = ref.read(repoProvider);
              if (repo == null) return;
              await repo.deleteTodo(todo.id);
              ref.invalidate(todosProvider);
            },
          ),
        ],
      ),
      onTap: () => _edit(context, ref, todo),
    );
  }

  Widget? _subtitle(BuildContext context, bool overdue, AppColors colors) {
    final parts = <String>[
      if (todo.isDone && todo.doneAt != null)
        'Done ${Fmt.date(todo.doneAt)}'
      else if (todo.dueDate != null)
        overdue ? 'Overdue — ${Fmt.date(todo.dueDate)}' : Fmt.date(todo.dueDate),
      if (todo.notes != null && todo.notes!.isNotEmpty) todo.notes!,
    ];
    if (parts.isEmpty) return null;
    return Text(
      parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: overdue ? TextStyle(color: colors.danger) : null,
    );
  }
}

class _TodoDialog extends ConsumerStatefulWidget {
  const _TodoDialog({this.existing});

  final Todo? existing;

  @override
  ConsumerState<_TodoDialog> createState() => _TodoDialogState();
}

class _TodoDialogState extends ConsumerState<_TodoDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  DateTime? _due;
  String _priority = 'normal';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
    _due = widget.existing?.dueDate;
    _priority = widget.existing?.priority ?? 'normal';
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add to the list' : 'Edit'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'What needs doing',
                hintText: 'Chase the Ramli invoice',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(_due == null ? 'No date' : Fmt.date(_due)),
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _due ?? now,
                        firstDate: DateTime(now.year - 1),
                        lastDate: DateTime(now.year + 5),
                      );
                      if (picked != null) setState(() => _due = picked);
                    },
                  ),
                ),
                if (_due != null)
                  IconButton(
                    tooltip: 'No date',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => setState(() => _due = null),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'low', label: Text('Low')),
                ButtonSegment(value: 'normal', label: Text('Normal')),
                ButtonSegment(value: 'high', label: Text('High')),
              ],
              selected: {_priority},
              onSelectionChanged: (s) => setState(() => _priority = s.first),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    // An item with no words on it is refused by the database anyway;
    // catching it here means somebody is told rather than shown an
    // error from a constraint they cannot see.
    if (_title.text.trim().isEmpty) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;

    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        await repo.addTodo(
          title: _title.text,
          notes: _notes.text,
          dueDate: _due,
          priority: _priority,
        );
      } else {
        await repo.updateTodo(
          widget.existing!.id,
          title: _title.text,
          notes: _notes.text,
          dueDate: _due,
          clearDueDate: _due == null,
          priority: _priority,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
