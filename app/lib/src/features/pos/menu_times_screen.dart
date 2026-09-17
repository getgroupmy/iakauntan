import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// When each part of the menu is offered.
///
/// A kitchen that serves nasi lemak until eleven and burgers after it
/// has one menu in its head and one on the till, and the till's does
/// not know what time it is. The cashier remembers, until the Saturday
/// somebody else is on the counter.
///
/// ## A schedule is a thing, not times on an item
///
/// Times typed onto each dish would mean entering 07:00–11:00 forty
/// times and getting it wrong once. A schedule is named and dishes hang
/// off it, so moving breakfast to half past eleven moves forty dishes
/// together.
///
/// ## Empty means always
///
/// A dish on no schedule is always on, and a schedule with no weekdays
/// runs every day. The same rule the promotions use, and the reason a
/// shop that does not want any of this never has to think about it.
class MenuTimesScreen extends ConsumerWidget {
  const MenuTimesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!moduleEnabled(ref, 'pos')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Menu times')),
        body: const EmptyState(
          icon: Icons.schedule_outlined,
          title: 'The till is not switched on',
          message: 'A menu time is when a till offers a dish, and this '
              'company has no till.',
        ),
      );
    }

    final schedules = ref.watch(posMenuSchedulesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Menu times')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('New schedule'),
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: schedules,
        onRetry: () => ref.invalidate(posMenuSchedulesProvider),
        skeleton: const ListSkeleton(rows: 6),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.schedule_outlined,
              title: 'Everything is on all day',
              message: 'Add a schedule to serve breakfast until eleven, or '
                  'to put a weekend special on only at the weekend. Dishes '
                  'on no schedule stay on all day.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [for (final s in rows) _ScheduleTile(schedule: s)],
          );
        },
      ),
    );
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  Map<String, dynamic>? schedule,
) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => _ScheduleDialog(schedule: schedule),
  );
  if (saved == true) ref.invalidate(posMenuSchedulesProvider);
}

/// When a schedule runs, in one line, or null when the answer is
/// "always".
///
/// Exported for the test: this is the sentence a shopkeeper checks
/// their own breakfast against, and a wrong one means finding out at
/// eleven o'clock.
String? scheduleWhen(Map<String, dynamic> s) {
  final bits = <String>[];
  final days = (s['weekdays'] as List?)?.map(Fmt.toInt).toList();
  if (days != null && days.isNotEmpty && days.length < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    bits.add([for (final d in days) names[(d - 1) % 7]].join(' '));
  }
  final from = '${s['starts_at'] ?? ''}';
  final to = '${s['ends_at'] ?? ''}';
  if (from.isNotEmpty && to.isNotEmpty) {
    bits.add('${_hhmm(from)}–${_hhmm(to)}');
  }
  return bits.isEmpty ? null : bits.join(' · ');
}

/// Postgres hands a `time` back as HH:MM:SS. Nobody writes a breakfast
/// menu to the second.
String _hhmm(String t) => t.length >= 5 ? t.substring(0, 5) : t;

class _ScheduleTile extends ConsumerWidget {
  const _ScheduleTile({required this.schedule});

  final Map<String, dynamic> schedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = schedule['is_active'] == true;
    final open = schedule['open_now'] == true;
    final dishes = Fmt.toInt(schedule['dishes']);
    final when = scheduleWhen(schedule);

    return ListTile(
      onTap: () => _edit(context, ref, schedule),
      leading: Icon(
        Icons.schedule_outlined,
        size: 20,
        color: live ? null : Theme.of(context).disabledColor,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              '${schedule['name']}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w500,
                color: live ? null : Theme.of(context).disabledColor,
              ),
            ),
          ),
          // The question somebody opens this screen to answer, said on
          // the row rather than worked out from two times and a clock.
          if (live && open) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: context.colors.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'on now',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.colors.success,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (!live) 'retired',
          when ?? 'all day, every day',
          // A schedule governing nothing is the mistake worth seeing:
          // it was saved without its dishes and quietly does nothing.
          '$dishes dish${dishes == 1 ? '' : 'es'}',
        ].join(' · '),
        style: TextStyle(
          fontSize: 12,
          color: live && dishes == 0 ? context.colors.warning : null,
        ),
      ),
      trailing: live
          ? IconButton(
              tooltip: 'Retire',
              icon: const Icon(Icons.block_outlined, size: 18),
              onPressed: () async {
                final repo = ref.read(repoProvider);
                if (repo == null) return;
                final ok = await runWithFeedback(
                  context,
                  // Said plainly, because retiring a schedule puts its
                  // dishes back on all day rather than taking them off.
                  successMessage: 'Retired — those dishes are on all day now',
                  action: () =>
                      repo.retirePosMenuSchedule(schedule['id'] as String),
                );
                if (ok) ref.invalidate(posMenuSchedulesProvider);
              },
            )
          : null,
    );
  }
}

