import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/ssm_repository.dart';
import 'ssm_query_hints.dart';

/// Choosing a company out of SSM's register.
///
/// Opened from the contact editor and from the "create this supplier"
/// dialog a scan leads to. Both are moments where somebody is about to
/// commit a name and a registration number to a permanent record that
/// an e-Invoice will be validated against, and both of them, until
/// this existed, had nothing to check the number against except the
/// paper in front of them.
///
/// Returns the chosen entity, or null when nothing was chosen. It does
/// NOT write anything: what the caller does with a match differs — the
/// contact editor fills its fields so the person can still change their
/// mind before saving, and an existing contact is stamped through
/// `set_contact_ssm_entity`. Deciding that here would be deciding it in
/// the wrong place.
Future<SsmEntity?> showSsmEntityPicker(
  BuildContext context, {
  String? initialQuery,
}) {
  return showDialog<SsmEntity>(
    context: context,
    builder: (_) => _SsmEntityPicker(initialQuery: initialQuery),
  );
}

class _SsmEntityPicker extends ConsumerStatefulWidget {
  const _SsmEntityPicker({this.initialQuery});

  /// What to search on opening. The caller knows more than this dialog
  /// does — a name already typed, or `SsmQueryHints.bestQuery` over
  /// what a reader saw — and making somebody retype it would be work
  /// the machine should have done.
  final String? initialQuery;

  @override
  ConsumerState<_SsmEntityPicker> createState() => _SsmEntityPickerState();
}

