import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Handing a ticket to somebody, and handing it upwards.
///
/// `0194` has had `assign_ticket` and `escalate_ticket` since the
/// lifecycle went in, and nothing in the app called either: a ticket
/// arrived, sat in whatever queue it landed in, and could only be
/// moved through its states by whoever happened to open it. This is
/// the pair of forms that reach them.
///
/// Both functions refuse the same shapes, so both forms refuse them
/// first — the point of the sheet is that the server's `raise` is
/// never the thing the user reads.

/// Who can be given a ticket.
///
/// `assign_ticket` refuses anybody who is not an active member of the
/// organization, and somebody who has been invited but has not accepted
/// has no `user_id` to name — so the list offered is exactly the set
/// the server will take.
///
/// Since `0355` there is a second refusal, and `roster` is how this
/// mirrors it: a ticket on a team whose membership has been filled in
/// may only be handed to somebody on that team. Null roster means the
/// list has not arrived, and an *empty* one means the team has nobody
/// on it — which the database reads as "anybody", so this does too. The
/// two are different answers and collapsing them would offer nobody at
/// all on every team that has not been filled in.
List<TeamMember> assignableMembers(
  Iterable<TeamMember> team, {
  List<Map<String, dynamic>>? roster,
}) {
  final active =
      team.where((m) => m.status == 'active' && m.userId != null).toList();
  if (roster == null || roster.isEmpty) return active;
  final onTeam = {for (final m in roster) '${m['user_id']}'};
  return active.where((m) => onTeam.contains(m.userId)).toList();
}

/// The name against `assignee_id`.
///
/// Somebody can leave an organization while still holding a ticket, and
/// then the id resolves to nobody in the list. That is a real state and
/// it has to read as one — a blank line here is how a ticket goes
/// quietly unowned.
String assigneeLabel(Iterable<TeamMember> team, String? assigneeId) {
  if (assigneeId == null) return 'Nobody yet';
  for (final m in team) {
    if (m.userId == assigneeId) return m.displayName;
  }
  return 'Somebody no longer on the team';
}

/// What handing a ticket over does to its status.
///
/// Both `assign_ticket` and `escalate_ticket` carry the same clause:
/// a ticket still sitting at `new` is opened by the act of being given
/// to somebody. Mirrored so the form can say so before it happens
/// rather than the status changing under the reader.
String statusAfterHandover(String status) => status == 'new' ? 'open' : status;

const List<String> kEscalationKinds = ['functional', 'hierarchic'];

String escalationLabel(String kind) => switch (kind) {
  'functional' => 'Sideways, to another team',
  'hierarchic' => 'Upwards, to somebody more senior',
  _ => kind,
};

/// A functional escalation moves the ticket to a different team; a
/// hierarchic one moves it up to a person. Each names the party its
/// own kind is about, and `escalate_ticket` raises if that party is
/// missing.
bool escalationNeedsTeam(String kind) => kind == 'functional';
bool escalationNeedsUser(String kind) => kind == 'hierarchic';

/// Whether escalating this ticket means anything.
///
/// An affordance, not a rule: `escalate_ticket` would happily bump the
/// level on a cancelled ticket. Nobody wants that, and the server is
/// not the place to argue about it, so the button is simply not
/// offered once the ticket is finished with.
bool escalationMakesSense(String status) =>
    status != 'cancelled' && status != 'closed';

/// An escalation, or null where the kind's own party has not been named.
///
/// The party the kind does not take is dropped rather than passed as
/// null, so a functional escalation cannot quietly reassign the ticket
/// to whoever was last selected in the other dropdown.
Escalation? escalationOf({
  required String kind,
  String? teamId,
  String? userId,
  String? reason,
}) {
  if (escalationNeedsTeam(kind) && teamId == null) return null;
  if (escalationNeedsUser(kind) && userId == null) return null;

  final trimmed = reason?.trim();
  return Escalation(
    kind: kind,
    toTeam: escalationNeedsTeam(kind) ? teamId : null,
    toUser: escalationNeedsUser(kind) ? userId : null,
    reason: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
  );
}

class Escalation {
  const Escalation({
    required this.kind,
    this.toTeam,
    this.toUser,
    this.reason,
  });

  final String kind;
  final String? toTeam;
  final String? toUser;
  final String? reason;
}