class _ScheduleDialog extends ConsumerStatefulWidget {
  const _ScheduleDialog({this.schedule});

  final Map<String, dynamic>? schedule;

  @override
  ConsumerState<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends ConsumerState<_ScheduleDialog> {
  late final _name = TextEditingController(
    text: '${widget.schedule?['name'] ?? ''}',
  );
  late TimeOfDay? _from = _parseTime(widget.schedule?['starts_at']);
  late TimeOfDay? _to = _parseTime(widget.schedule?['ends_at']);
  late final Set<int> _days = {
    ...?(widget.schedule?['weekdays'] as List?)?.map(Fmt.toInt),
  };
  late final Set<String> _items = {
    ...?(widget.schedule?['item_ids'] as List?)?.map((v) => '$v'),
  };
  bool _saving = false;

  static TimeOfDay? _parseTime(Object? v) {
    final s = '${v ?? ''}';
    if (s.length < 5) return null;
    return TimeOfDay(
      hour: int.tryParse(s.substring(0, 2)) ?? 0,
      minute: int.tryParse(s.substring(3, 5)) ?? 0,
    );
  }

  static String _wire(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:00';

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A schedule needs a name.')),
      );
      return;
    }
    if ((_from == null) != (_to == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('An hours window needs both a start and an end.'),
        ),
      );
      return;
    }

    setState(() => _saving = true);
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Saved',
      action: () => repo.savePosMenuSchedule(
        id: widget.schedule?['id'] as String?,
        name: _name.text.trim(),
        weekdays: _days.isEmpty ? null : (_days.toList()..sort()),
        startsAt: _from == null ? null : _wire(_from!),
        endsAt: _to == null ? null : _wire(_to!),
        items: _items.toList(),
        // Editing a retired schedule brings it back, the rule
        // everywhere else in this module.
        isActive: true,
      ),
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    // Every item, unfiltered: the schedule is about the whole menu
    // and a search box here would hide the dish somebody came to tick.
    final items = ref.watch(itemsProvider('')).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(
        widget.schedule == null ? 'New schedule' : 'Edit schedule',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  hintText: 'Breakfast',
                ),
              ),
              const SizedBox(height: Space.md),
              Text(
                'Leave the days and hours alone and it runs all the time.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.sm),
              Wrap(
                spacing: 4,
                children: [
                  for (var d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(dayNames[d - 1]),
                      selected: _days.contains(d),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _days.add(d);
                        } else {
                          _days.remove(d);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final t = await showTimePicker(
                          context: context,
                          initialTime:
                              _from ?? const TimeOfDay(hour: 7, minute: 0),
                        );
                        if (t != null) setState(() => _from = t);
                      },
                      child: Text(
                        _from == null ? 'From' : _from!.format(context),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        final t = await showTimePicker(
                          context: context,
                          initialTime:
                              _to ?? const TimeOfDay(hour: 11, minute: 0),
                        );
                        if (t != null) setState(() => _to = t);
                      },
                      child: Text(_to == null ? 'To' : _to!.format(context)),
                    ),
                  ),
                  if (_from != null || _to != null)
                    IconButton(
                      tooltip: 'All day',
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() {
                        _from = null;
                        _to = null;
                      }),
                    ),
                ],
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Which dishes',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Text(
                    '${_items.length} chosen',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: Space.xs),
              // Said, because a schedule saved with no dishes governs
              // nothing and looks like it is working.
              if (_items.isEmpty)
                Text(
                  'A schedule with no dishes on it does nothing.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.colors.warning,
                  ),
                ),
              const SizedBox(height: Space.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final i in items)
                      CheckboxListTile(
                        dense: true,
                        value: _items.contains(i.id),
                        title: Text(i.name),
                        subtitle: Text(Fmt.money(i.unitPrice)),
                        onChanged: (on) => setState(() {
                          if (on == true) {
                            _items.add(i.id);
                          } else {
                            _items.remove(i.id);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
