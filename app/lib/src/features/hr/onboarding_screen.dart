import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/picker_options.dart';
import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// Somebody's first fortnight, and somebody else's last.
///
/// Four tables — templates, template items, checklists and tasks — were
/// a complete design that nothing could create a row in. The template
/// holds offsets ("IT account, day 0"; "EPF registration, day 3") and
/// starting a checklist turns them into dates against a hire date.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  bool _openOnly = true;

  @override
  Widget build(BuildContext context) {
    final checklists = ref.watch(onboardingChecklistsProvider(_openOnly));
    final canManage = ref.watch(canManageHrProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Onboarding'),
        actions: [
          if (canManage)
            Padding(
              padding: const EdgeInsets.only(right: Space.md),
              child: FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('Start a checklist'),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: FilterBar(
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('In progress')),
                ButtonSegment(value: false, label: Text('All')),
              ],
              selected: {_openOnly},
              onSelectionChanged: (s) => setState(() => _openOnly = s.first),
            ),
          ),
        ),
      ),
      body: AsyncView(
        value: checklists,
        onRetry: () => ref.invalidate(onboardingChecklistsProvider(_openOnly)),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.checklist_rtl_outlined,
                title: 'Nothing in progress',
                message: 'Build a template under HR setup, then start a '
                    'checklist against whoever is joining.',
              )
            : ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _ChecklistTile(
                  checklist: list[i],
                  onOpen: () => _open(list[i]),
                ),
              ),
      ),
    );
  }

  Future<void> _start() async {
    final started = await showDialog<bool>(
      context: context,
      builder: (_) => const _StartDialog(),
    );
    if (started == true) {
      ref.invalidate(onboardingChecklistsProvider(_openOnly));
    }
  }

  Future<void> _open(Map<String, dynamic> checklist) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TasksDialog(checklist: checklist),
    );
    ref.invalidate(onboardingChecklistsProvider(_openOnly));
  }
}

class _ChecklistTile extends StatelessWidget {
  const _ChecklistTile({required this.checklist, required this.onOpen});

