import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/reserved_names_repository.dart';
import '../../core/searchable_picker.dart';
import 'mailbox_owners.dart';

/// The two names a company can reserve on the platform's domain.
///
/// One card rather than two, because they are the same act twice — ask
/// for a name, wait for somebody to look at it — and a company that
/// holds both modules should see one place where its names live rather
/// than two cards saying nearly the same thing.
///
/// Each half appears only for a company that has bought that module, so
/// a company with the address and not the door sees the address alone.
class AddressesCard extends ConsumerWidget {
  const AddressesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wantsDoor = moduleEnabled(ref, 'workspace_address');
    final wantsMail = moduleEnabled(ref, 'mailbox');
    if (!wantsDoor && !wantsMail) return const SizedBox.shrink();

    // The gap below is the card's own, so a company holding neither
    // module leaves no hole where it would have been.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                'Your names on our domain',
                subtitle:
                    'Asked for here, switched on once we have checked '
                    'the name is free and fair',
              ),
              if (wantsDoor) const _Subdomain(),
              if (wantsDoor && wantsMail) const Divider(height: Space.xl),
              if (wantsMail) const _Mailboxes(),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line saying where a request has got to.
///
/// The three states are the three sentences somebody actually wants:
/// it is live and here is the address, somebody is looking at it, or it
/// was refused and here is why.
class _Standing extends StatelessWidget {
  const _Standing({
    required this.status,
    required this.address,
    this.note,
    this.owner,
    this.trailing,
  });

  final String status;
  final String address;
  final String? note;

  /// Whose it is, for a mailbox. Null on a subdomain, which belongs to
  /// the company by definition.
  final String? owner;

  /// The button that moves it, where the person looking may move it.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.colors;

    final (icon, colour, line) = switch (status) {
      'approved' => (Icons.check_circle_outline, colors.success, address),
      'refused' => (
        Icons.cancel_outlined,
        colors.danger,
        note?.isNotEmpty == true
            ? '$address was refused: $note'
            : '$address was refused',
      ),
      _ => (
        Icons.hourglass_empty,
        scheme.onSurfaceVariant,
        '$address is with us; we will tell you when it is decided',
      ),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line,
                  style: TextStyle(
                    fontWeight: status == 'approved'
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                // Said on every mailbox, not only the personal ones.
                // "Shared with the company" is the fact somebody needs
                // before they write to a customer from it, and a line
                // that appears only sometimes is one nobody learns to
                // look for.
                if (owner != null)
                  Text(
                    owner!,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _Subdomain extends ConsumerWidget {
  const _Subdomain();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final standing = ref.watch(orgSubdomainProvider);

    return AsyncView(
      value: standing,
      onRetry: () => ref.invalidate(orgSubdomainProvider),
      loading: const LinearProgressIndicator(),
      builder: (row) {
        final status = row?['status'] as String?;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Web address',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Sign in at your own name, on a page with your logo on it.',
            ),
            if (row != null)
              _Standing(
                status: status ?? 'requested',
                address: '${row['subdomain']}.iakauntan.com',
                note: row['note'] as String?,
              ),
            // A live address is not changed from a form. It is a door
            // people are walking through, and swapping it is a
            // conversation rather than a submission.
            if (status != 'approved')
              _AskFor(
                scope: 'subdomain',
                label: 'Name you would like',
                suffix: '.iakauntan.com',
                // A subdomain belongs to the company by definition, so
                // the owner the mailbox form asks for is ignored here.
                submit: (orgId, name, _) => ref
                    .read(reservedNamesProvider)
                    .requestSubdomain(orgId, name),
                onDone: () => ref.invalidate(orgSubdomainProvider),
              ),
            // And once it is live, the words on it. Here rather than in
            // a screen of its own because it is the same subject: the
            // address, and what it says when somebody arrives at it.
            // A company with no address yet has nothing to write on.
            if (status == 'approved') const _DoorWords(),
          ],
        );
      },
    );
  }
}

/// What a company writes over its own sign-in page.
///
/// `0348` gave workspace addresses their own page of copy and `0349`
/// gave it to the company. The platform's version is a sentence written
/// for every tenant at once, which is to say a generic one; this is the
/// company saying something true about itself to its own staff.
///
/// Two boxes and no publish switch. The three pages the footer links to
/// are gated on publication because a half-written privacy policy is
/// worse than none; a heading is not that kind of document, and a draft
/// state here would only be a way to have typed something and not see
/// it.
///
/// Empty is not blank. Clearing a box restores the platform's wording
/// rather than rendering a blank line above the form, which is what the
/// saver's `nullif(btrim(...), '')` is for.
class _DoorWords extends ConsumerStatefulWidget {
  const _DoorWords();

  @override
  ConsumerState<_DoorWords> createState() => _DoorWordsState();
}

