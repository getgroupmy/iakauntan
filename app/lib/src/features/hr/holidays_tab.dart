import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/repository.dart';

/// The public holiday calendar.
///
/// Leave day counts and the rest-day / public-holiday classification in
/// attendance both read this table, and it has always been empty with
/// no way to fill it — so every public holiday has been an ordinary
/// working day, silently, for every organization.
class HolidaysTab extends ConsumerStatefulWidget {
  const HolidaysTab({super.key});

  @override
  ConsumerState<HolidaysTab> createState() => _HolidaysTabState();
}

class _HolidaysTabState extends ConsumerState<HolidaysTab> {
  late int _year = DateTime.now().year;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final holidays = ref.watch(publicHolidaysProvider(_year));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(null),
        icon: const Icon(Icons.add),
        label: const Text('Add holiday'),
      ),
      body: AsyncView(
        value: holidays,
        onRetry: () => ref.invalidate(publicHolidaysProvider(_year)),
        builder: (list) => ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            Padding(
              padding: const EdgeInsets.all(Space.lg),
              child: Row(children: [
                Expanded(
                  child: SectionHeader(
                    'Public holidays',
                    subtitle: list.isEmpty
                        ? 'Nothing for $_year — every day is a working day'
                        : '${list.length} in $_year',
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _year--),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Previous year',
                ),
                Text('$_year',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                IconButton(
                  onPressed: () => setState(() => _year++),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Next year',
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Only four Malaysian holidays fall on a fixed date '
                        'in every state: Labour Day, National Day, Malaysia '
                        'Day and Christmas. Hari Raya, Chinese New Year, '
                        'Deepavali and Wesak are gazetted each year, and the '
                        'state holidays differ by state — those have to be '
                        'entered from the gazette rather than guessed.',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: Space.md),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _addFixed,
                          icon: const Icon(Icons.event_available, size: 18),
                          label: Text('Add the four fixed dates for $_year'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(Space.xxl),
                child: EmptyState(
                  icon: Icons.event_outlined,
                  title: 'No holidays entered',
                  message: 'Until one is here, attendance treats every '
                      'holiday as an ordinary working day.',
                ),
              )
            else
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _HolidayTile(
                  row: list[i],
                  onTap: () => _edit(list[i]),
                  onDelete: () => _delete(list[i]),
                ),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _addFixed() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      // Not runWithFeedback: the count is the message. Pressing this a
      // second time adds nothing, and reporting "added 4" when it added
      // none is a lie somebody plans a roster around.
      final added = await ref.read(repoProvider)!.addFixedHolidays(_year);
      messenger.showSnackBar(SnackBar(
        content: Text(added == 0
            ? 'They were already in the calendar'
            : 'Added $added holiday${added == 1 ? '' : 's'}'),
      ));
      ref.invalidate(publicHolidaysProvider(_year));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('$err')));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _edit(Map<String, dynamic>? row) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _HolidayDialog(row: row, year: _year),
    );
    if (saved == true) ref.invalidate(publicHolidaysProvider(_year));
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final ok = await confirm(
      context,
      title: 'Remove ${row['name']}?',
      message: 'Attendance and leave will treat it as an ordinary working '
          'day again.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .deleteSetupRow('public_holidays', row['id'] as String),
      successMessage: 'Removed',
    );
    ref.invalidate(publicHolidaysProvider(_year));
  }
}

class _HolidayTile extends StatelessWidget {
  const _HolidayTile({
    required this.row,
    required this.onTap,
    required this.onDelete,
  });

  final Map<String, dynamic> row;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final date = Fmt.parseDate(row['holiday_date']);
    final working = row['is_working'] == true;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg, vertical: Space.xs),
      onTap: onTap,
      title: Text(row['name']?.toString() ?? '',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          if (date != null) '${Fmt.date(date)} · ${Fmt.weekday(date)}',
          if (row['state_code'] != null) '${row['state_code']} only',
          if (working) 'worked — replacement day',
        ].join(' · '),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: onDelete,
      ),
    );
  }
}

class _HolidayDialog extends ConsumerStatefulWidget {
  const _HolidayDialog({required this.row, required this.year});

  final Map<String, dynamic>? row;
  final int year;

  @override
  ConsumerState<_HolidayDialog> createState() => _HolidayDialogState();
}

class _HolidayDialogState extends ConsumerState<_HolidayDialog> {
  late final _name =
      TextEditingController(text: widget.row?['name']?.toString() ?? '');
  late DateTime _date = Fmt.parseDate(widget.row?['holiday_date']) ??
      DateTime(widget.year, 1, 1);
  late String? _state = widget.row?['state_code'] as String?;
  late bool _working = widget.row?['is_working'] == true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final states = ref.watch(statesProvider).valueOrNull ?? const [];

    return AlertDialog(
      title: Text(widget.row == null ? 'Add holiday' : 'Edit holiday'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name *',
                hintText: 'Hari Raya Aidilfitri',
              ),
            ),
            const SizedBox(height: Space.md),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(widget.year - 1),
                  lastDate: DateTime(widget.year + 1, 12, 31),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Date',
                  suffixIcon: Icon(Icons.calendar_today, size: 18),
                ),
                child: Text('${Fmt.date(_date)} · ${Fmt.weekday(_date)}'),
              ),
            ),
            const SizedBox(height: Space.md),
            // Most Malaysian holidays are state-specific. Leaving this
            // empty means the whole company observes it.
            DropdownButtonFormField<String?>(
              value: _state,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'State',
                helperText: 'Leave as everywhere unless only one state '
                    'observes it',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Everywhere')),
                for (final s in states)
                  DropdownMenuItem(
                    value: s['code'] as String,
                    child: Text(s['name']?.toString() ?? '',
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _state = v),
            ),
            const SizedBox(height: Space.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _working,
              onChanged: (v) => setState(() => _working = v),
              title: const Text('Worked anyway'),
              subtitle: const Text(
                  'For a gazetted day the company works through'),
            ),
          ],
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
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Give the holiday a name'),
      ));
      return;
    }
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.saveSetupRow(
            'public_holidays',
            {
              'name': _name.text.trim(),
              'holiday_date': Fmt.iso(_date),
              'state_code': _state,
              'is_working': _working,
            },
            id: widget.row?['id'] as String?,
          ),
      successMessage: 'Saved',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.pop(context, true);
  }
}
