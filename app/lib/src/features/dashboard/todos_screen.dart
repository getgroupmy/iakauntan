import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import 'todo_detail.dart';

/// The whole list, and the item somebody is looking at.
///
/// Two tabs and no filters: open, and what has been cleared. A to-do
/// list that needs configuring before it can be read is one people stop
/// opening, and the only question anybody asks of a finished item is
/// "when did I do that", which the second tab answers by itself.
///
/// ## List AND detail
///
/// Tapping an item used to open the edit dialog, which is right for
/// changing something and wrong for reading it. The notes were three
/// lines in a form and two ellipsised lines in the list, so a to-do
/// longer than a sentence could not be read anywhere.
///
/// On a window with room, the item is drawn beside the list. On one
/// without, it is a page — the same widget, pushed, so there is one
/// description of what a to-do looks like rather than two that drift.
/// [detailBeside] is the rule, and it is a function so the number is
/// in one place and can be asserted.
class TodosScreen extends ConsumerStatefulWidget {
  const TodosScreen({super.key});

  @override
  ConsumerState<TodosScreen> createState() => _TodosScreenState();
}

/// Whether this window has room for the detail beside the list.
///
/// 820: a readable list is about 360 and a detail that has to hold a
/// paragraph of notes wants 420, with the navigation rail already
/// taking its share on the left. Below that the two columns are two
/// things neither of which can be read, which is worse than one.
bool detailBeside(double width) => width >= 820;

class _TodosScreenState extends ConsumerState<TodosScreen> {
  /// The item drawn in the panel, by id rather than by value.
  ///
  /// By ID because the list is refetched after every change: holding
  /// the `Todo` would leave the panel showing a stale copy of an item
  /// that was just ticked off, and holding an index would show a
  /// different item once one leaves the list.
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final wide = detailBeside(MediaQuery.sizeOf(context).width);

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
        body: TabBarView(
          children: [
            _TodoPane(
              done: false,
              wide: wide,
              selectedId: _selectedId,
              onSelect: (id) => setState(() => _selectedId = id),
            ),
            _TodoPane(
              done: true,
              wide: wide,
              selectedId: _selectedId,
              onSelect: (id) => setState(() => _selectedId = id),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _edit(BuildContext context, WidgetRef ref, Todo? existing) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => TodoDialog(existing: existing),
  );
  if (saved == true) ref.invalidate(todosProvider);
}

/// One tab: the list, and beside it the item where there is room.
class _TodoPane extends ConsumerWidget {
  const _TodoPane({
    required this.done,
    required this.wide,
    required this.selectedId,
    required this.onSelect,
  });

  final bool done;
  final bool wide;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = _TodoList(
      done: done,
      wide: wide,
      selectedId: selectedId,
      onSelect: onSelect,
    );
    if (!wide) return list;

    final items = ref.watch(todosProvider(done)).valueOrNull ?? const <Todo>[];
    // The selected item may have been ticked off, deleted, or belong to
    // the other tab. `firstOrNull` over a list that changed under it is
    // the whole reason the selection is an id.
    final selected = items.where((t) => t.id == selectedId).firstOrNull;

    return Row(
      children: [
        SizedBox(width: 380, child: list),
        const VerticalDivider(width: 1),
        Expanded(
          child: selected == null
              ? const EmptyState(
                  icon: Icons.checklist_outlined,
                  title: 'Nothing chosen',
                  message: 'Pick something from the list to see all of it.',
                )
              : TodoDetail(
                  todo: selected,
                  onEdit: () => _edit(context, ref, selected),
                  onChanged: () => ref.invalidate(todosProvider),
                ),
        ),
      ],
    );
  }
}

class _TodoList extends ConsumerWidget {
  const _TodoList({
    required this.done,
    required this.wide,
    required this.selectedId,
    required this.onSelect,
  });

  final bool done;
  final bool wide;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final todos = ref.watch(todosProvider(done));

    return AsyncView(
      value: todos,
      onRetry: () => ref.invalidate(todosProvider),
      skeleton: const ListSkeleton(rows: 6),
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
            itemBuilder: (context, i) => _TodoTile(
              todo: items[i],
              done: done,
              wide: wide,
              selected: items[i].id == selectedId,
              onSelect: onSelect,
            ),
          ),
        );
      },
    );
  }
}

class _TodoTile extends ConsumerWidget {
  const _TodoTile({
    required this.todo,
    required this.done,
    required this.wide,
    required this.selected,
    required this.onSelect,
  });

  final Todo todo;
  final bool done;
  final bool wide;
  final bool selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overdue = todo.isOverdue(DateTime.now());
    final colors = context.colors;

