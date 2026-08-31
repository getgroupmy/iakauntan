import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import 'access_types_card.dart';
import 'invitations.dart';
import 'audit_trail_card.dart';

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
                if (canAdmin) ...[
                  const AccessTypesCard(),
                  const SizedBox(height: 24),
                  const _PayslipAccessCard(),
                  const SizedBox(height: 24),
                  const AuditTrailCard(),
                  const SizedBox(height: 24),
                ],
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
        // The access type belongs next to the person, not only in the
        // card that defines it — "what can Aminah see" is asked about
        // Aminah.
        member.accessTypeName == null
            ? (member.email ?? '—')
            : '${member.email ?? '—'} · ${member.accessTypeName}',
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
                for (final e in assignableRoles)
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
              tooltip: 'Access type',
              icon: const Icon(Icons.key_outlined, size: 18),
              onPressed: () => _chooseAccessType(context, ref),
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

  /// Which access type this person holds, or none at all.
  ///
  /// "Everything" is first and is what everybody has until a company
  /// decides otherwise, so the list reads as a narrowing rather than a
  /// grant.
  Future<void> _chooseAccessType(BuildContext context, WidgetRef ref) async {
    final types = await ref.read(accessTypesProvider.future);
    if (!context.mounted) return;

    final chosen = await showDialog<({String? id})>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text('Access for ${member.displayName}'),
        children: [
          RadioListTile<String?>(
            value: null,
            groupValue: member.accessTypeId,
            title: const Text('Everything'),
            subtitle: const Text('Every module the company has'),
            onChanged: (_) => Navigator.of(context).pop((id: null)),
          ),
          for (final t in types)
            RadioListTile<String?>(
              value: t.id,
              groupValue: member.accessTypeId,
              title: Text(t.name),
              subtitle: Text(t.grantedCount == 0
                  ? 'No modules — reaches nothing'
                  : '${t.grantedCount} '
                      '${t.grantedCount == 1 ? "module" : "modules"}'),
              onChanged: (_) => Navigator.of(context).pop((id: t.id)),
            ),
          if (types.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Text(
                'No access types yet. Create one below the team list.',
                style: TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .setMemberAccessType(member.memberId, chosen.id),
      successMessage: 'Access updated',
    );
    ref.invalidate(teamProvider);
    ref.invalidate(myModuleAccessProvider);
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
    final email = _email.text.trim();
    setState(() => _saving = true);

    String? token;
    // `runWithFeedback` reports the failure; the token is what this
    // call is for, so it is captured on the way through rather than
    // read back afterwards — `0353` stores a digest and there is no
    // reading it back.
    final ok = await runWithFeedback(
      context,
      action: () async {
        token = await ref.read(repoProvider)!.inviteMember(email, _role);
      },
      successMessage: 'Invitation created for $email',
    );

    if (mounted) setState(() => _saving = false);
    if (ok && mounted) {
      ref.invalidate(teamProvider);
      Navigator.pop(context);
      await showDialog<void>(
        context: context,
        builder: (_) => _InvitationIssued(email: email, token: token),
      );
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
                  // Both halves, because they are two different
                  // journeys and the old text described only one of
                  // them: somebody without an account joins by
                  // registering at this address, and somebody who
                  // already has one joins with the code this produces.
                  helperText: 'They join when they register, or with the '
                      'code you are about to be given',
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
                  for (final e in assignableRoles)
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


/// Auditors asking to see payslips, and what was decided. Sits with the
/// rest of access management because that is what it is.
class _PayslipAccessCard extends ConsumerWidget {
  const _PayslipAccessCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(payslipAccessRequestsProvider);

    return requests.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (list) {
        if (list.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                  'Payslip access',
                  subtitle: 'Auditors do not see what people are paid unless '
                      'you let them, and only for as long as you say',
                ),
                for (var i = 0; i < list.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _AccessRow(request: list[i]),
                ],
                const SizedBox(height: Space.lg),
                const _AccessLog(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Who actually opened what. Written by the read functions themselves,
/// so a payslip cannot be read under a grant without appearing here.
class _AccessLog extends ConsumerStatefulWidget {
  const _AccessLog();

  @override
  ConsumerState<_AccessLog> createState() => _AccessLogState();
}

class _AccessLogState extends ConsumerState<_AccessLog> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(payslipAccessLogProvider);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Row(children: [
                Icon(Icons.history, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    'Who has opened a payslip'
                    '${log.valueOrNull == null ? '' : ' (${log.value!.length})'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(_open ? Icons.expand_less : Icons.expand_more, size: 20),
              ]),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Space.md, 0, Space.md, Space.md),
              child: log.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) => Text('$e'),
                data: (entries) => entries.isEmpty
                    ? Text('Nobody has opened a payslip under a grant.',
                        style: Theme.of(context).textTheme.bodySmall)
                    : Column(
                        children: [
                          for (final e in entries)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: Space.xs),
                              child: Row(children: [
                                Icon(
                                  e.isView
                                      ? Icons.visibility_outlined
                                      : Icons.list_alt,
                                  size: 15,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: Space.sm),
                                Expanded(
                                  child: Text(
                                    '${e.actorName ?? 'Someone'} — ${e.summary}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                                Text(
                                  Fmt.dateTime(e.viewedAt),
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          color: scheme.onSurfaceVariant),
                                ),
                              ]),
                            ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AccessRow extends ConsumerWidget {
  const _AccessRow({required this.request});

  final PayslipAccessRequest request;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(request.requesterName ?? 'Auditor',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: Space.sm),
                  StatusChip(request.displayStatus, compact: true),
                ]),
                const SizedBox(height: 2),
                Text(request.reason,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  [
                    request.scopeLabel,
                    'asked ${Fmt.date(request.requestedAt)}',
                    if (request.isLive && request.expiresAt != null)
                      'expires ${Fmt.date(request.expiresAt)}',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          if (request.isPending)
            Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => _decide(context, ref, false),
                child: Text('Refuse',
                    style: TextStyle(color: context.colors.danger)),
              ),
              FilledButton(
                onPressed: () => _approve(context, ref),
                child: const Text('Approve'),
              ),
            ])
          else if (request.isLive)
            OutlinedButton(
              onPressed: () => _revoke(context, ref),
              child: const Text('Revoke'),
            ),
        ],
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    final days = await showDialog<int>(
      context: context,
      builder: (_) => const _AccessDurationDialog(),
    );
    if (days == null || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref
          .read(repoProvider)!
          .decidePayslipAccess(request.id, true, days: days),
      successMessage: 'Granted for $days days, read only',
    );
    ref.invalidate(payslipAccessRequestsProvider);
  }

  Future<void> _decide(BuildContext context, WidgetRef ref, bool approve) async {
    await runWithFeedback(
      context,
      action: () =>
          ref.read(repoProvider)!.decidePayslipAccess(request.id, approve),
      successMessage: 'Refused',
    );
    ref.invalidate(payslipAccessRequestsProvider);
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Revoke access?',
      message: '${request.requesterName ?? 'The auditor'} loses sight of every '
          'payslip immediately.',
      confirmLabel: 'Revoke',
      destructive: true,
    );
    if (!ok || !context.mounted) return;

    await runWithFeedback(
      context,
      action: () => ref.read(repoProvider)!.revokePayslipAccess(request.id),
      successMessage: 'Access revoked',
    );
    ref.invalidate(payslipAccessRequestsProvider);
  }
}

/// Access has to expire, so the only question is when.
class _AccessDurationDialog extends StatefulWidget {
  const _AccessDurationDialog();

  @override
  State<_AccessDurationDialog> createState() => _AccessDurationDialogState();
}

class _AccessDurationDialogState extends State<_AccessDurationDialog> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('How long?'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Access is read-only and ends by itself, so nobody has to '
              'remember to take it away.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.lg),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 7, label: Text('7 days')),
                ButtonSegment(value: 30, label: Text('30 days')),
                ButtonSegment(value: 90, label: Text('90 days')),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
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
          onPressed: () => Navigator.pop(context, _days),
          child: const Text('Grant access'),
        ),
      ],
    );
  }
}

/// The code, handed over once.
///
/// No e-mail carries it. `invite_member` returns the raw token and
/// `0353` stores only a digest, so this dialog is the only moment it
/// exists anywhere — which is said on the dialog, because somebody who
/// closes it expecting to find the code again later will not.
///
/// A code to type rather than a link to click, and that is a decision
/// rather than a shortcut: a link carrying a credential ends up in a
/// browser history, in a referer header, and in the preview a chat app
/// fetches on the sender's behalf.
class _InvitationIssued extends StatelessWidget {
  const _InvitationIssued({required this.email, required this.token});

  final String email;
  final String? token;

  @override
  Widget build(BuildContext context) {
    final code = token;
    return AlertDialog(
      title: Text(hasCodeToGive(code) ? 'Invitation created' : 'Role changed'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(invitedOutcome(email: email, token: code)),
            if (hasCodeToGive(code)) ...[
              const SizedBox(height: Space.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: SelectableText(
                  code!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                'This is the only time it is shown. If it is lost, invite '
                'them again and a fresh code replaces this one.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (hasCodeToGive(code))
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code!));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Code copied')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
