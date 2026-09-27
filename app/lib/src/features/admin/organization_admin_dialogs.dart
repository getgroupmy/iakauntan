import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// Making a company for somebody else. `0719`.
///
/// The owner is named by e-mail and has to exist already: a company
/// with no owner is a company nobody can open, and the database refuses
/// it. The message says to add the person first, which is why the Users
/// page is next door.
class NewOrganizationDialog extends ConsumerStatefulWidget {
  const NewOrganizationDialog({super.key});

  @override
  ConsumerState<NewOrganizationDialog> createState() =>
      _NewOrganizationDialogState();
}

class _NewOrganizationDialogState extends ConsumerState<NewOrganizationDialog> {
  final _owner = TextEditingController();
  final _name = TextEditingController();
  final _registration = TextEditingController();
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _owner.dispose();
    _name.dispose();
    _registration.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await ref.read(platformRepoProvider).platformCreateOrganization(
            ownerEmail: _owner.text.trim(),
            name: _name.text.trim(),
            registrationNo: _registration.text.trim(),
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _problem = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready =
        _owner.text.contains('@') && _name.text.trim().isNotEmpty && !_saving;

    return AlertDialog(
      title: const Text('Add a company'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('new-org-owner'),
              controller: _owner,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Owner’s e-mail',
                helperText: 'They have to be here already',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('new-org-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Company name'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('new-org-registration'),
              controller: _registration,
              decoration: const InputDecoration(
                labelText: 'Registration number',
                helperText: 'Optional; it can be filled in later',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'It arrives with a chart of accounts, tax codes, payment '
              'terms and a warehouse, exactly as one somebody signs up '
              'for does. You will not be a member of it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_problem != null) ...[
              const SizedBox(height: 12),
              Text(
                _problem!,
                key: const ValueKey('new-org-problem'),
                style: TextStyle(color: context.colors.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('new-org-save'),
          onPressed: ready ? _save : null,
          child: const Text('Create it'),
        ),
      ],
    );
  }
}

/// Editing a company's name and contact details. `0719`.
class EditOrganizationDialog extends ConsumerStatefulWidget {
  const EditOrganizationDialog({
    super.key,
    required this.orgId,
    required this.name,
    this.registrationNo,
  });

  final String orgId;
  final String name;
  final String? registrationNo;

  @override
  ConsumerState<EditOrganizationDialog> createState() =>
      _EditOrganizationDialogState();
}

class _EditOrganizationDialogState
    extends ConsumerState<EditOrganizationDialog> {
  late final _name = TextEditingController(text: widget.name);
  late final _registration =
      TextEditingController(text: widget.registrationNo ?? '');
  final _phone = TextEditingController();
  final _email = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _registration.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit this company'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('edit-org-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Company name'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('edit-org-registration'),
              controller: _registration,
              decoration:
                  const InputDecoration(labelText: 'Registration number'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('edit-org-phone'),
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('edit-org-email'),
              controller: _email,
              decoration: const InputDecoration(labelText: 'E-mail'),
            ),
            const SizedBox(height: 12),
            // Said out loud, because a box somebody clears expecting the
            // value to go and finds unchanged is a form that lied.
            Text(
              'A box left blank is left alone. Clearing one does not '
              'empty the field.',
              style: Theme.of(context).textTheme.bodySmall,
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
          key: const ValueKey('edit-org-save'),
          onPressed: () async {
            final ok = await runWithFeedback(
              context,
              doing: 'editing a company from the console',
              action: () =>
                  ref.read(platformRepoProvider).platformUpdateOrganization(
                        orgId: widget.orgId,
                        name: _name.text,
                        registrationNo: _registration.text,
                        phone: _phone.text,
                        email: _email.text,
                      ),
              successMessage: 'Saved',
            );
            if (ok && context.mounted) Navigator.pop(context, true);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Opening a support session over one company. `0719`.
///
/// The reason is required by the database, and the dialog says why
/// rather than just refusing: it is the whole difference between
/// support and a back door.
class GrantSupportDialog extends ConsumerStatefulWidget {
  const GrantSupportDialog({
    super.key,
    required this.orgId,
    required this.orgName,
  });

  final String orgId;
  final String orgName;

  @override
  ConsumerState<GrantSupportDialog> createState() => _GrantSupportDialogState();
}

class _GrantSupportDialogState extends ConsumerState<GrantSupportDialog> {
  final _reason = TextEditingController();
  int _minutes = 60;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Read ${widget.orgName}’s books'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('support-reason'),
              controller: _reason,
              autofocus: true,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Why',
                helperText: 'The customer will see this',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            Text('For how long',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                for (final m in const [15, 60, 240, 480])
                  ChoiceChip(
                    key: ValueKey('support-minutes-$m'),
                    label: Text(m < 60 ? '$m min' : '${m ~/ 60} h'),
                    selected: _minutes == m,
                    onSelected: (_) => setState(() => _minutes = m),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: context.scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You will be able to read everything and change '
                    'nothing. It ends on its own, it is written into '
                    'this company’s own audit trail, and they can '
                    'end it themselves.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
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
          key: const ValueKey('support-start'),
          onPressed: _reason.text.trim().isEmpty
              ? null
              : () async {
                  final ok = await runWithFeedback(
                    context,
                    doing: 'opening a support session',
                    action: () =>
                        ref.read(platformRepoProvider).grantSupportAccess(
                              orgId: widget.orgId,
                              reason: _reason.text.trim(),
                              minutes: _minutes,
                            ),
                    successMessage: 'You can read ${widget.orgName} now',
                  );
                  if (ok && context.mounted) Navigator.pop(context, true);
                },
          child: const Text('Start'),
        ),
      ],
    );
  }
}

/// Who can open one company, and the two things to do about it. `0720`.
class OrgMembersPanel extends ConsumerWidget {
  const OrgMembersPanel({
    super.key,
    required this.orgId,
    required this.orgName,
  });

  final String orgId;
  final String orgName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(platformOrgMembersProvider(orgId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AsyncView<List<Map<String, dynamic>>>(
          value: people,
          onRetry: () => ref.invalidate(platformOrgMembersProvider(orgId)),
          skeleton: const ListSkeleton(rows: 3, trailing: false),
          builder: (rows) => Column(
            children: [
              for (final m in rows)
                ListTile(
                  key: ValueKey('org-member-${m['user_id']}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('${m['full_name'] ?? m['email'] ?? ''}'),
                  subtitle: Text('${m['email'] ?? ''} · ${m['role']}'),
                  trailing: IconButton(
                    key: ValueKey('org-member-remove-${m['user_id']}'),
                    tooltip: 'Take their access away',
                    icon: const Icon(Icons.person_remove_outlined, size: 18),
                    onPressed: () async {
                      final ok = await runWithFeedback(
                        context,
                        doing: 'removing access from the console',
                        action: () => ref
                            .read(platformRepoProvider)
                            .platformRemoveOrgAccess(
                              orgId: orgId,
                              userId: '${m['user_id']}',
                            ),
                        successMessage: 'Removed',
                      );
                      if (ok) {
                        ref.invalidate(platformOrgMembersProvider(orgId));
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: ValueKey('org-member-add-$orgId'),
          onPressed: () async {
            final added = await showDialog<bool>(
              context: context,
              builder: (_) => AssignAccessDialog(orgId: orgId, orgName: orgName),
            );
            if (added == true) {
              ref.invalidate(platformOrgMembersProvider(orgId));
            }
          },
          icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
          label: const Text('Give somebody access'),
        ),
      ],
    );
  }
}

/// Giving somebody access to a company, or changing what they have.
///
/// One dialog for both, because the database upserts: "give somebody
/// access" and "change their role" are the same request arriving twice.
class AssignAccessDialog extends ConsumerStatefulWidget {
  const AssignAccessDialog({
    super.key,
    required this.orgId,
    required this.orgName,
  });

  final String orgId;
  final String orgName;

  @override
  ConsumerState<AssignAccessDialog> createState() => _AssignAccessDialogState();
}

class _AssignAccessDialogState extends ConsumerState<AssignAccessDialog> {
  final _email = TextEditingController();
  String _role = 'viewer';
  String? _problem;

  /// The roles, in the order this schema declares them, which runs from
  /// most able to least.
  static const roles = [
    'owner',
    'admin',
    'accountant',
    'hr_manager',
    'accounts_clerk',
    'auditor',
    'sales',
    'purchaser',
    'viewer',
    'employee',
  ];

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Give access to ${widget.orgName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('assign-email'),
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'E-mail',
                helperText: 'They have to be here already',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('assign-role'),
              initialValue: _role,
              // `dropdown_census_test.dart` requires it, and it is right:
              // without it a long item is drawn at its natural width and
              // overflows the field instead of ellipsising. This dialog
              // has already been caught once by that, which is why the
              // role names below are names.
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Role'),
              items: [
                for (final r in roles)
                  DropdownMenuItem(value: r, child: Text(niceRole(r))),
              ],
              onChanged: (v) => setState(() => _role = v ?? 'viewer'),
            ),
            const SizedBox(height: 6),
            Text(
              roleMeans(_role),
              key: const ValueKey('assign-role-means'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            Text(
              'This is permanent and it is the customer’s own access, '
              'not a support session. Somebody already here has their '
              'role changed rather than a second one made.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_problem != null) ...[
              const SizedBox(height: 12),
              Text(
                _problem!,
                key: const ValueKey('assign-problem'),
                style: TextStyle(color: context.colors.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('assign-save'),
          onPressed: _email.text.contains('@')
              ? () async {
                  setState(() => _problem = null);
                  try {
                    await ref
                        .read(platformRepoProvider)
                        .platformAssignOrgAccess(
                          orgId: widget.orgId,
                          email: _email.text.trim(),
                          role: _role,
                        );
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (mounted) setState(() => _problem = errorText(e));
                  }
                }
              : null,
          child: const Text('Give access'),
        ),
      ],
    );
  }
}

/// A role as a person reads it rather than as the enum spells it.
///
/// A NAME, and nothing more. What each one can do is [roleMeans], drawn
/// under the picker: the explanation used to be part of the name, and
/// "Auditor — reads everything, changes nothing" overflowed the dropdown
/// by 49 pixels, which Flutter draws as a striped bar over the text it
/// could not fit. `platform_people_test.dart` found it.
String niceRole(String code) => switch (code) {
      'owner' => 'Owner',
      'admin' => 'Administrator',
      'accountant' => 'Accountant',
      'hr_manager' => 'HR manager',
      'accounts_clerk' => 'Accounts clerk',
      'auditor' => 'Auditor',
      'sales' => 'Sales',
      'purchaser' => 'Purchaser',
      'viewer' => 'Viewer',
      'employee' => 'Employee',
      _ => code,
    };

/// What a role can do, in one line, read off the guards that decide it.
///
/// `app.can_write`, `can_post`, `can_admin`, `can_read_ledger`,
/// `can_manage_hr` and `can_run_payroll` are the whole of it, and each
/// names the roles it admits. Somebody in the console picking a role for
/// a customer's colleague should not have to read SQL to find out what
/// they just handed over.
String roleMeans(String code) => switch (code) {
      'owner' => 'Everything, and can close the company',
      'admin' => 'Everything, including who else can come in',
      'accountant' => 'Writes and posts to the ledger, and runs payroll',
      'hr_manager' => 'People and payroll, not the ledger',
      'accounts_clerk' => 'Writes to the books but cannot post',
      'auditor' => 'Reads the ledger and changes nothing',
      'sales' => 'Sales and customers; not the ledger',
      'purchaser' => 'Purchases and suppliers; not the ledger',
      'viewer' => 'Reads what is not the ledger',
      'employee' => 'Their own payslips, leave and claims',
      _ => 'An unknown role',
    };
