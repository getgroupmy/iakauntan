import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// One ticket: what was asked, what was said, and what may happen next.
///
/// The status buttons are the database's own state machine, mirrored.
/// `app.ticket_transition_allowed` decides what is legal; this table has
/// to agree with it, and where it does not the server refuses and says
/// what was allowed instead — so the failure is a message rather than a
/// wrong record. Kept next to the enum it mirrors so the two are read
/// together when either changes.
const Map<String, List<String>> kTicketTransitions = {
  'new': ['open', 'pending', 'on_hold', 'resolved', 'cancelled'],
  'open': ['pending', 'on_hold', 'resolved', 'cancelled'],
  'pending': ['open', 'on_hold', 'resolved', 'cancelled'],
  'on_hold': ['open', 'pending', 'resolved', 'cancelled'],
  'resolved': ['closed', 'open'],
  'closed': ['open'],
  'cancelled': <String>[],
};

class TicketScreen extends ConsumerStatefulWidget {
  const TicketScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<TicketScreen> createState() => _TicketScreenState();
}

class _TicketScreenState extends ConsumerState<TicketScreen> {
  final _reply = TextEditingController();
  bool _internal = true;
  bool _busy = false;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  void _refresh() {
    ref.invalidate(ticketProvider(widget.id));
    ref.invalidate(ticketCommentsProvider(widget.id));
    ref.invalidate(ticketEventsProvider(widget.id));
  }

  Future<void> _run(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await action();
      _refresh();
    } catch (e) {
      // The server's refusal is the useful text — a rejected transition
      // names the moves that were available instead — so it is shown
      // rather than replaced with "something went wrong".
      messenger.showSnackBar(
        SnackBar(content: Text(e is PostgrestException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ticket = ref.watch(ticketProvider(widget.id));

    return Scaffold(
      appBar: AppBar(
        title: ticket.maybeWhen(
          data: (t) => Text((t['ticket_no'] ?? 'Ticket') as String),
          orElse: () => const Text('Ticket'),
        ),
      ),
      body: AsyncView(
        value: ticket,
        onRetry: () => ref.invalidate(ticketProvider(widget.id)),
        builder: (t) => PageBody(
          child: ListView(
            children: [
              _Header(
                t,
                team: _nameOf(ref.watch(ticketTeamsProvider), t['team_id']),
                category: _nameOf(
                  ref.watch(ticketCategoriesProvider),
                  t['category_id'],
                ),
              ),
              const SizedBox(height: 16),
              _Sla(t),
              const SizedBox(height: 16),
              _Actions(
                ticket: t,
                busy: _busy,
                onTransition: (to) => _run(
                  () => requireRepo(ref).transitionTicket(widget.id, to),
                ),
              ),
              const SizedBox(height: 24),
              const SectionHeader('Conversation'),
              _Conversation(widget.id),
              const SizedBox(height: 16),
              _ReplyBox(
                controller: _reply,
                internal: _internal,
                busy: _busy,
                onInternalChanged: (v) => setState(() => _internal = v),
                onSend: () {
                  final body = _reply.text.trim();
                  if (body.isEmpty) return;
                  _run(() async {
                    await requireRepo(
                      ref,
                    ).addTicketComment(widget.id, body, internal: _internal);
                    _reply.clear();
                  });
                },
              ),
              const SizedBox(height: 24),
              const SectionHeader('History'),
              _History(widget.id),
            ],
          ),
        ),
      ),
    );
  }
}

/// The name behind an id, from a list the screen already holds. Null
/// while the list is still loading, which reads as "not shown yet"
/// rather than as "not set".
String? _nameOf(AsyncValue<List<Map<String, dynamic>>> v, Object? id) {
  if (id == null) return null;
  for (final row in v.value ?? const <Map<String, dynamic>>[]) {
    if (row['id'] == id) return row['name'] as String?;
  }
  return null;
}

class _Header extends StatelessWidget {
  const _Header(this.t, {this.team, this.category});

  final Map<String, dynamic> t;
  final String? team;
  final String? category;

  @override
  Widget build(BuildContext context) {
    // Bound to locals because Dart does not promote public nullable
    // fields, so `if (team != null) Text(team)` does not compile.
    final team = this.team;
    final category = this.category;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (t['subject'] ?? '') as String,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            StatusChip((t['status'] ?? '') as String),
            Chip(label: Text((t['priority'] ?? '').toString().toUpperCase())),
            Chip(label: Text(_typeLabel(t['ticket_type'] as String?))),
            if (team != null) Chip(label: Text(team)),
            if (category != null) Chip(label: Text(category)),
            Chip(label: Text('via ${t['channel']}')),
          ],
        ),
        if ((t['description'] as String?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 12),
          Text(t['description'] as String),
        ],
        const SizedBox(height: 12),
        FieldRow(
          label: 'Raised',
          value: Fmt.dateTime(
            DateTime.parse(t['opened_at'] as String).toLocal(),
          ),
        ),
        FieldRow(
          label: 'Raised by',
          value: t['requester_contact_id'] != null
              ? 'A customer'
              : 'Somebody in the company',
        ),
        if ((t['escalation_level'] as int? ?? 0) > 0)
          FieldRow(
            label: 'Escalated',
            value: '${t['escalation_level']} time(s)',
          ),
        if ((t['reopened_count'] as int? ?? 0) > 0)
          FieldRow(
            label: 'Reopened',
            value: '${t['reopened_count']} time(s)',
          ),
      ],
    );
  }

  static String _typeLabel(String? t) => switch (t) {
    'service_request' => 'Service request',
    'problem' => 'Problem',
    'change' => 'Change',
    _ => 'Incident',
  };
}