class _DoorWordsState extends ConsumerState<_DoorWords> {
  final _title = TextEditingController();
  final _body = TextEditingController();

  /// Filled once, not on every rebuild.
  ///
  /// A save invalidates the provider, the provider rebuilds this
  /// widget, and refilling the boxes from the row at that point throws
  /// away whatever has been typed since. The same rule the console's
  /// page editor keeps, and for the same reason.
  bool _loaded = false;
  bool _busy = false;
  String? _error;
  String? _saved;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _saved = null;
    });
    try {
      await ref
          .read(supabaseProvider)
          .rpc(
            'org_save_login_page',
            params: {
              'p_org_id': orgId,
              'p_title': _title.text,
              'p_body': _body.text,
            },
          );
      ref.invalidate(orgLoginPageProvider);
      if (mounted) setState(() => _saved = 'Saved.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only somebody who speaks for the company. The function refuses
    // anybody else anyway — this is so a clerk is not shown a form that
    // will not take.
    if (!ref.watch(canAdminProvider)) return const SizedBox.shrink();

    final page = ref.watch(orgLoginPageProvider);
    if (page.hasValue && !_loaded) {
      _loaded = true;
      _title.text = (page.value?['title'] as String?) ?? '';
      _body.text = (page.value?['body'] as String?) ?? '';
    }

    return Padding(
      padding: const EdgeInsets.only(top: Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Words on your sign-in page',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'What your staff read when they arrive at your address. '
            'Leave a box empty to use ours.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Heading',
              hintText: 'Welcome back',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            enabled: !_busy,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Line under it',
              // The company's name is put after this by the screen, so
              // what is typed here is the half that is theirs to
              // decide — the same bargain the platform's own copy makes.
              hintText: 'Sign in to continue to',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_saved != null) ...[
            const SizedBox(height: 8),
            Text(_saved!, style: TextStyle(color: context.colors.success)),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Mailboxes extends ConsumerWidget {
  const _Mailboxes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boxes = ref.watch(orgMailboxesProvider);
    // `0560` made the domain askable rather than a literal, and this
    // screen was writing it out in two more places.
    final domain = ref.watch(mailDomainProvider).valueOrNull ?? 'iakauntan.com';
    final team = ref.watch(teamProvider).valueOrNull ?? const <TeamMember>[];
    final names = namesById(team);

    return AsyncView(
      value: boxes,
      onRetry: () => ref.invalidate(orgMailboxesProvider),
      loading: const LinearProgressIndicator(),
      builder: (rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Email address',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Send and receive at your own name. More than one is fine — '
            'sales and support are two addresses doing two jobs, and an '
            'address for one person is read by them and nobody else.',
          ),
          for (final row in rows)
            _Standing(
              status: '${row['status']}',
              address: '${row['local_part']}@$domain',
              note: row['note'] as String?,
              owner: mailboxOwnerLabel(row, names),
              trailing: TextButton(
                onPressed: () => _move(context, ref, row, team),
                child: Text(handOverLabel(row)),
              ),
            ),
          _AskFor(
            scope: 'mailbox',
            label: 'Address you would like',
            suffix: '@$domain',
            owners: mailboxOwnerCandidates(team),
            submit: (orgId, name, ownerId) => ref
                .read(reservedNamesProvider)
                .requestMailbox(orgId, name, ownerId: ownerId),
            onDone: () => ref.invalidate(orgMailboxesProvider),
          ),
        ],
      ),
    );
  }

  /// Hand an address to somebody, or give it back to the company.
  ///
  /// The door an administrator has instead of reading somebody's mail.
  /// It is refused for anybody who is not one, by `assign_mailbox` and
  /// not by this screen — the button is drawn for everybody and the
  /// refusal is shown, because hiding it would leave an owner wondering
  /// why their own address cannot be moved.
  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> row,
    List<TeamMember> team,
  ) async {
    final moved = await showDialog<bool>(
      context: context,
      builder: (_) => _HandOver(row: row, team: team),
    );
    if (moved == true) ref.invalidate(orgMailboxesProvider);
  }
}

/// The form itself: a field that refuses a bad name before it is sent.
///
/// The refusal is a copy of the database's, and the database refuses
/// again whatever this says. What it buys is being told while you are
/// still typing rather than after a round trip.
class _AskFor extends ConsumerStatefulWidget {
  const _AskFor({
    required this.scope,
    required this.label,
    required this.suffix,
    required this.submit,
    required this.onDone,
    this.owners = const [],
  });

  final String scope;
  final String label;
  final String suffix;
  final Future<void> Function(String orgId, String name, String? ownerId)
  submit;
  final VoidCallback onDone;

  /// The people this address could belong to. Empty for a subdomain,
  /// which belongs to the company by definition.
  final List<TeamMember> owners;