/// Give the ticket to somebody, or take it back off them.
Future<bool> showAssignTicketSheet(
  BuildContext context, {
  required String ticketId,
  required String status,
  String? assigneeId,
  String? teamId,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _AssignSheet(
        ticketId: ticketId,
        status: status,
        assigneeId: assigneeId,
        teamId: teamId,
      ),
    ) ??
    false;

class _AssignSheet extends ConsumerStatefulWidget {
  const _AssignSheet({
    required this.ticketId,
    required this.status,
    this.assigneeId,
    this.teamId,
  });

  final String ticketId;
  final String status;
  final String? assigneeId;
  final String? teamId;

  @override
  ConsumerState<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends ConsumerState<_AssignSheet> {
  String? _userId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _userId = widget.assigneeId;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.assignTicket(widget.ticketId, _userId),
      successMessage: _userId == null ? 'Put back in the queue' : 'Assigned',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final team = ref.watch(teamProvider).valueOrNull ?? const <TeamMember>[];
    final roster = widget.teamId == null
        ? null
        : ref.watch(ticketTeamRosterProvider(widget.teamId!)).valueOrNull;
    final people = assignableMembers(team, roster: roster);
    final opens = statusAfterHandover(widget.status) != widget.status;

    return AlertDialog(
      title: const Text('Assign this ticket'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (opens)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Text(
                  'This ticket is still new. Giving it to somebody opens it.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.scheme.onSurfaceVariant),
                ),
              ),
            DropdownButtonFormField<String?>(
              key: const ValueKey('assign-person'),
              value: _userId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Assign to'),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Nobody — leave it in the queue'),
                ),
                for (final m in people)
                  DropdownMenuItem<String?>(
                    value: m.userId,
                    child: Text(
                      m.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _saving ? null : (v) => setState(() => _userId = v),
            ),
            if (people.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Text(
                  'Nobody here has accepted their invitation yet, so there '
                  'is nobody a ticket can be given to.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.colors.warning),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('assign-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Assign'),
        ),
      ],
    );
  }
}

/// Send the ticket somewhere it will actually get done.
Future<bool> showEscalateTicketSheet(
  BuildContext context, {
  required String ticketId,
  required String status,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _EscalateSheet(ticketId: ticketId, status: status),
    ) ??
    false;

class _EscalateSheet extends ConsumerStatefulWidget {
  const _EscalateSheet({required this.ticketId, required this.status});

  final String ticketId;
  final String status;

  @override
  ConsumerState<_EscalateSheet> createState() => _EscalateSheetState();
}

class _EscalateSheetState extends ConsumerState<_EscalateSheet> {
  final _reason = TextEditingController();

  String _kind = 'functional';
  String? _teamId;
  String? _userId;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final e = escalationOf(
      kind: _kind,
      teamId: _teamId,
      userId: _userId,
      reason: _reason.text,
    );
    if (e == null) return;

    setState(() => _saving = true);
    final ok = await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.escalateTicket(
            widget.ticketId,
            e.kind,
            toTeam: e.toTeam,
            toUser: e.toUser,
            reason: e.reason,
          ),
      successMessage: 'Escalated',
    );
    if (mounted) setState(() => _saving = false);
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final teams = ref.watch(ticketTeamsProvider).valueOrNull ??
        const <Map<String, dynamic>>[];
    final team = ref.watch(teamProvider).valueOrNull ?? const <TeamMember>[];
    final people = assignableMembers(team);
    final opens = statusAfterHandover(widget.status) != widget.status;

    final ready = escalationOf(
          kind: _kind,
          teamId: _teamId,
          userId: _userId,
        ) !=
        null;

    return AlertDialog(
      title: const Text('Escalate'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Escalating raises the level on the ticket and writes why '
                'into its history. It does not reset the clock: the SLA '
                'that was promised is still the one being measured.'
                '${opens ? ' A ticket still new is opened by it.' : ''}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.scheme.onSurfaceVariant),
              ),
              const SizedBox(height: Space.md),
              DropdownButtonFormField<String>(
                key: const ValueKey('escalate-kind'),
                value: _kind,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Which way'),
                items: [
                  for (final k in kEscalationKinds)
                    DropdownMenuItem(value: k, child: Text(escalationLabel(k))),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _kind = v ?? _kind),
              ),
              const SizedBox(height: Space.md),
              // Only the party this kind of escalation is about. The
              // other would be accepted and would quietly change
              // something nobody asked to change.
              if (escalationNeedsTeam(_kind))
                DropdownButtonFormField<String?>(
                  key: const ValueKey('escalate-team'),
                  value: _teamId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'To which team'),
                  items: [
                    for (final t in teams)
                      DropdownMenuItem<String?>(
                        value: t['id'] as String?,
                        child: Text(
                          (t['name'] ?? '—') as String,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _teamId = v),
                ),
              if (escalationNeedsUser(_kind))
                DropdownButtonFormField<String?>(
                  key: const ValueKey('escalate-person'),
                  value: _userId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'To whom'),
                  items: [
                    for (final m in people)
                      DropdownMenuItem<String?>(
                        value: m.userId,
                        child: Text(
                          m.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged:
                      _saving ? null : (v) => setState(() => _userId = v),
                ),
              const SizedBox(height: Space.md),
              TextFormField(
                key: const ValueKey('escalate-reason'),
                controller: _reason,
                enabled: !_saving,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Why',
                  helperText: 'Goes into the history beside the level.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('escalate-save'),
          onPressed: _saving || !ready ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Escalate'),
        ),
      ],
    );
  }
}