class _SsmEntityPickerState extends ConsumerState<_SsmEntityPicker> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery?.trim() ?? '',
  );

  /// The type filter. Null is every kind, which is the right default:
  /// a bill from a sole proprietorship and one from a Sdn Bhd look the
  /// same on the letterhead.
  int? _typeId;
  List<SsmEntityType> _types = const [];

  SsmSearchPage? _page;
  SsmLookupException? _error;
  bool _busy = false;

  /// Whether a search has been run at all. An empty result and a dialog
  /// nobody has searched in yet look identical otherwise.
  bool _searched = false;

  /// Searching as the person types, once there is enough to search on.
  ///
  /// The pause matters more here than usual: every distinct query that
  /// is not already cached is a real search against ssmsearch.com, and
  /// `docs/ssm-lookup.md` asks for that volume to stay modest. Half a
  /// second of quiet turns "Kabeer Holdings" into one or two searches
  /// rather than twelve. Enter and the search button still search at
  /// once.
  Timer? _debounce;
  static const _pause = Duration(milliseconds: 500);

  /// Which search is the current one. A slow answer to "Kab" must not
  /// land on top of the results for "Kabeer Hol".
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTypes());
    if (_query.text.trim().length >= 3) unawaited(_run());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadTypes() async {
    try {
      final types = await ref.read(ssmLookupProvider).entityTypes();
      if (mounted) setState(() => _types = types);
    } on SsmLookupException {
      // The filter is a convenience and the search works without it.
      // A dialog that refuses to open because a reference table did
      // not load would be worse than one with no filter in it.
    }
  }

  /// Every keystroke lands here. Under three characters there is
  /// nothing to search on (the function refuses it too), so a pending
  /// search is dropped and the dialog goes back to its opening state;
  /// from three on, a search is queued for when the typing pauses.
  void _onChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 3) {
      // The helper text under the field reads it, so rebuild anyway.
      setState(() {
        if (_searched) {
          _page = null;
          _error = null;
          _searched = false;
        }
      });
      return;
    }
    setState(() {});
    _debounce = Timer(_pause, () {
      if (mounted) unawaited(_run());
    });
  }

  Future<void> _run({int page = 1}) async {
    _debounce?.cancel();
    final q = _query.text.trim();
    if (q.length < 3) {
      setState(() {
        _searched = true;
        _error = const SsmLookupException(
          'QUERY_TOO_SHORT',
          'Type at least three characters.',
          status: 400,
        );
        _page = null;
      });
      return;
    }

    final mine = ++_seq;
    setState(() {
      _busy = true;
      _error = null;
      _searched = true;
    });
    try {
      final result = await ref
          .read(ssmLookupProvider)
          .search(q, typeId: _typeId, page: page);
      if (mounted && mine == _seq) setState(() => _page = result);
    } on SsmLookupException catch (e) {
      if (mounted && mine == _seq) setState(() => _error = e);
    } finally {
      if (mounted && mine == _seq) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Look up in the SSM register'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('ssm-query'),
              controller: _query,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (_) => _run(),
              decoration: InputDecoration(
                labelText: 'Name or registration number',
                helperText: SsmQueryHints.looksLikeRegNo(_query.text)
                    ? 'A registration number matches one company exactly'
                    : 'The registered name, not the trading name',
                suffixIcon: IconButton(
                  key: const ValueKey('ssm-search'),
                  tooltip: 'Search',
                  icon: const Icon(Icons.search),
                  onPressed: _busy ? null : _run,
                ),
              ),
            ),
            if (_types.isNotEmpty) ...[
              const SizedBox(height: Space.sm),
              DropdownButtonFormField<int?>(
                isExpanded: true,
                initialValue: _typeId,
                decoration: const InputDecoration(labelText: 'Kind of entity'),
                items: [
                  const DropdownMenuItem<int?>(child: Text('Any kind')),
                  for (final t in _types)
                    DropdownMenuItem<int?>(value: t.id, child: Text(t.title)),
                ],
                onChanged: (v) {
                  setState(() => _typeId = v);
                  if (_searched) unawaited(_run());
                },
              ),
            ],
            const SizedBox(height: Space.md),
            // Flexible and not a fixed height. A dialog on a phone in
            // landscape has less room than this wants, and a Column
            // that insists overflows — which a release web build draws
            // as nothing at all rather than as the striped bar a debug
            // build shows.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: _results(context),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _results(BuildContext context) {
    if (_busy && _page == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final error = _error;
    if (error != null) return _Problem(error: error, onRetry: _run);

    final page = _page;
    if (page == null) {
      return const _Hint(
        icon: Icons.travel_explore_outlined,
        text:
            'Search the register by name or by registration number. '
            'What comes back is what SSM has on file.',
      );
    }
    if (page.items.isEmpty) {
      return _Hint(
        icon: Icons.search_off,
        text: SsmQueryHints.looksLikeRegNo(_query.text)
            // Two different facts, and telling somebody the wrong one
            // sends them looking in the wrong place.
            ? 'No company carries that registration number. Check the '
                  'digits — a letterhead is where a reader loses one.'
            : 'Nothing by that name. The register holds the REGISTERED '
                  'name, which is often not the name on the sign.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.xs),
          child: Text(
            [
              '${page.total} ${page.total == 1 ? 'match' : 'matches'}',
              if (page.cached) 'from a recent search',
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: page.items.length + (page.hasMore ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == page.items.length) {
                return Center(
                  child: TextButton(
                    onPressed: _busy ? null : () => _run(page: page.page + 1),
                    child: Text('Show more (page ${page.page + 1})'),
                  ),
                );
              }
              final e = page.items[i];
              return ListTile(
                key: ValueKey('ssm-hit-$i'),
                dense: true,
                title: Text(e.name),
                subtitle: Text(
                  [
                    e.registrationDisplay,
                    if (e.entityType != null) e.entityType!,
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, e),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// What went wrong, and whether it is worth trying again.
class _Problem extends StatelessWidget {
  const _Problem({required this.error, required this.onRetry});

  final SsmLookupException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              error.notConfigured
                  ? Icons.settings_outlined
                  : Icons.error_outline,
              color: error.notConfigured
                  ? context.colors.warning
                  : context.colors.danger,
            ),
            const SizedBox(height: Space.sm),
            Text(
              error.userMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            // Nothing to retry when nobody has set it up: the same
            // answer would come back, and offering the button says the
            // opposite of what is true.
            if (!error.notConfigured) ...[
              const SizedBox(height: Space.sm),
              TextButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: Space.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