/// The two promises, and whether each was kept.
///
/// A deadline that has passed is shown as breached rather than as a date
/// in the past, because the second requires the reader to do the
/// comparison and they will not.
class _Sla extends StatelessWidget {
  const _Sla(this.t);

  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context) {
    final respondedAt = t['first_response_at'] as String?;
    final resolvedAt = t['resolved_at'] as String?;

    return Column(
      children: [
        _SlaLine(
          label: 'First response',
          dueAt: t['response_due_at'] as String?,
          metAt: respondedAt,
          breached: t['response_breached'] as bool? ?? false,
        ),
        const SizedBox(height: 4),
        _SlaLine(
          label: 'Resolution',
          dueAt: t['resolution_due_at'] as String?,
          metAt: resolvedAt,
          breached: t['resolution_breached'] as bool? ?? false,
        ),
      ],
    );
  }
}

class _SlaLine extends StatelessWidget {
  const _SlaLine({
    required this.label,
    required this.dueAt,
    required this.metAt,
    required this.breached,
  });

  final String label;
  final String? dueAt;
  final String? metAt;
  final bool breached;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (text, color) = switch ((metAt, breached, dueAt)) {
      (final m?, _, _) => (
        'met ${Fmt.dateTime(DateTime.parse(m).toLocal())}',
        c.success,
      ),
      (_, true, _) => ('breached', c.danger),
      (_, _, final d?) => (
        'due ${Fmt.dateTime(DateTime.parse(d).toLocal())}',
        c.info,
      ),
      _ => ('no target', const Color(0xFF94A3B8)),
    };

    return Row(
      children: [
        SizedBox(
          width: 130,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.ticket,
    required this.busy,
    required this.onTransition,
  });

  final Map<String, dynamic> ticket;
  final bool busy;
  final ValueChanged<String> onTransition;

  @override
  Widget build(BuildContext context) {
    final status = (ticket['status'] ?? '') as String;
    final allowed = kTicketTransitions[status] ?? const <String>[];

    if (allowed.isEmpty) {
      return Text(
        'This ticket was cancelled and cannot be moved again.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final to in allowed)
          FilledButton.tonal(
            onPressed: busy ? null : () => onTransition(to),
            child: Text(_label(to)),
          ),
      ],
    );
  }

  static String _label(String s) => switch (s) {
    'open' => 'Open',
    'pending' => 'Wait on requester',
    'on_hold' => 'Put on hold',
    'resolved' => 'Resolve',
    'closed' => 'Close',
    'cancelled' => 'Cancel',
    _ => s,
  };
}

class _Conversation extends ConsumerWidget {
  const _Conversation(this.id);

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final comments = ref.watch(ticketCommentsProvider(id));
    return AsyncView(
      value: comments,
      onRetry: () => ref.invalidate(ticketCommentsProvider(id)),
      builder: (list) {
        if (list.isEmpty) {
          return Text(
            'Nothing said yet.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }
        return Column(
          children: [for (final c in list) _Comment(c)],
        );
      },
    );
  }
}

class _Comment extends StatelessWidget {
  const _Comment(this.c);

