import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/skeletons.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The people on this platform. `0721`.
///
/// Three of the things this page does are not SQL — creating an
/// account, setting a password, suspending one — because they live in
/// `auth.users` and the only supported way to write them is the Admin
/// API with the service role key. That key is in the `platform-users`
/// edge function and nowhere else. The page cannot tell the difference
/// and should not: both arrive through `platformRepoProvider`.
class UsersAdminTab extends ConsumerStatefulWidget {
  const UsersAdminTab({super.key});

  @override
  ConsumerState<UsersAdminTab> createState() => _UsersAdminTabState();
}

class _UsersAdminTabState extends ConsumerState<UsersAdminTab> {
  final _search = TextEditingController();

  /// What the list is filtered by, which is NOT what is in the box: the
  /// box changes on every keystroke and each change is a round trip.
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final made = await showDialog<bool>(
      context: context,
      builder: (_) => const _NewUserDialog(),
    );
    if (made == true) ref.invalidate(platformUsersProvider(_query));
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(platformUsersProvider(_query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('users-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Name or e-mail',
                    helperText: 'Leave it empty for everybody',
                  ),
                  // On submit, not on every keystroke: each change is a
                  // round trip, and a directory of every user on the
                  // platform is not something to fetch six times while
                  // somebody types a surname.
                  onSubmitted: (v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: Space.md),
              FilledButton.icon(
                key: const ValueKey('users-add'),
                onPressed: _create,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: const Text('Add a person'),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncView<List<Map<String, dynamic>>>(
            value: people,
            onRetry: () => ref.invalidate(platformUsersProvider(_query)),
            skeleton: const ListSkeleton(rows: 8),
            builder: (rows) {
              if (rows.isEmpty) {
                return EmptyState(
                  icon: Icons.people_outline,
                  title: _query.isEmpty
                      ? 'Nobody here yet'
                      : 'Nobody matches that',
                  message: _query.isEmpty
                      ? 'People appear here as they register, and '
                          'when you add one.'
                      : 'Try part of a name, or the whole e-mail address.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(Space.lg),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => _PersonTile(
                  person: rows[i],
                  onChanged: () =>
                      ref.invalidate(platformUsersProvider(_query)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PersonTile extends ConsumerWidget {
  const _PersonTile({required this.person, required this.onChanged});

  final Map<String, dynamic> person;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = '${person['full_name'] ?? ''}'.trim();
    final email = '${person['email'] ?? ''}';
    final companies = (person['company_count'] as num?)?.toInt() ?? 0;
    final suspended = person['suspended'] == true;
    final staff = person['is_platform_admin'] == true;
    final seen = Fmt.parseDate(person['last_sign_in_at']);

    return ListTile(
      key: ValueKey('user-${person['user_id']}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: suspended
            ? context.colors.danger.withValues(alpha: 0.12)
            : null,
        child: Icon(
          suspended ? Icons.block : Icons.person_outline,
          size: 20,
          color: suspended ? context.colors.danger : null,
        ),
      ),
      title: Row(
        children: [
          Flexible(child: Text(name.isEmpty ? email : name)),
          if (staff) ...[
            const SizedBox(width: 8),
            const _Tag('Platform'),
          ],
          if (suspended) ...[
            const SizedBox(width: 8),
            const _Tag('Suspended', danger: true),
          ],
        ],
      ),
      subtitle: Text(
        [
          if (name.isNotEmpty) email,
          companies == 1 ? '1 company' : '$companies companies',
          // Somebody who has never signed in is a different problem from
          // somebody who signed in last March, and "—" says neither.
          seen == null ? 'never signed in' : 'last seen ${Fmt.date(seen)}',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (_) => _PersonSheet(person: person),
        );
        onChanged();
      },
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.danger = false});

  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final colour = danger ? context.colors.danger : context.scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: colour, height: 1.2),
      ),
    );
  }
}

/// Creating an account with a password the administrator sets.
///
/// Asked for that way rather than as an invitation — faster for
/// onboarding somebody over the phone, and it means an administrator
/// has briefly known their credentials. The dialog says so, because
/// somebody typing another person's password should be aware they are
/// doing it.
class _NewUserDialog extends ConsumerStatefulWidget {
  const _NewUserDialog();

  @override
  ConsumerState<_NewUserDialog> createState() => _NewUserDialogState();
}

class _NewUserDialogState extends ConsumerState<_NewUserDialog> {
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await ref.read(platformRepoProvider).platformCreateUser(
            email: _email.text.trim(),
            password: _password.text,
            fullName: _name.text.trim(),
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // Shown IN THE DIALOG rather than as a snackbar behind it: "A
      // user with this email address has already been registered" is
      // about the box above it, and a message that outlives the form
      // it belongs to is a message nobody connects to anything.
      if (mounted) setState(() => _problem = errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _email.text.contains('@') && _password.text.length >= 10;

    return AlertDialog(
      title: const Text('Add a person'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('new-user-email'),
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'E-mail',
                helperText: 'This is what they sign in with',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('new-user-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('new-user-password'),
              controller: _password,
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'At least 10 characters',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: context.scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'You are setting somebody else’s password, so you '
                    'will know it. Tell them to change it, and the '
                    'account is confirmed straight away — there is no '
                    'e-mail to wait for.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            if (_problem != null) ...[
              const SizedBox(height: 12),
              Text(
                _problem!,
                key: const ValueKey('new-user-problem'),
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
          key: const ValueKey('new-user-save'),
          onPressed: ready && !_saving ? _save : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// One person: what is theirs, which companies they can open, and the
/// three things only the edge function can do.
class _PersonSheet extends ConsumerStatefulWidget {
  const _PersonSheet({required this.person});

  final Map<String, dynamic> person;

  @override
  ConsumerState<_PersonSheet> createState() => _PersonSheetState();
}

class _PersonSheetState extends ConsumerState<_PersonSheet> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.person['full_name'] ?? ''}',
  );
  late final TextEditingController _phone = TextEditingController(
    text: '${widget.person['phone'] ?? ''}',
  );
  bool _busy = false;

  String get _id => '${widget.person['user_id']}';
  String get _email => '${widget.person['email'] ?? ''}';

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String said) async {
    setState(() => _busy = true);
    await runWithFeedback(
      context,
      doing: 'changing a person from the console',
      action: action,
      successMessage: said,
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setPassword() async {
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
    if (typed == null || !mounted) return;
    await _run(
      () => ref
          .read(platformRepoProvider)
          .platformSetPassword(userId: _id, password: typed),
      'Password set',
    );
  }

  Future<void> _toggleSuspended() async {
    final suspended = widget.person['suspended'] == true;
    if (!suspended) {
      final sure = await confirm(
        context,
        title: 'Suspend this person?',
        message: 'They will not be able to sign in. Their companies and '
            'everything in them are untouched, and you can let them '
            'back in at any time.',
        confirmLabel: 'Suspend',
      );
      if (!sure || !mounted) return;
    }
    await _run(
      () => ref
          .read(platformRepoProvider)
          .platformSetSuspended(userId: _id, suspended: !suspended),
      suspended ? 'Let back in' : 'Suspended',
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final orgs = ref.watch(platformUserOrgsProvider(_id));
    final suspended = widget.person['suspended'] == true;

    return AlertDialog(
      title: Text(_email),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('person-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('person-phone'),
                controller: _phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const ValueKey('person-save'),
                  onPressed: _busy
                      ? null
                      : () => _run(
                            () => ref
                                .read(platformRepoProvider)
                                .platformUpdateUser(
                                  userId: _id,
                                  fullName: _name.text,
                                  phone: _phone.text,
                                ),
                            'Saved',
                          ),
                  child: const Text('Save details'),
                ),
              ),
              const Divider(height: 24),
              const SectionHeader(
                'Companies',
                subtitle: 'What this person can open, and as what.',
              ),
              AsyncView<List<Map<String, dynamic>>>(
                value: orgs,
                onRetry: () => ref.invalidate(platformUserOrgsProvider(_id)),
                skeleton: const ListSkeleton(rows: 2, trailing: false),
                builder: (rows) => rows.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'No companies. Give them one from the '
                          'Organizations page.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      )
                    : Column(
                        children: [
                          for (final o in rows)
                            ListTile(
                              key: ValueKey('person-org-${o['org_id']}'),
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text('${o['org_name']}'),
                              subtitle: Text(
                                '${o['role']}'
                                '${o['is_demo'] == true ? ' · demo' : ''}',
                              ),
                              trailing: IconButton(
                                key: ValueKey(
                                    'person-org-remove-${o['org_id']}'),
                                tooltip: 'Take this company away',
                                icon: const Icon(Icons.link_off, size: 18),
                                onPressed: _busy
                                    ? null
                                    : () async {
                                        await _run(
                                          () => ref
                                              .read(platformRepoProvider)
                                              .platformRemoveOrgAccess(
                                                orgId: '${o['org_id']}',
                                                userId: _id,
                                              ),
                                          'Removed',
                                        );
                                        ref.invalidate(
                                            platformUserOrgsProvider(_id));
                                      },
                              ),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 24),
              // The two that are not SQL, kept together and last so
              // they read as what they are.
              Wrap(
                spacing: Space.sm,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('person-password'),
                    onPressed: _busy ? null : _setPassword,
                    icon: const Icon(Icons.key_outlined, size: 18),
                    label: const Text('Set a password'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('person-suspend'),
                    onPressed: _busy ? null : _toggleSuspended,
                    icon: Icon(
                      suspended ? Icons.lock_open_outlined : Icons.block,
                      size: 18,
                    ),
                    label: Text(suspended ? 'Let back in' : 'Suspend'),
                  ),
                ],
              ),
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

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set a password'),
      content: SizedBox(
        width: 380,
        child: TextField(
          key: const ValueKey('set-password-field'),
          controller: _password,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New password',
            helperText: 'At least 10 characters. They can change it after.',
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('set-password-save'),
          onPressed: _password.text.length >= 10
              ? () => Navigator.pop(context, _password.text)
              : null,
          child: const Text('Set it'),
        ),
      ],
    );
  }
}