  @override
  ConsumerState<_AskFor> createState() => _AskForState();
}

class _AskForState extends ConsumerState<_AskFor> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _reserved = const [];
  String? _problem;
  bool _busy = false;

  /// Null is the company's own address, which is what `sales@` and
  /// `support@` are and what every address was before `0559`.
  String? _ownerId;

  @override
  void initState() {
    super.initState();
    // Read once and kept: the blocklist changes about as often as a
    // deploy, and re-reading it on every keystroke would be a request
    // per character.
    ref
        .read(reservedNamesProvider)
        .reserved()
        .then((rows) => mounted ? setState(() => _reserved = rows) : null)
        .catchError((_) => null);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final orgId = ref.read(currentOrgIdProvider);
    if (orgId == null) return;

    final problem = checkName(
      _controller.text,
      scope: widget.scope,
      reserved: _reserved,
    );
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }

    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.submit(orgId, normalizeName(_controller.text), _ownerId);
      _controller.clear();
      setState(() => _ownerId = null);
      widget.onDone();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Asked for. We will look at it.')),
        );
      }
    } catch (e) {
      // The database's own sentence, which is the one worth showing:
      // it knows about names taken since this screen loaded.
      if (mounted) {
        setState(() => _problem = e is PostgrestException ? e.message : '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final field = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: !_busy,
            decoration: InputDecoration(
              labelText: widget.label,
              suffixText: widget.suffix,
              errorText: _problem,
              helperText: 'Letters, digits and hyphens',
            ),
            onChanged: (_) {
              if (_problem != null) setState(() => _problem = null);
            },
            onSubmitted: (_) => _busy ? null : _send(),
          ),
        ),
        const SizedBox(width: Space.md),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FilledButton(
            onPressed: _busy ? null : _send,
            child: const Text('Ask for it'),
          ),
        ),
      ],
    );

    if (widget.owners.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: Space.md),
        child: field,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          const SizedBox(height: Space.md),
          // Asked here rather than afterwards, and that is `0559`'s
          // reasoning rather than a layout choice: an approved mailbox
          // with nobody on it is one everybody in the company can read
          // until somebody remembers to assign it.
          SearchablePicker<String>(
            label: 'Whose address is this?',
            value: _ownerId,
            allowEmpty: true,
            emptyLabel: 'The company — anybody here can read it',
            enabled: !_busy,
            options: [
              for (final m in widget.owners)
                PickerOption(
                  value: m.userId!,
                  label: memberLabel(m),
                  sublabel: 'Only they can read it',
                  keywords: [if (m.email != null) m.email!],
                ),
            ],
            onChanged: (v) => setState(() => _ownerId = v),
          ),
        ],
      ),
    );
  }
}

/// Moving an address to somebody, or back to the company.
///
/// A dialog rather than a menu, because one of the two directions is
/// not reversible in the way people assume: giving a personal mailbox
/// back to the company makes every message already in it readable by
/// every member, and that is worth a sentence and a second press.
class _HandOver extends ConsumerStatefulWidget {
  const _HandOver({required this.row, required this.team});

  final Map<String, dynamic> row;
  final List<TeamMember> team;

  @override
  ConsumerState<_HandOver> createState() => _HandOverState();
}

class _HandOverState extends ConsumerState<_HandOver> {
  late String? _ownerId = widget.row['owner_id'] as String?;
  bool _busy = false;
  String? _problem;

  @override
  Widget build(BuildContext context) {
    final candidates = mailboxOwnerCandidates(widget.team);

    return AlertDialog(
      title: Text('${widget.row['local_part']}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SearchablePicker<String>(
              label: 'Whose address is this?',
              value: _ownerId,
              allowEmpty: true,
              emptyLabel: 'The company — anybody here can read it',
              enabled: !_busy,
              options: [
                for (final m in candidates)
                  PickerOption(
                    value: m.userId!,
                    label: memberLabel(m),
                    sublabel: 'Only they can read it',
                    keywords: [if (m.email != null) m.email!],
                  ),
              ],
              onChanged: (v) => setState(() => _ownerId = v),
            ),
            const SizedBox(height: Space.md),
            Text(
              handOverWarning(_ownerId),
              style: TextStyle(
                fontSize: 12,
                color: context.scheme.onSurfaceVariant,
              ),
            ),
            if (_problem != null) ...[
              const SizedBox(height: Space.md),
              Text(_problem!, style: TextStyle(color: context.colors.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Moving…' : 'Move it'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await ref
          .read(reservedNamesProvider)
          .assignMailbox('${widget.row['id']}', _ownerId);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // `assign_mailbox` refuses anybody who is not an owner or
      // administrator, and says so in words written to be read.
      if (mounted) {
        setState(() {
          _busy = false;
          _problem = e is PostgrestException ? e.message : '$e';
        });
      }
    }
  }
}
