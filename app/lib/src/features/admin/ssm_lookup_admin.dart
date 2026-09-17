import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../../data/ssm_repository.dart';
import '../shared/ssm_entity_picker.dart';

/// The SSM register lookup, from the operator's side.
///
/// ## There is no credential form here, and that is deliberate
///
/// The ssmsearch.com email and password are edge-function secrets in
/// the Supabase dashboard, like `OCR_KEY_*` and `RESEND_API_KEY`. The
/// package this feature came from offered to key them in on this screen
/// and store them in the database; that would put a working login to a
/// third-party service in a table, inside a payload the app can read,
/// where the rest of this system's secrets are deliberately not.
///
/// So the screen answers a narrower question — is it configured, is
/// there a live session, what went wrong last, how much is it being
/// used — and the four buttons are the four things an operator can
/// usefully DO without holding the password: prove the login works,
/// throw the session away, empty the cache, and run a real search.
///
/// ## Why "test the login" is worth a button
///
/// A wrong secret in the dashboard does not announce itself. Without
/// this, the first sign of one is a user's search failing, and the
/// error they see says the registry is not answering, which is not
/// what happened.
class SsmLookupAdminTab extends ConsumerStatefulWidget {
  const SsmLookupAdminTab({super.key});

  @override
  ConsumerState<SsmLookupAdminTab> createState() => _SsmLookupAdminTabState();
}

class _SsmLookupAdminTabState extends ConsumerState<SsmLookupAdminTab> {
  bool _busy = false;

