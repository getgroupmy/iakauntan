import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/searchable_picker.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'teams.dart';

/// The support teams, and who is on each.
///
/// Neither was reachable. `ticket_teams` could be filtered by and
/// labelled with and never created, so every team in existence came
/// from a demo seed; `ticket_team_members` was written by nothing at
/// all. `0355` gives the membership list its meaning — a ticket on a
/// team whose list has been filled in may only be handed to somebody on
/// it — and this is where the list is filled in.
class TicketTeamsScreen extends ConsumerWidget {
  const TicketTeamsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final teams = ref.watch(ticketTeamsAllProvider);
    final canAdmin = ref.watch(canAdminProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Support teams')),
      floatingActionButton: canAdmin
          ? FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, null),
              icon: const Icon(Icons.add),
              label: const Text('Add a team'),
            )
          : null,
      body: AsyncView<List<Map<String, dynamic>>>(
        value: teams,
        onRetry: () => ref.invalidate(ticketTeamsAllProvider),
        skeleton: const ListSkeleton(rows: 6, leading: false),
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.groups_outlined,
              title: 'No teams yet',
              message: 'A team is who a ticket is routed to. Until there is '
                  'one, every ticket sits in the same queue.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              for (final t in rows)
                _TeamTile(team: t, canAdmin: canAdmin),
            ],
          );
        },
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic>? existing,
  ) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _TeamDialog(existing: existing),
    );
    if (saved == true) {
      ref.invalidate(ticketTeamsAllProvider);
      ref.invalidate(ticketTeamsProvider);
    }
  }
}

class _TeamTile extends ConsumerWidget {
  const _TeamTile({required this.team, required this.canAdmin});

  final Map<String, dynamic> team;
  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${team['id']}';
    final roster = ref.watch(ticketTeamRosterProvider(id)).valueOrNull;

    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text('${team['name']}')),
          if (team['is_active'] != true) ...[
            const SizedBox(width: Space.sm),
            const StatusChip('retired', compact: true),
          ],
        ],
      ),
      // Held until the roster lands rather than saying "nobody is on
      // it" while the read is still in flight: that sentence describes
      // a setting with a consequence, and flashing it at somebody who
      // has filled the team in reads as their work having been lost.
      subtitle: roster == null
          ? null
          : Text(
              rosterSummary(roster),
              style: TextStyle(
                fontSize: 12,
                color: context.scheme.onSurfaceVariant,
              ),
            ),
      trailing: canAdmin
          ? IconButton(
              tooltip: 'Rename',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () async {
                final saved = await showDialog<bool>(
                  context: context,
                  builder: (_) => _TeamDialog(existing: team),
                );
                if (saved == true) {
                  ref.invalidate(ticketTeamsAllProvider);
                  ref.invalidate(ticketTeamsProvider);
                }
              },
            )
          : null,
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => _RosterDialog(team: team, canAdmin: canAdmin),
      ),
    );
  }
}

class _TeamDialog extends ConsumerStatefulWidget {
  const _TeamDialog({required this.existing});

  final Map<String, dynamic>? existing;

  @override
  ConsumerState<_TeamDialog> createState() => _TeamDialogState();
}

