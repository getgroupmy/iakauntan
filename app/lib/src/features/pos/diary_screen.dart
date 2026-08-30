import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/widgets.dart';
// `RepoPos` is an extension, and a Dart extension is only in scope
// where its declaring library is imported.
import '../../data/repository.dart';
import 'provider_roster_screen.dart';
import 'till_screen.dart' show PosRegisterPicker, posNum;

/// The diary.
///
/// A day, one column per provider, because the thing a salon asks all
/// morning is "who is free at three" and that question is about people
/// rather than about time. A single merged list sorted by hour would
/// answer a different question nobody asks.
///
/// ## Every provider, booked or not
///
/// `pos_day_sheet` left-joins the bookings, so somebody with an empty
/// day still has a column. That is the whole point: an empty column is
/// the answer to "who is free", and a diary that hid it would only
/// show the people who cannot help.
///
/// ## Arrival is not a status somebody types
///
/// Checking in calls `check_in_booking`, which opens a sale with the
/// service on it at the price that was quoted. So the button says
/// "Check in" and what it does is start charging — the two are the
/// same act, and a screen that let you mark somebody arrived without
/// opening their bill would be a screen that loses the money.
class DiaryScreen extends ConsumerStatefulWidget {
  const DiaryScreen({super.key});

  @override
  ConsumerState<DiaryScreen> createState() => _DiaryScreenState();
}

