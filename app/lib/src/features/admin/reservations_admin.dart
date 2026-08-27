import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/reserved_names_repository.dart';
import '../landing/landing_content.dart';

/// Names companies have asked for on the platform's domain, and the
/// decision an operator has to make about each one.
///
/// The whole module rests on somebody looking at this list. There is
/// one `iakauntan.com`, and the blocklist only refuses what was
/// predictable — `sinar-teknologi` is fine and `lhdn-refunds` is not,
/// and no list was ever going to know that.
///
/// Two lists, pending above decided, because they are two different
/// jobs: the first is work waiting, the second is a record to check
/// against and occasionally take something back from.
class ReservationsAdminTab extends ConsumerWidget {
  const ReservationsAdminTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingReservationsProvider);

    return AsyncView(
      value: pending,
      onRetry: () => ref.invalidate(pendingReservationsProvider),
      builder: (waiting) => SingleChildScrollView(
        child: PageBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(
                'Waiting on you',
                subtitle: waiting.isEmpty
                    ? 'Nothing to decide'
                    : '${waiting.length} '
                        '${waiting.length == 1 ? 'request' : 'requests'}',
              ),
              if (waiting.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'Nothing waiting',
                  message: 'Names companies ask for appear here to be '
                      'approved or refused.',
                )
              else
                for (final row in waiting) _Pending(row: row),
              const SizedBox(height: 32),
              const SectionHeader(
                'Already decided',
                subtitle: 'What is live, and what was turned down',
              ),
              const _Decided(),
              const SizedBox(height: 32),
              const SectionHeader(
                'When the name is nobody\'s',
                subtitle: 'What a visitor sees at a name you have not '
                    'given out',
              ),
              const UnknownWorkspaceCopyCard(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a request is, spelled out.
///
/// The full address rather than the bare name: `lhdn` and
/// `lhdn.iakauntan.com` read differently, and the second is the thing
/// somebody is actually being asked to hand over.
String _address(Map<String, dynamic> row) => row['kind'] == 'subdomain'
    ? '${row['name']}.iakauntan.com'
    : '${row['name']}@iakauntan.com';

class _Pending extends ConsumerStatefulWidget {
  const _Pending({required this.row});

  final Map<String, dynamic> row;

  @override
  ConsumerState<_Pending> createState() => _PendingState();
}

class _PendingState extends ConsumerState<_Pending> {
  bool _busy = false;

  Future<void> _decide(bool approve) async {
    String? note;
    if (!approve) {
      // A refusal with no reason is a support ticket. The company that
      // asked sees this sentence and nothing else.
      note = await showDialog<String>(
        context: context,
        builder: (ctx) => const _ReasonDialog(),
      );
      if (note == null) return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(reservedNamesProvider).decide(
            kind: '${widget.row['kind']}',
            id: '${widget.row['id']}',
            approve: approve,
            note: note,
          );
      ref.invalidate(pendingReservationsProvider);
      ref.invalidate(decidedReservationsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is PostgrestException ? e.message : '$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(
          children: [
            Icon(
              row['kind'] == 'subdomain' ? Icons.language : Icons.alternate_email,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _address(row),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${row['org_name'] ?? 'Unknown company'} · asked '
                    '${Fmt.date(DateTime.tryParse('${row['requested_at']}'))}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (_busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              TextButton(
                onPressed: () => _decide(false),
                child: const Text('Refuse'),
              ),
              const SizedBox(width: Space.sm),
              FilledButton(
                onPressed: () => _decide(true),
                child: const Text('Approve'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Why are you refusing it?'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'The company that asked will see this',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Refuse it'),
        ),
      ],
    );
  }
}

class _Decided extends ConsumerWidget {
  const _Decided();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decided = ref.watch(decidedReservationsProvider);
    final colors = context.colors;

    return AsyncView(
      value: decided,
      onRetry: () => ref.invalidate(decidedReservationsProvider),
      loading: const LinearProgressIndicator(),
      builder: (rows) {
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.history,
            title: 'Nothing decided yet',
            message: 'Approved and refused names appear here.',
          );
        }
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final row in rows)
                ListTile(
                  leading: Icon(
                    row['status'] == 'approved'
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    color: row['status'] == 'approved'
                        ? colors.success
                        : colors.danger,
                  ),
                  title: Text(_address(row)),
                  subtitle: Text(
                    [
                      '${row['org_name'] ?? 'Unknown company'}',
                      if ((row['note'] as String?)?.isNotEmpty == true)
                        '${row['note']}',
                    ].join(' · '),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}


/// The copy shown at a subdomain nobody holds, and the form for it.
///
/// It lives on this screen rather than beside the rest of the landing
/// page copy because this is the screen an operator is on when they
/// think about subdomains at all. It is saved by
/// `platform_save_landing_page` all the same — it is one row of the
/// platform's front-door copy, and giving it a table of its own would
/// have bought nothing.
///
/// Every box may be left empty. Empty means "use what the product
/// ships with", which is why the fields say so rather than sitting
/// blank and unexplained: an operator who clears a box should know
/// they are restoring a default rather than deleting a page.
class UnknownWorkspaceCopyCard extends ConsumerStatefulWidget {
  const UnknownWorkspaceCopyCard({super.key});

  @override
  ConsumerState<UnknownWorkspaceCopyCard> createState() =>
      _UnknownWorkspaceCopyCardState();
}

class _UnknownWorkspaceCopyCardState
    extends ConsumerState<UnknownWorkspaceCopyCard> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _label = TextEditingController();
  final _url = TextEditingController();

  /// Filled once, from whatever the payload had. Not on every build:
  /// the provider refreshes and would otherwise take back what somebody
  /// is halfway through typing.
  bool _loaded = false;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _label.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).rpc(
        'platform_save_landing_page',
        params: {
          'p_patch': {
            'unknown_title': _title.text,
            'unknown_body': _body.text,
            'unknown_cta_label': _label.text,
            'unknown_cta_url': _url.text,
          },
        },
      );
      ref.invalidate(landingContentProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is PostgrestException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(landingContentProvider).valueOrNull;
    if (!_loaded && brand != null) {
      _title.text = brand.unknownTitle ?? '';
      _body.text = brand.unknownBody ?? '';
      _label.text = brand.unknownCtaLabel ?? '';
      _url.text = brand.unknownCtaUrl ?? '';
      _loaded = true;
    }

    return Card(
      key: const Key('unknown-workspace-copy'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              decoration: InputDecoration(
                labelText: 'Heading',
                hintText: LandingContent.defaultUnknownTitle,
                helperText: 'Empty uses the wording the product ships with',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _body,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'What it says',
                hintText: LandingContent.defaultUnknownBody,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              decoration: InputDecoration(
                labelText: 'Button',
                hintText: LandingContent.defaultUnknownCtaLabel,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Where the button goes',
                hintText: 'Empty sends them to the bare domain',
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
