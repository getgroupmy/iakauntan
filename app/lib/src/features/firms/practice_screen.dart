import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// The practice: who works at it, whose books it keeps, and what has
/// happened to it.
///
/// Almost nobody sees anything here. A company that keeps its own books
/// belongs to no firm, and `my_firms()` returns nothing for them — so
/// the screen opens on an explanation and one button rather than on an
/// empty table.
///
/// The thing worth understanding before reading any of this: **a client
/// is never inside the practice.** Appointing a firm writes ordinary
/// membership rows on the client company, carrying `via_firm_id` to say
/// where they came from. Nothing is copied, nothing is nested, and
/// ending the appointment removes exactly those rows. That is why a
/// company can be handed to another accountant without an export.
class PracticeScreen extends ConsumerWidget {
  const PracticeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firms = ref.watch(myFirmsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Practice')),
      body: AsyncView(
        value: firms,
        onRetry: () => ref.invalidate(myFirmsProvider),
        builder: (rows) {
          if (rows.isEmpty) return const _NoPractice();

          final selected = ref.watch(currentFirmIdProvider);
          final firm = rows.firstWhere(
            (f) => f['id'] == selected,
            orElse: () => rows.first,
          );
          final firmId = firm['id'] as String;

          return SingleChildScrollView(
            child: PageBody(
              maxWidth: 1000,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (rows.length > 1) ...[
                    _FirmPicker(firms: rows, current: firmId),
                    const SizedBox(height: 20),
                  ],
                  _ClientsCard(firmId: firmId),
                  const SizedBox(height: 24),
                  _PeopleCard(firmId: firmId),
                  const SizedBox(height: 24),
                  _TrailCard(firmId: firmId),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NoPractice extends ConsumerWidget {
  const _NoPractice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: Icons.apartment_outlined,
      title: 'You do not keep anybody else\'s books',
      message:
          'A practice is for an accounting firm with clients. Its staff '
          'get access to every client company at the role that client '
          'agreed to, and lose it the day they leave. Each client stays '
          'a company in its own right — with its own owner, its own '
          'ledger and its own subscription — and can be handed to '
          'another firm, or taken back in-house, without anything being '
          'exported.',
      action: FilledButton.icon(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _StartPracticeDialog(),
        ),
        icon: const Icon(Icons.add_business_outlined, size: 18),
        label: const Text('Start a practice'),
      ),
    );
  }
}

class _FirmPicker extends ConsumerWidget {
  const _FirmPicker({required this.firms, required this.current});

  final List<Map<String, dynamic>> firms;
  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: DropdownButtonFormField<String>(
          value: current,
          decoration: const InputDecoration(
            labelText: 'Practice',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final f in firms)
              DropdownMenuItem(
                value: f['id'] as String,
                child: Text('${f['name']}'),
              ),
          ],
          onChanged: (v) =>
              ref.read(currentFirmIdProvider.notifier).state = v,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// The client list
// ---------------------------------------------------------------------
class _ClientsCard extends ConsumerWidget {
  const _ClientsCard({required this.firmId});

  final String firmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final portfolio = ref.watch(firmPortfolioProvider(firmId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Clients',
          subtitle: 'Companies this practice keeps the books for',
          action: FilledButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _AppointDialog(firmId: firmId),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Take on a client'),
          ),
        ),
        AsyncView(
          value: portfolio,
          onRetry: () => ref.invalidate(firmPortfolioProvider(firmId)),
          builder: (rows) {
            if (rows.isEmpty) {
              return const Card(
                child: Padding(
                  padding: EdgeInsets.all(Space.lg),
                  child: Text(
                    'No clients yet. Taking one on needs you to '
                    'administer that company as well as belong to this '
                    'practice — handing books to a firm that has never '
                    'heard of you is not an appointment, so the client '
                    'side of it is done by the client.',
                  ),
                ),
              );
            }
            return Card(
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _ClientTile(row: rows[i]),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ClientTile extends ConsumerWidget {
  const _ClientTile({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = (row['unposted_documents'] as num?)?.toInt() ?? 0;
    final people = (row['people'] as num?)?.toInt() ?? 0;
    final last = DateTime.tryParse('${row['last_activity'] ?? ''}');

    return ListTile(
      title: Text('${row['name']}'),
      subtitle: Text(
        [
          '${row['member_role']}'.replaceAll('_', ' '),
          '$people ${people == 1 ? 'person' : 'people'}',
          if (last != null) 'last touched ${Fmt.date(last)}',
        ].join(' · '),
      ),
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (waiting > 0)
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text('$waiting unposted'),
            ),
          TextButton(
            onPressed: () {
              ref
                  .read(currentOrgIdProvider.notifier)
                  .select(row['org_id'] as String);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// The office
// ---------------------------------------------------------------------
class _PeopleCard extends ConsumerWidget {
  const _PeopleCard({required this.firmId});

  final String firmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final team = ref.watch(firmTeamProvider(firmId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'People',
          subtitle:
              'Everyone here reaches every client at the role that '
              'client agreed to',
          action: FilledButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => _InviteStaffDialog(firmId: firmId),
            ),
            icon: const Icon(Icons.person_add_alt, size: 18),
            label: const Text('Invite'),
          ),
        ),
        AsyncView(
          value: team,
          onRetry: () => ref.invalidate(firmTeamProvider(firmId)),
          builder: (rows) => Card(
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _StaffTile(firmId: firmId, row: rows[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StaffTile extends ConsumerWidget {
  const _StaffTile({required this.firmId, required this.row});

  final String firmId;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = '${row['full_name'] ?? row['email'] ?? '—'}';
    final status = '${row['status']}';

    return ListTile(
      title: Text(name),
      subtitle: Text('${row['role']} · $status'),
      trailing: IconButton(
        tooltip: 'Remove from the practice',
        icon: const Icon(Icons.person_remove_outlined, size: 18),
        onPressed: () async {
          final ok = await confirm(
            context,
            title: 'Remove $name?',
            message:
                'They lose access to every client of this practice at '
                'once. Anything a client invited them to directly is '
                'not affected.',
            confirmLabel: 'Remove',
            destructive: true,
          );
          if (!ok || !context.mounted) return;
          final client = ref.read(supabaseProvider);
          await runWithFeedback(
            context,
            doing: 'remove a member of the practice',
            successMessage: 'Removed',
            action: () async {
              await client
                  .from('firm_members')
                  .delete()
                  .eq('id', row['member_id'] as String);
            },
          );
          ref.invalidate(firmTeamProvider(firmId));
          ref.invalidate(firmPortfolioProvider(firmId));
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------
// The record
// ---------------------------------------------------------------------
class _TrailCard extends ConsumerWidget {
  const _TrailCard({required this.firmId});

  final String firmId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trail = ref.watch(firmTrailProvider(firmId));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'What has happened here',
          subtitle: 'Partners and managers only',
        ),
        trail.when(
          loading: () => const Card(
            child: Padding(
              padding: EdgeInsets.all(Space.lg),
              child: LinearProgressIndicator(),
            ),
          ),
          // A member of staff is refused this by the database rather
          // than shown an empty list, so the refusal is the answer and
          // not an error to retry.
          error: (_, _) => const Card(
            child: Padding(
              padding: EdgeInsets.all(Space.lg),
              child: Text(
                'Only a partner or manager of this practice may read '
                'its record.',
              ),
            ),
          ),
          data: (rows) => Card(
            child: Column(
              children: [
                if (rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(Space.lg),
                    child: Text('Nothing recorded yet.'),
                  ),
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    dense: true,
                    title: Text(_describe(rows[i])),
                    subtitle: Text(
                      '${rows[i]['who']} · '
                      '${Fmt.dateTime(DateTime.tryParse('${rows[i]['at']}'))}',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _describe(Map<String, dynamic> row) {
    final what = '${row['what']}';
    final action = '${row['action']}';
    if (what == 'firms') {
      return action == 'insert'
          ? 'The practice was started'
          : 'The practice\'s own details changed';
    }
    return switch (action) {
      'insert' => 'Somebody joined the practice',
      'delete' => 'Somebody left the practice',
      _ => 'Somebody\'s standing at the practice changed',
    };
  }
}

// ---------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------
class _StartPracticeDialog extends ConsumerStatefulWidget {
  const _StartPracticeDialog();

  @override
  ConsumerState<_StartPracticeDialog> createState() =>
      _StartPracticeDialogState();
}

class _StartPracticeDialogState extends ConsumerState<_StartPracticeDialog> {
  final _name = TextEditingController();
  final _reg = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _reg.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Start a practice'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name of the firm'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _reg,
              decoration: const InputDecoration(
                labelText: 'SSM registration number',
                hintText: 'Optional',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'E-mail'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Telephone'),
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
          onPressed: () async {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            final repo = ref.read(firmsRepoProvider);
            final ok = await runWithFeedback(
              context,
              doing: 'start a practice',
              successMessage: 'Practice started',
              action: () => repo.createFirm(
                name,
                registrationNo: _reg.text.trim().isEmpty
                    ? null
                    : _reg.text.trim(),
                email: _email.text.trim().isEmpty ? null : _email.text.trim(),
                phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
              ),
            );
            ref.invalidate(myFirmsProvider);
            if (ok && context.mounted) Navigator.pop(context);
          },
          child: const Text('Start'),
        ),
      ],
    );
  }
}

class _InviteStaffDialog extends ConsumerStatefulWidget {
  const _InviteStaffDialog({required this.firmId});

  final String firmId;

  @override
  ConsumerState<_InviteStaffDialog> createState() => _InviteStaffDialogState();
}

class _InviteStaffDialogState extends ConsumerState<_InviteStaffDialog> {
  final _email = TextEditingController();
  String _role = 'staff';

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Invite somebody to the practice'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _email,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'E-mail'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _role,
              decoration: const InputDecoration(labelText: 'Role here'),
              items: const [
                DropdownMenuItem(
                  value: 'partner',
                  child: Text('Partner — may do anything, including invite'),
                ),
                DropdownMenuItem(
                  value: 'manager',
                  child: Text('Manager — may invite and read the record'),
                ),
                DropdownMenuItem(
                  value: 'staff',
                  child: Text('Staff — works on the clients'),
                ),
              ],
              onChanged: (v) => setState(() => _role = v ?? 'staff'),
            ),
            const SizedBox(height: 12),
            Text(
              'Somebody who already has an account joins immediately and '
              'gets every client of this practice. Somebody who does not '
              'is invited, and gets them when they register.',
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
          onPressed: () async {
            final email = _email.text.trim();
            if (email.isEmpty) return;
            final repo = ref.read(firmsRepoProvider);
            final ok = await runWithFeedback(
              context,
              doing: 'invite somebody to a practice',
              successMessage: 'Invited',
              action: () => repo.invite(widget.firmId, email, _role),
            );
            ref.invalidate(firmTeamProvider(widget.firmId));
            if (ok && context.mounted) Navigator.pop(context);
          },
          child: const Text('Invite'),
        ),
      ],
    );
  }
}

/// Appointing the practice on a company the caller administers.
///
/// The list is the caller's own companies, because that is exactly the
/// set the database will accept: `attach_company_to_firm` wants
/// `can_admin` on the company *and* membership of the firm.
class _AppointDialog extends ConsumerStatefulWidget {
  const _AppointDialog({required this.firmId});

  final String firmId;

  @override
  ConsumerState<_AppointDialog> createState() => _AppointDialogState();
}

class _AppointDialogState extends ConsumerState<_AppointDialog> {
  String? _orgId;
  String _role = 'accountant';

  @override
  Widget build(BuildContext context) {
    final orgs = ref.watch(organizationsProvider);

    return AlertDialog(
      title: const Text('Take on a client'),
      content: SizedBox(
        width: 460,
        child: orgs.when(
          loading: () => const SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('$e'),
          data: (list) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _orgId,
                decoration: const InputDecoration(labelText: 'Company'),
                items: [
                  for (final o in list)
                    DropdownMenuItem(value: o.id, child: Text(o.name)),
                ],
                onChanged: (v) => setState(() => _orgId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _role,
                decoration: const InputDecoration(
                  labelText: 'What the practice may do here',
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'admin',
                    child: Text('Administrator'),
                  ),
                  DropdownMenuItem(
                    value: 'accountant',
                    child: Text('Accountant'),
                  ),
                  DropdownMenuItem(
                    value: 'accounts_clerk',
                    child: Text('Accounts clerk'),
                  ),
                  DropdownMenuItem(value: 'auditor', child: Text('Auditor')),
                ],
                onChanged: (v) => setState(() => _role = v ?? 'accountant'),
              ),
              const SizedBox(height: 12),
              Text(
                'Never owner. A practice keeps books; it does not become '
                'the company through the door marked bookkeeping — the '
                'database refuses that outright.',
                style: Theme.of(context).textTheme.bodySmall,
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
          onPressed: () async {
            final orgId = _orgId;
            if (orgId == null) return;
            final repo = ref.read(firmsRepoProvider);
            final ok = await runWithFeedback(
              context,
              doing: 'appoint a practice',
              successMessage: 'Taken on',
              action: () => repo.attach(orgId, widget.firmId, _role),
            );
            ref.invalidate(firmPortfolioProvider(widget.firmId));
            if (ok && context.mounted) Navigator.pop(context);
          },
          child: const Text('Take on'),
        ),
      ],
    );
  }
}