class _DiaryScreenState extends ConsumerState<DiaryScreen> {
  String? _registerId;
  String? _outletId;
  late DateTime _day = _today();

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
    });
  }

  void _shift(int days) {
    setState(() => _day = _day.add(Duration(days: days)));
  }

  void _refresh() {
    final outlet = _outletId;
    if (outlet != null) {
      ref.invalidate(posDaySheetProvider((outletId: outlet, day: _day)));
    }
  }

  Future<void> _checkIn(Map<String, dynamic> b) async {
    final reg = _registerId;
    final id = b['booking_id'] as String?;
    if (reg == null || id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: 'Checked in — the bill is open on the till',
      action: () => repo.checkInBooking(id, reg),
    );
    if (ok && mounted) _refresh();
  }

  Future<void> _setStatus(Map<String, dynamic> b, String status) async {
    final id = b['booking_id'] as String?;
    if (id == null) return;
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final ok = await runWithFeedback(
      context,
      successMessage: null,
      action: () => repo.setBookingStatus(id, status),
    );
    if (ok && mounted) _refresh();
  }

  /// Selling a slot.
  ///
  /// The form asks for the three things a booking cannot be made
  /// without — who, what and when — and nothing else. Everything the
  /// slot costs, how long it runs and what it is worth, is on the
  /// service already; asking again would be inviting the two to
  /// disagree.
  Future<void> _book(String providerId, String providerName) async {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    final services = await ref.read(posServicesProvider.future);
    if (!mounted) return;
    if (services.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nothing is set up to be booked yet. An item becomes '
            'bookable when it is given a duration.',
          ),
        ),
      );
      return;
    }
    final picked = await showDialog<({String itemId, TimeOfDay at})>(
      context: context,
      builder: (ctx) =>
          _BookingDialog(provider: providerName, services: services),
    );
    if (picked == null || !mounted) return;
    final startsAt = DateTime(
      _day.year,
      _day.month,
      _day.day,
      picked.at.hour,
      picked.at.minute,
    );
    final ok = await runWithFeedback(
      context,
      successMessage: 'Booked',
      action: () => repo.bookAppointment(
        providerId: providerId,
        itemId: picked.itemId,
        startsAt: startsAt,
      ),
    );
    if (ok && mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Diary'),
        actions: [
          // A diary is a list of people before it is a list of hours,
          // and until somebody's week is written down every booking
          // made for them is refused by name.
          if (_outletId != null)
            IconButton(
              key: const ValueKey('diary-roster'),
              icon: const Icon(Icons.people_alt_outlined),
              tooltip: 'Who does the work',
              onPressed: () => showProviderRoster(context, _outletId!),
            ),
          registers.maybeWhen(
            data: (rows) => PosRegisterPicker(
              registers: rows,
              selectedId: _registerId,
              onPicked: _pickRegister,
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: registers,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.event_note_outlined,
              title: 'No tills yet',
              message:
                  'A diary belongs to an outlet, and checking somebody in '
                  'opens a sale on a register.',
            );
          }
          if (_registerId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickRegister(rows.first);
            });
          }
          final outlet = _outletId;
          if (outlet == null) return const SizedBox.shrink();
          return Column(
            children: [
              _DayBar(
                day: _day,
                onShift: _shift,
                onToday: () => setState(() => _day = _today()),
              ),
              Expanded(
                child: _Day(
                  outletId: outlet,
                  day: _day,
                  onCheckIn: _checkIn,
                  onStatus: _setStatus,
                  onBook: _book,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DayBar extends StatelessWidget {
  const _DayBar({
    required this.day,
    required this.onShift,
    required this.onToday,
  });

  final DateTime day;
  final ValueChanged<int> onShift;
  final VoidCallback onToday;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final isToday = day.year == today.year &&
        day.month == today.month &&
        day.day == today.day;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onShift(-1),
            tooltip: 'The day before',
          ),
          Expanded(
            child: Center(
              child: Text(
                Fmt.date(day),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => onShift(1),
            tooltip: 'The day after',
          ),
          // Only offered when it would do something. A "Today" button on
          // today is a control that cannot change anything.
          if (!isToday)
            TextButton(onPressed: onToday, child: const Text('Today')),
        ],
      ),
    );
  }
}

class _Day extends ConsumerWidget {
  const _Day({
    required this.outletId,
    required this.day,
    required this.onCheckIn,
    required this.onStatus,
    required this.onBook,
  });

  final String outletId;
  final DateTime day;
  final ValueChanged<Map<String, dynamic>> onCheckIn;
  final void Function(Map<String, dynamic>, String) onStatus;
  final void Function(String, String) onBook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sheet = ref.watch(
      posDaySheetProvider((outletId: outletId, day: day)),
    );
    return AsyncView<List<Map<String, dynamic>>>(
      value: sheet,
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.event_note_outlined,
            title: 'Nobody to book',
            message:
                'Add a service provider to this outlet — a chair, a room '
                'or a person — and the diary opens.',
          );
        }
        // Grouped by provider, keeping the order the query returned.
        // A provider with a free day still gets a column: that is the
        // answer to "who can take somebody at three".
        final byProvider = <String, List<Map<String, dynamic>>>{};
        final names = <String, String>{};
        for (final r in rows) {
          final id = r['provider_id'] as String;
          names[id] = '${r['provider']}';
          byProvider.putIfAbsent(id, () => []);
          if (r['booking_id'] != null) byProvider[id]!.add(r);
        }
        return LayoutBuilder(
          builder: (context, box) {
            final columns = (box.maxWidth / 280).floor().clamp(1, 5);
            final ids = byProvider.keys.toList();
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: ids.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: 0.7,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemBuilder: (_, i) => _Column(
                name: names[ids[i]] ?? '',
                bookings: byProvider[ids[i]]!,
                onCheckIn: onCheckIn,
                onStatus: onStatus,
                onBook: () => onBook(ids[i], names[ids[i]] ?? ''),
              ),
            );
          },
        );
      },
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({
    required this.name,
    required this.bookings,
    required this.onCheckIn,
    required this.onStatus,
    required this.onBook,
  });

  final String name;
  final List<Map<String, dynamic>> bookings;
  final ValueChanged<Map<String, dynamic>> onCheckIn;
  final void Function(Map<String, dynamic>, String) onStatus;
  final VoidCallback onBook;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Book $name',
                  icon: const Icon(Icons.add),
                  onPressed: onBook,
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: bookings.isEmpty
                  // Said in words rather than left blank. A column with
                  // nothing in it reads as "not loaded" unless it says
                  // otherwise, and "free all day" is the good answer.
                  ? Center(
                      child: Text(
                        'Free all day',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    )
                  : ListView(
                      children: [
                        for (final b in bookings)
                          _Slot(
                            booking: b,
                            onCheckIn: () => onCheckIn(b),
                            onStatus: (s) => onStatus(b, s),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({
    required this.booking,
    required this.onCheckIn,
    required this.onStatus,
  });

  final Map<String, dynamic> booking;
  final VoidCallback onCheckIn;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    final status = '${booking['status']}';
    final starts = DateTime.tryParse('${booking['starts_at']}')?.toLocal();
    final minutes = (booking['minutes'] as num?)?.toInt() ?? 0;
    // A slot that was called off or never turned up is struck through
    // rather than removed: the hour is free again, but somebody
    // looking at the day needs to see that it was sold once.
    final gone = status == 'cancelled' || status == 'no_show';

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${starts == null ? '' : Fmt.time(starts)} · '
        '${booking['description'] ?? ''}',
        style: gone
            ? Theme.of(context).textTheme.bodyMedium?.copyWith(
                decoration: TextDecoration.lineThrough,
              )
            : null,
      ),
      subtitle: Text(
        '${booking['customer']} · ${minutes}m · '
        '${Fmt.money(posNum(booking['price']))}',
      ),
      trailing: _SlotAction(
        status: status,
        onCheckIn: onCheckIn,
        onStatus: onStatus,
      ),
    );
  }
}