  /// Runs one of the operator actions, reporting what happened either
  /// way. A refusal here is information — `FORBIDDEN` means the caller
  /// is not platform staff, and the function decides that, not this
  /// screen.
  Future<void> _act(Future<String> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final said = await action();
      messenger.showSnackBar(SnackBar(content: Text(said)));
      ref.invalidate(ssmStatusProvider);
    } on SsmLookupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks the provider which paths are routes, and shows what came
  /// back.
  ///
  /// Its own method rather than another `_act`, because the result is
  /// a table somebody reads and copies a path out of, not a sentence
  /// in a snackbar.
  Future<void> _probe() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final found = await ref.read(ssmLookupProvider).probe();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _ProbeResult(probe: found),
      );
    } on SsmLookupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.userMessage)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(ssmStatusProvider);

    return AsyncView<SsmStatus>(
      value: status,
      onRetry: () => ref.invalidate(ssmStatusProvider),
      builder: (s) => SingleChildScrollView(
        child: PageBody(
          maxWidth: 820,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        'The SSM register lookup',
                        subtitle: s.configured
                            ? 'Set up. Anybody signed in can look a company '
                                  'up while adding or correcting a contact.'
                            : 'Not set up. Every search answers "not '
                                  'switched on yet" rather than failing.',
                        action: StatusChip(
                          s.configured ? 'valid' : 'not_applicable',
                        ),
                      ),
                      _Row(
                        label: 'Which lookup',
                        value: s.onOfficialApi
                            ? 'SSM\u2019s own Search API (charged per call)'
                            : 'ssmsearch.com, the interim one',
                      ),
                      if (!s.configured)
                        const _NotConfigured()
                      else ...[
                        _Row(
                          label: 'Signed in as',
                          value: s.loggedInAs ?? 'Not signed in yet',
                        ),
                        _Row(
                          label: 'Session taken',
                          value: s.obtainedAt == null
                              ? 'No session held'
                              : Fmt.dateTime(s.obtainedAt),
                        ),
                        _Row(
                          label: 'Last used',
                          value: s.lastUsedAt == null
                              ? 'Never'
                              : Fmt.dateTime(s.lastUsedAt),
                        ),
                        _Row(
                          label: 'Searches, 24 hours',
                          value: '${s.searches24h}',
                        ),
                        _Row(label: 'Answers cached', value: '${s.cacheRows}'),
                        // The endpoints, because the defaults are a
                        // guess at ssmsearch.com's own API and each is
                        // overridable by a dashboard secret. "Which URL
                        // did it ask for" is the first question a
                        // failed sign-in raises, and once these are
                        // overridable the repository cannot answer it.
                        if (s.loginUrl != null)
                          _Row(label: 'Signs in at', value: s.loginUrl!),
                        if (s.searchUrl != null)
                          _Row(label: 'Searches at', value: s.searchUrl!),
                        if (s.lastError != null)
                          _Row(
                            label: 'Last error',
                            value:
                                '${s.lastError}'
                                '${s.lastErrorAt == null ? '' : ' · ${Fmt.dateTime(s.lastErrorAt)}'}',
                            danger: true,
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(Space.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        'What an operator can do',
                        subtitle:
                            'The login itself lives in the Supabase '
                            'dashboard, under the edge function’s '
                            'secrets, and nothing here can read it.',
                      ),
                      Wrap(
                        spacing: Space.sm,
                        runSpacing: Space.sm,
                        children: [
                          FilledButton.tonalIcon(
                            key: const ValueKey('ssm-test-login'),
                            onPressed: _busy || !s.configured
                                ? null
                                : () => _act(() async {
                                    final who = await ref
                                        .read(ssmLookupProvider)
                                        .testLogin();
                                    return who == null
                                        ? 'Signed in.'
                                        : 'Signed in as $who.';
                                  }),
                            icon: const Icon(Icons.login),
                            label: const Text('Test the login'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('ssm-clear-session'),
                            onPressed: _busy || !s.configured
                                ? null
                                : () => _act(() async {
                                    await ref
                                        .read(ssmLookupProvider)
                                        .clearSession();
                                    return 'Session thrown away. The next '
                                        'search signs in again.';
                                  }),
                            icon: const Icon(Icons.logout),
                            label: const Text('Force a fresh sign-in'),
                          ),
                          OutlinedButton.icon(
                            key: const ValueKey('ssm-clear-cache'),
                            onPressed: _busy
                                ? null
                                : () => _act(() async {
                                    await ref
                                        .read(ssmLookupProvider)
                                        .clearCache();
                                    return 'Cache emptied.';
                                  }),
                            icon: const Icon(Icons.cleaning_services_outlined),
                            label: const Text('Empty the cache'),
                          ),
                          // Offered whether or not the login works,
                          // and especially when it does not: this is
                          // what somebody reaches for when the
                          // configured path is the thing that is
                          // wrong.
                          FilledButton.tonalIcon(
                            key: const ValueKey('ssm-probe'),
                            onPressed: _busy ? null : _probe,
                            icon: const Icon(Icons.travel_explore),
                            label: const Text('Find the endpoints'),
                          ),
                          TextButton.icon(
                            key: const ValueKey('ssm-try-search'),
                            onPressed: _busy
                                ? null
                                : () => showSsmEntityPicker(context),
                            icon: const Icon(Icons.travel_explore_outlined),
                            label: const Text('Try a search'),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      Text(
                        'Emptying the cache costs the upstream a fresh '
                        'search for every question already answered. Worth '
                        'it when a company has just changed its name; not '
                        'worth it as a habit.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              const _Caution(),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the probe found, and what to do with it.
///
/// A table rather than a sentence, because the useful output is a path
/// somebody copies into a secret — and the reason a path is interesting
/// is what the provider SAID when asked, which a snackbar cannot hold.
class _ProbeResult extends StatelessWidget {
  const _ProbeResult({required this.probe});

  final SsmProbe probe;

  @override
  Widget build(BuildContext context) {
    final found = probe.found;
    return AlertDialog(
      title: const Text('What answered'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                found.isEmpty
                    // Also an answer, and a more useful one than it
                    // looks: it rules out every shape the guesses were
                    // based on rather than leaving somebody to try a
                    // few more by hand.
                    ? 'Every path was answered "not found". The provider\u2019s '
                          'API is not shaped like any of these, so the next '
                          'step is a browser: developer tools, Network, '
                          'Fetch/XHR, sign in, and read the request URL.'
                    : 'These answered something other than "not found", so '
                          'something is listening. Put the path in '
                          'SSMSEARCH_LOGIN_PATH or SSMSEARCH_SEARCH_PATH and '
                          'test the login again.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: Space.sm),
              Text(probe.apiRoot, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Space.md),
              for (final hit in [...probe.login, ...probe.search])
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        hit.exists ? Icons.check_circle_outline : Icons.remove,
                        size: 16,
                        color: hit.exists
                            ? context.colors.success
                            : Theme.of(context).colorScheme.outline,
                      ),
                      const SizedBox(width: Space.sm),
                      SizedBox(
                        width: 170,
                        child: Text(
                          '${hit.method} ${hit.path}',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: hit.exists
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          hit.status == 0 ? '\u2014' : '${hit.status}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          hit.said,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: Space.md),
              Text(
                'No password was sent. A login route answers an empty body '
                'with a complaint about the missing fields; a path that is '
                'not a route answers 404.',
                style: Theme.of(context).textTheme.bodySmall,
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

/// What to do about a lookup nobody has set up.
///
/// Names the two secrets, because the alternative is an operator
/// guessing at them or reading the edge function's source.
class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set SSMSEARCH_EMAIL and SSMSEARCH_PASSWORD in the Supabase '
            'dashboard, under Edge Functions → Secrets, then come '
            'back and test the login.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: Space.sm),
          Text(
            'They are not kept in this database or in this repository, '
            'so there is nothing to key in here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.sm),
          Text(
            'Three more are optional and only matter if the sign-in '
            'fails with a path: SSMSEARCH_API_ROOT, '
            'SSMSEARCH_LOGIN_PATH and SSMSEARCH_SEARCH_PATH. The '
            'defaults are a guess at the provider\u2019s own API, and '
            'correcting one is a secret change rather than a release.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// The terms-of-service caution, on screen and not only in a document.
///
/// The same words are in `docs/ssm-lookup.md` and in migration 0589.
/// An operator deciding how hard to lean on this feature is the person
/// who needs to know, and they will not be reading the migration.
class _Caution extends StatelessWidget {
  const _Caution();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: context.colors.warning.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.gavel_outlined, color: context.colors.warning),
                const SizedBox(width: Space.sm),
                Text(
                  'While the official API is arranged',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Text(
              'The interim provider signs in to ssmsearch.com the way '
              'their own website does and searches from a server, which '
              'their terms of service prohibit. Keep the volume modest '
              '— the cache and the per-minute limit are part of '
              'that — and switch to SSM’s Corporate API when '
              'it is available. See docs/ssm-lookup.md.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                color: danger ? context.colors.danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