  final Map<String, dynamic> c;

  @override
  Widget build(BuildContext context) {
    final internal = c['is_internal'] as bool? ?? true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Said plainly, because the difference between a note
                // and a reply is the difference between a colleague
                // reading it and a customer reading it.
                Text(
                  internal ? 'Internal note' : 'Reply to requester',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: internal
                        ? context.colors.warning
                        : context.colors.info,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  Fmt.dateTime(
                    DateTime.parse(c['created_at'] as String).toLocal(),
                  ),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text((c['body'] ?? '') as String),
          ],
        ),
      ),
    );
  }
}

class _ReplyBox extends ConsumerWidget {
  const _ReplyBox({
    required this.controller,
    required this.internal,
    required this.busy,
    required this.onInternalChanged,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool internal;
  final bool busy;
  final ValueChanged<bool> onInternalChanged;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canned = ref.watch(cannedResponsesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          minLines: 2,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Add a note or reply',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Defaults to the internal note, matching the column
            // default, so the dangerous direction is the one that has to
            // be chosen rather than the one that happens by accident.
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: true, label: Text('Internal note')),
                ButtonSegment(value: false, label: Text('Reply to requester')),
              ],
              selected: {internal},
              onSelectionChanged: (s) => onInternalChanged(s.first),
            ),
            const Spacer(),
            canned.maybeWhen(
              data: (list) => list.isEmpty
                  ? const SizedBox.shrink()
                  : PopupMenuButton<String>(
                      tooltip: 'Canned response',
                      icon: const Icon(Icons.quickreply_outlined),
                      itemBuilder: (_) => [
                        for (final r in list)
                          PopupMenuItem(
                            value: r['body'] as String,
                            child: Text((r['title'] ?? '') as String),
                          ),
                      ],
                      onSelected: (body) => controller.text = body,
                    ),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : onSend,
              child: const Text('Send'),
            ),
          ],
        ),
      ],
    );
  }
}

class _History extends ConsumerWidget {
  const _History(this.id);

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(ticketEventsProvider(id));
    return AsyncView(
      value: events,
      onRetry: () => ref.invalidate(ticketEventsProvider(id)),
      builder: (list) => Column(
        children: [
          for (final e in list)
            ListTile(
              dense: true,
              leading: Icon(_icon(e['event_type'] as String?), size: 18),
              title: Text(_describe(e)),
              trailing: Text(
                Fmt.dateTime(
                  DateTime.parse(e['created_at'] as String).toLocal(),
                ),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
    );
  }

  static IconData _icon(String? type) => switch (type) {
    'created' => Icons.add_circle_outline,
    'status' => Icons.swap_horiz,
    'assigned' => Icons.person_outline,
    'escalated' => Icons.trending_up,
    'first_response' => Icons.reply_outlined,
    'sla_breach' => Icons.warning_amber_outlined,
    _ => Icons.circle_outlined,
  };

  static String _describe(Map<String, dynamic> e) {
    final type = e['event_type'] as String?;
    final from = e['from_value'] as String?;
    final to = e['to_value'] as String?;
    return switch (type) {
      'created' => 'Raised at $to',
      'status' => 'Moved from $from to $to',
      'assigned' => 'Assigned',
      'escalated' => 'Escalated to level $to — ${e['note'] ?? ''}',
      'first_response' => 'First reply sent',
      'sla_breach' => '${to == 'response' ? 'Response' : 'Resolution'} '
          'deadline breached',
      _ => type ?? 'Event',
    };
  }
}