class _SlotAction extends StatelessWidget {
  const _SlotAction({
    required this.status,
    required this.onCheckIn,
    required this.onStatus,
  });

  final String status;
  final VoidCallback onCheckIn;
  final ValueChanged<String> onStatus;

  @override
  Widget build(BuildContext context) {
    // Before they arrive there is one thing to do and two things that
    // can go wrong; afterwards the money has moved and the diary is
    // no longer where it is handled.
    if (status == 'booked' || status == 'confirmed') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(onPressed: onCheckIn, child: const Text('Check in')),
          PopupMenuButton<String>(
            tooltip: 'They are not coming',
            icon: const Icon(Icons.more_vert, size: 18),
            onSelected: onStatus,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'no_show', child: Text('Did not turn up')),
              PopupMenuItem(value: 'cancelled', child: Text('Cancel')),
            ],
          ),
        ],
      );
    }
    return Text(
      switch (status) {
        'arrived' => 'In',
        'completed' => 'Done',
        'no_show' => 'No show',
        'cancelled' => 'Cancelled',
        _ => status,
      },
      style: Theme.of(context).textTheme.labelMedium,
    );
  }
}

/// What is being sold, and at what time.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({required this.provider, required this.services});

  final String provider;
  final List<Map<String, dynamic>> services;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  String? _itemId;
  TimeOfDay _at = const TimeOfDay(hour: 10, minute: 0);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Book ${widget.provider}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            value: _itemId,
            decoration: const InputDecoration(labelText: 'What'),
            items: [
              for (final s in widget.services)
                DropdownMenuItem(
                  value: (s['items'] as Map?)?['id'] as String?,
                  child: Text(
                    '${(s['items'] as Map?)?['name'] ?? ''} · '
                    '${s['duration_minutes']}m',
                  ),
                ),
            ],
            onChanged: (v) => setState(() => _itemId = v),
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('When'),
            trailing: Text(_at.format(context)),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: _at,
              );
              if (picked != null) setState(() => _at = picked);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Nothing to book until something is chosen. The database
          // would refuse a null item; refusing it here saves a round
          // trip and an error message about a column.
          onPressed: _itemId == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop((itemId: _itemId!, at: _at)),
          child: const Text('Book'),
        ),
      ],
    );
  }
}
