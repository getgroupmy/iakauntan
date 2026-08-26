import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/reserved_names_repository.dart';

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
  const _Standing({required this.status, required this.address, this.note});

  final String status;
  final String address;
  final String? note;

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
            child: Text(
              line,
              style: TextStyle(
                fontWeight: status == 'approved'
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
            ),
          ),
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
                submit: (orgId, name) => ref
                    .read(reservedNamesProvider)
                    .requestSubdomain(orgId, name),
                onDone: () => ref.invalidate(orgSubdomainProvider),
              ),
          ],
        );
      },
    );
  }
}

class _Mailboxes extends ConsumerWidget {
  const _Mailboxes();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boxes = ref.watch(orgMailboxesProvider);

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
            'sales and support are two addresses doing two jobs.',
          ),
          for (final row in rows)
            _Standing(
              status: '${row['status']}',
              address: '${row['local_part']}@iakauntan.com',
              note: row['note'] as String?,
            ),
          _AskFor(
            scope: 'mailbox',
            label: 'Address you would like',
            suffix: '@iakauntan.com',
            submit: (orgId, name) =>
                ref.read(reservedNamesProvider).requestMailbox(orgId, name),
            onDone: () => ref.invalidate(orgMailboxesProvider),
          ),
        ],
      ),
    );
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
  });

  final String scope;
  final String label;
  final String suffix;
  final Future<void> Function(String orgId, String name) submit;
  final VoidCallback onDone;

  @override
  ConsumerState<_AskFor> createState() => _AskForState();
}

class _AskForState extends ConsumerState<_AskFor> {
  final _controller = TextEditingController();
  List<Map<String, dynamic>> _reserved = const [];
  String? _problem;
  bool _busy = false;

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
      await widget.submit(orgId, normalizeName(_controller.text));
      _controller.clear();
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
    return Padding(
      padding: const EdgeInsets.only(top: Space.md),
      child: Row(
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
      ),
    );
  }
}