  final Map<String, dynamic> checklist;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final employee = checklist['employees'];
    final tasks = (checklist['onboarding_tasks'] as List?)
            ?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final done = tasks.where((t) => t['is_done'] == true).length;
    final completed = checklist['completed_at'] != null;
    final start = Fmt.parseDate(checklist['start_date']);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.sm),
      onTap: onOpen,
      title: Row(children: [
        Flexible(
          child: Text(
            employee is Map ? employee['full_name']?.toString() ?? '—' : '—',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: Space.sm),
        StatusChip(checklist['kind']?.toString() ?? 'onboarding', compact: true),
        if (completed) ...[
          const SizedBox(width: Space.xs),
          const StatusChip('completed', compact: true),
        ],
      ]),
      subtitle: Text(
        [
          if (employee is Map && employee['employee_no'] != null)
            employee['employee_no'].toString(),
          if (start != null) 'from ${Fmt.date(start)}',
          '$done of ${tasks.length} done',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: SizedBox(
        width: 90,
        child: LinearProgressIndicator(
          value: tasks.isEmpty ? 0 : done / tasks.length,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

class _StartDialog extends ConsumerStatefulWidget {
  const _StartDialog();

  @override
  ConsumerState<_StartDialog> createState() => _StartDialogState();
}

class _StartDialogState extends ConsumerState<_StartDialog> {
  String? _employeeId;
  String? _templateId;
  String _kind = 'onboarding';
  DateTime? _start;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final employees = ref.watch(employeesProvider('active')).valueOrNull ?? const [];
    final templates = ref
            .watch(setupRowsProvider(
                (table: 'onboarding_templates', orderBy: 'name')))
            .valueOrNull ??
        const [];

    return AlertDialog(
      title: const Text('Start a checklist'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SearchablePicker<String>(
                options: employeePickerOptions(employees),
                value: _employeeId,
                label: 'Who *',
                hint: 'Type a name or a staff number',
                onChanged: (v) => setState(() => _employeeId = v),
              ),
              const SizedBox(height: Space.md),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'onboarding', label: Text('Joining')),
                  ButtonSegment(value: 'offboarding', label: Text('Leaving')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              const SizedBox(height: Space.md),
              SearchablePicker<String>(
                options: [
                  for (final t in templates)
                    PickerOption<String>(
                      value: t['id'] as String,
                      label: t['name']?.toString() ?? '',
                    ),
                ],
                value: _templateId,
                label: 'Template',
                helperText: 'Without one the checklist starts empty',
                allowEmpty: true,
                onChanged: (v) => setState(() => _templateId = v),
              ),
              const SizedBox(height: Space.md),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _start ?? DateTime.now(),
                    firstDate: DateTime(DateTime.now().year - 1),
                    lastDate: DateTime(DateTime.now().year + 2),
                    helpText: 'Day the offsets count from',
                  );
                  if (picked != null) setState(() => _start = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Start date',
                    // Left empty, the database uses the hire date for a
                    // joiner and today for a leaver, which is what
                    // somebody means nine times out of ten.
                    helperText: 'Defaults to the hire date',
                    suffixIcon: Icon(Icons.calendar_today, size: 18),
                  ),
                  child: Text(_start == null ? 'Hire date' : Fmt.date(_start)),
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
          onPressed: _saving || _employeeId == null ? null : _start_,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Start'),
        ),
      ],
    );
  }

  Future<void> _start_() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.startOnboarding(
            employeeId: _employeeId!,
            templateId: _templateId,
            startDate: _start,
            kind: _kind,
          ),
      successMessage: 'Checklist started',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}

class _TasksDialog extends ConsumerWidget {
  const _TasksDialog({required this.checklist});

  final Map<String, dynamic> checklist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = checklist['id'] as String;
    final tasks = ref.watch(onboardingTasksProvider(id));
    final employee = checklist['employees'];

    return AlertDialog(
      title: Text(employee is Map
          ? '${employee['full_name']} · ${Fmt.label(checklist['kind']?.toString() ?? '')}'
          : 'Checklist'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: AsyncView(
            value: tasks,
            onRetry: () => ref.invalidate(onboardingTasksProvider(id)),
            builder: (list) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: Space.lg),
                    child: Text('This checklist has no tasks. It was started '
                        'without a template.'),
                  )
                else
                  for (final t in list)
                    _TaskRow(
                      task: t,
                      onToggle: (done) => _toggle(context, ref, id, t, done),
                    ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _toggle(BuildContext context, WidgetRef ref, String checklistId,
      Map<String, dynamic> task, bool done) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      // The return value is the whole point: the person ticking the last
      // mandatory box is the one who wants to know it was the last one.
      final finished = await ref
          .read(repoProvider)!
          .setOnboardingTaskDone(task['id'] as String, done);
      if (finished) {
        messenger.showSnackBar(const SnackBar(
          content: Text('That was the last one — the checklist is complete'),
        ));
      }
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
    ref.invalidate(onboardingTasksProvider(checklistId));
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.onToggle});

  final Map<String, dynamic> task;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final due = Fmt.parseDate(task['due_date']);
    final done = task['is_done'] == true;
    final owner = task['employees'];
    // Overdue only matters while it is still outstanding.
    final overdue = !done &&
        due != null &&
        due.isBefore(DateTime.now().subtract(const Duration(days: 1)));

    return CheckboxListTile(
      value: done,
      onChanged: (v) => onToggle(v ?? false),
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        task['title']?.toString() ?? '',
        style: TextStyle(
          decoration: done ? TextDecoration.lineThrough : null,
          fontWeight: task['is_mandatory'] == true
              ? FontWeight.w600
              : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        [
          if (task['category'] != null) task['category'].toString(),
          if (due != null) 'due ${Fmt.date(due)}',
          if (owner is Map) owner['full_name'].toString(),
          if (task['is_mandatory'] != true) 'optional',
        ].join(' · '),
        style: TextStyle(
          fontSize: 12,
          color: overdue ? context.colors.danger : null,
          fontWeight: overdue ? FontWeight.w600 : null,
        ),
      ),
    );
  }
}