class _TeamDialogState extends ConsumerState<_TeamDialog> {
  late final _name = TextEditingController(
    text: '${widget.existing?['name'] ?? ''}',
  );
  late bool _active = widget.existing?['is_active'] != false;
  bool _busy = false;
  String? _said;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final taken = (ref.read(ticketTeamsAllProvider).valueOrNull ?? const [])
        .map((t) => '${t['code']}');
    final blocked = teamBlockedBecause(
      name: _name.text,
      takenCodes: taken,
      editingCode: widget.existing == null
          ? null
          : '${widget.existing!['code']}',
    );
    if (blocked != null) {
      setState(() => _said = blocked);
      return;
    }
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      successMessage: 'Team saved',
      action: () => ref.read(repoProvider)!.saveTicketTeam(
        id: widget.existing?['id'] as String?,
        code: teamCode(_name.text),
        name: _name.text.trim(),
        isActive: _active,
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add a team' : 'Rename team'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'Billing, Front desk, Dispatch',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _active,
              onChanged: (v) => setState(() => _active = v),
              title: const Text('Tickets can be routed to it'),
              subtitle: const Text(
                'Retiring a team leaves the tickets already on it where '
                'they are.',
              ),
            ),
            if (_said != null)
              Text(
                _said!,
                style: TextStyle(fontSize: 12, color: context.colors.danger),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Who is on one team.
class _RosterDialog extends ConsumerWidget {
  const _RosterDialog({required this.team, required this.canAdmin});

  final Map<String, dynamic> team;
  final bool canAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = '${team['id']}';
    final roster = ref.watch(ticketTeamRosterProvider(id)).valueOrNull;
    final orgTeam = ref.watch(teamProvider).valueOrNull ?? const <TeamMember>[];

    Future<void> reload() async {
      ref.invalidate(ticketTeamRosterProvider(id));
      ref.invalidate(ticketTeamsAllProvider);
    }

    final addable = addableTo(
      orgTeam: [
        for (final m in orgTeam)
          {'user_id': m.userId, 'status': m.status, 'name': m.displayName},
      ],
      roster: roster ?? const [],
    );

    return AlertDialog(
      title: Text('${team['name']}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (roster != null && roster.isEmpty)
                // Said in full here rather than left to the one-line
                // summary: on this screen somebody is deciding whether
                // to fill the list in, and what an empty one *does* is
                // the whole of that decision.
                Text(
                  'Nobody is on this team, so a ticket routed here can be '
                  'given to anybody in the company. Add somebody and only '
                  'the people on this list can take these tickets.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.scheme.onSurfaceVariant,
                  ),
                ),
              for (final m in roster ?? const <Map<String, dynamic>>[])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(memberName(m),
                      style: const TextStyle(fontSize: 13)),
                  subtitle: m['is_lead'] == true
                      ? const Text('Leads this team',
                          style: TextStyle(fontSize: 11))
                      : null,
                  trailing: !canAdmin
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (m['is_lead'] != true)
                              IconButton(
                                tooltip: 'Make lead',
                                icon: const Icon(Icons.star_outline, size: 18),
                                onPressed: () async {
                                  final ok = await runWithFeedback(
                                    context,
                                    successMessage: 'Lead changed',
                                    action: () => ref
                                        .read(repoProvider)!
                                        .setTicketTeamLead(
                                            id, '${m['user_id']}'),
                                  );
                                  if (ok) await reload();
                                },
                              ),
                            IconButton(
                              tooltip: 'Take off the team',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () async {
                                final ok = await runWithFeedback(
                                  context,
                                  successMessage: 'Taken off the team',
                                  action: () => ref
                                      .read(repoProvider)!
                                      .removeTicketTeamMember(
                                          id, '${m['user_id']}'),
                                );
                                if (ok) await reload();
                              },
                            ),
                          ],
                        ),
                ),
              if (canAdmin && addable.isNotEmpty) ...[
                const Divider(height: Space.xl),
                SearchablePicker<String>(
                  options: [
                    for (final m in addable)
                      PickerOption<String>(
                        value: '${m['user_id']}',
                        label: '${m['name']}',
                      ),
                  ],
                  // Nothing stays chosen: picking somebody ADDS them and
                  // the box goes back to empty, ready for the next one.
                  value: null,
                  label: 'Add somebody',
                  onChanged: (v) async {
                    if (v == null) return;
                    final ok = await runWithFeedback(
                      context,
                      successMessage: 'Added to the team',
                      action: () =>
                          ref.read(repoProvider)!.addTicketTeamMember(id, v),
                    );
                    if (ok) await reload();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
