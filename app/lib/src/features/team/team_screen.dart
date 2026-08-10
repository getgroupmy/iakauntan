import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';

/// Who is in the company and what they may do. Inviting someone creates
/// a pending membership; when they register with that e-mail the database
/// claims the invitation and drops them straight into the right company.
class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(teamProvider);
    final canAdmin = ref.watch(canAdminProvider);
    final me = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team & access'),
        actions: [
          if (canAdmin)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _InviteDialog(),
                ),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Invite'),
              ),
            ),
        ],
      ),
      body: AsyncView(
        value: team,
        onRetry: () => ref.invalidate(teamProvider),
        builder: (members) => SingleChildScrollView(
          child: PageBody(
            maxWidth: 900,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < members.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _MemberTile(
                          member: members[i],
                          canAdmin: canAdmin,
                          isSelf: members[i].userId == me?.id,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const _RoleReference(),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.member,
    required this.canAdmin,
    required this.isSelf,
  });

  final TeamMember member;
  final bool canAdmin;
  final bool isSelf;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // An owner is never demoted or removed from here; ownership is
    // transferred deliberately, not edited in a list.
    final editable = canAdmin && !isSelf && member.role != 'owner';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: CircleAvatar(
        backgroundColor: member.isPending
            ? scheme.surfaceContainerHighest
            : scheme.primaryContainer,
        child: member.isPending
            ? const Icon(Icons.schedule, size: 18)
            : Text(Fmt.initials(member.displayName),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
      title: Row(children: [
        Flexible(
          child: Text(member.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500)),
        ),
        if (isSelf) ...[
          const SizedBox(width: 8),
          const StatusChip('you', compact: true),
        ],
        if (member.isPending) ...[
          const SizedBox(width: 8),
          const StatusChip('pending', compact: true),
        ],
      ]),
      subtitle: Text(
        member.email ?? '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editable)
            DropdownButton<String>(
              value: member.role,
              underline: const SizedBox.shrink(),
              onChanged: (role) => _changeRole(context, ref, role),
              items: [
                for (final e in memberRoles.entries)
                  if (e.key != 'owner')
                    DropdownMenuItem(value: e.key, child: Text(e.value.label)),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(roleLabel(member.role),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          if (editable)
            IconButton(
              tooltip: 'Remove from company',
              icon: const Icon(Icons.person_remove_outlined, size: 18),
              onPressed: () => _remove(context, ref),
            ),
        ],
      ),
    );
  }

  Future<void> _changeRole(
      BuildContext context, WidgetRef ref, String? role) async {
    if (role == null) return;
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.changeMemberRole(member.memberId, role),
      successMessage: '${member.displayName} is now ${roleLabel(role)}',
    );
    ref.invalidate(teamProvider);
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Remove ${member.displayName}?',
      message: 'They lose access to this company immediately. Records they '
          'created are kept.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.removeMember(member.memberId),
      successMessage: 'Removed from the company',
    );
    ref.invalidate(teamProvider);
  }
}

class _InviteDialog extends ConsumerStatefulWidget {
  const _InviteDialog();

  @override
  ConsumerState<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends ConsumerState<_InviteDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  String _role = 'accounts_clerk';
  bool _saving = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _invite() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final ok = await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.inviteMember(_email.text.trim(), _role),
      successMessage: 'Invitation created for ${_email.text.trim()}',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(teamProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite someone'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Email address *',
                  helperText: 'They join this company when they register',
                ),
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return 'Enter an email address';
                  if (!value.contains('@')) return 'Enter a valid email';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Access type'),
                items: [
                  for (final e in memberRoles.entries)
                    if (e.key != 'owner')
                      DropdownMenuItem(value: e.key, child: Text(e.value.label)),
                ],
                onChanged: (v) => setState(() => _role = v ?? 'viewer'),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  memberRoles[_role]?.description ?? '',
                  style: Theme.of(context).textTheme.bodySmall,
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
          onPressed: _saving ? null : _invite,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Send invitation'),
        ),
      ],
    );
  }
}

class _RoleReference extends StatelessWidget {
  const _RoleReference();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              'What each access type can do',
              subtitle: 'Enforced by the database, not just hidden in the app',
            ),
            for (final e in memberRoles.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(e.value.label,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                      child: Text(e.value.description,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: context.colors.info.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'An Accounts Clerk can prepare invoices and bills but cannot '
                'post them to the ledger — that separation is deliberate, so '
                'preparation and approval stay in different hands.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