    return ListTile(
      selected: wide && selected,
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
              // The panel beside this row may be showing the item that
              // just went. It reads the list by id, so refetching is
              // what empties it -- there is nothing to clear by hand.
              ref.invalidate(todosProvider);
            },
          ),
        ],
      ),
      // Reading, not editing. The dialog is a button away in the
      // detail; opening it on a tap made looking at an item and
      // changing it the same gesture, and a form is the wrong shape
      // for the first of those.
      onTap: () {
        onSelect(todo.id);
        if (!wide) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (pageContext, pageRef, _) {
                  // Read back from the list rather than captured, so
                  // the page redraws after an edit instead of showing
                  // what was true when it opened.
                  final items =
                      pageRef.watch(todosProvider(done)).valueOrNull ??
                      const <Todo>[];
                  final current =
                      items.where((t) => t.id == todo.id).firstOrNull;
                  if (current == null) {
                    // Ticked off, deleted, or moved to the other tab.
                    // Leaving is the honest answer; the alternative is
                    // a page about something that is not there.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (pageContext.mounted) {
                        Navigator.of(pageContext).maybePop();
                      }
                    });
                    return const Scaffold(body: SizedBox.shrink());
                  }
                  return TodoDetailPage(
                    todo: current,
                    onEdit: () => _edit(pageContext, pageRef, current),
                    onChanged: () => pageRef.invalidate(todosProvider),
                  );
                },
              ),
            ),
          );
        }
      },
    );
  }

  Widget? _subtitle(BuildContext context, bool overdue, AppColors colors) {
    final parts = <String>[
      if (todo.isDone && todo.doneAt != null)
        'Done ${Fmt.date(todo.doneAt)}'
      else if (todo.dueDate != null)
        overdue ? 'Overdue — ${Fmt.date(todo.dueDate)}' : Fmt.date(todo.dueDate),
      // `0656`. Who it is about, where it is about somebody. Before the
      // notes, because it is the shorter and the more identifying of
      // the two.
      if ((todo.contactName ?? '').isNotEmpty) todo.contactName!,
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

/// Add something to the list, or change it.
///
/// Public so the dashboard card can open the same dialog rather than
/// describing the fields a second time.
class TodoDialog extends ConsumerStatefulWidget {
  const TodoDialog({super.key, this.existing});

  final Todo? existing;

  @override
  ConsumerState<TodoDialog> createState() => _TodoDialogState();
}

class _TodoDialogState extends ConsumerState<TodoDialog> {
  late final TextEditingController _title;
  late final TextEditingController _notes;
  DateTime? _due;
  String _priority = 'normal';
  String? _contactId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _notes = TextEditingController(text: widget.existing?.notes ?? '');
    _due = widget.existing?.dueDate;
    _priority = widget.existing?.priority ?? 'normal';
    _contactId = widget.existing?.contactId;
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every contact, not only customers: "pay the landlord" and "chase
    // Ramli" are the same kind of note about two different sides of the
    // ledger, and a picker that offered one would send somebody to
    // retype the other as a name in the notes.
    final contacts =
        ref.watch(contactsProvider((type: 'all', search: ''))).valueOrNull ??
        const <Contact>[];

    return AlertDialog(
      title: Text(widget.existing == null ? 'Add to the list' : 'Edit'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
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
              // `0656`. Room to write. Three lines was a box that
              // looked like a single-line field with a scrollbar, and
              // a to-do people could not write a paragraph in is one
              // they write the paragraph somewhere else instead.
              TextField(
                key: const ValueKey('todo-notes-field'),
                controller: _notes,
                minLines: 4,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  alignLabelWithHint: true,
                  hintText: 'As many lines as you need.',
                ),
              ),
              const SizedBox(height: 12),
              // `0656`. Who it is about. A picker over a list that
              // grows, with the search the chart and the contacts list
              // already use -- a company with four hundred contacts
              // cannot scroll to one.
              SearchablePicker<String>(
                key: const ValueKey('todo-contact'),
                label: 'About a contact',
                hint: 'Optional — type a name or a code',
                options: [
                  for (final c in contacts)
                    PickerOption(
                      value: c.id,
                      label: c.name,
                      sublabel: c.code,
                      keywords: [c.code, c.name],
                    ),
                ],
                value: _contactId,
                onChanged: (v) => setState(() => _contactId = v),
              ),
              if (_contactId != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('todo-contact-clear'),
                    onPressed: () => setState(() => _contactId = null),
                    icon: const Icon(Icons.clear, size: 16),
                    label: const Text('Not about anybody'),
                  ),
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
          contactId: _contactId,
        );
      } else {
        await repo.updateTodo(
          widget.existing!.id,
          title: _title.text,
          notes: _notes.text,
          dueDate: _due,
          clearDueDate: _due == null,
          priority: _priority,
          contactId: _contactId,
          // Absent and "take it off" are the same value, so the second
          // has to be said separately -- the split `clearDueDate`
          // already makes for the date.
          clearContact: _contactId == null,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
