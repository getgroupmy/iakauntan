import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';
import '../../core/error_text.dart';
import '../../core/format.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// What the holder of a signing link sees.
///
/// The only page in the app that works with no account. A director will
/// not sign up to an accounting system to sign one resolution, so the
/// link has to stand on its own — and it grants exactly one action on
/// exactly one document, never a session.
///
/// It deliberately does not use [repoProvider]: there may be no signed-in
/// user at all, and the two functions behind this page authorise
/// themselves against the token rather than against a JWT.
class SigningPage extends ConsumerStatefulWidget {
  const SigningPage({super.key, required this.token});

  final String token;

  @override
  ConsumerState<SigningPage> createState() => _SigningPageState();
}

class _SigningPageState extends ConsumerState<SigningPage> {
  late Future<Map<String, dynamic>> _link = _open();
  final _name = TextEditingController();
  bool _signing = false;
  bool _done = false;

  SupabaseClient get _client => Supabase.instance.client;

  Future<Map<String, dynamic>> _open() async {
    final rows = await _client
        .rpc('corp_open_signing_link', params: {'p_token': widget.token});
    final list = (rows as List?) ?? const [];
    return list.isEmpty
        ? {'state': 'invalid'}
        : Map<String, dynamic>.from(list.first as Map);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: FutureBuilder<Map<String, dynamic>>(
              future: _link,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(Space.xxl),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return _Message(
                    icon: Icons.error_outline,
                    title: 'Something went wrong',
                    body: '${snap.error}',
                  );
                }
                final d = snap.data ?? const {'state': 'invalid'};
                if (_done) {
                  return _Message(
                    icon: Icons.check_circle_outline,
                    title: 'Signed',
                    body: 'Thank you. ${d['company_name'] ?? 'The company'}’s '
                        'secretary has been notified. You can close this page '
                        '— the link has now been used and will not open again.',
                    tone: _Tone.good,
                  );
                }
                return _forState(context, d);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _forState(BuildContext context, Map<String, dynamic> d) {
    final state = d['state']?.toString() ?? 'invalid';

    // Every unusable state gets its own sentence. "Invalid link" for a
    // link that merely expired sends somebody hunting for a problem that
    // is not there.
    final problems = <String, ({String title, String body})>{
      'invalid': (
        title: 'This link is not valid',
        body: 'Check that you copied the whole address. If it came by '
            'e-mail, open it from the message rather than retyping it.',
      ),
      'expired': (
        title: 'This link has expired',
        body: 'Signing links are short-lived on purpose. Ask the company '
            'secretary for a new one.',
      ),
      'used': (
        title: 'This link has already been used',
        body: 'Each link signs once. If you need to sign again, ask for a '
            'fresh link.',
      ),
      'revoked': (
        title: 'This link has been withdrawn',
        body: 'A newer link was issued, or the secretary withdrew this one.',
      ),
      'already_signed': (
        title: 'Already signed',
        body: 'This document has been signed in your name.',
      ),
      'withdrawn': (
        title: 'The request has been withdrawn',
        body: 'The company secretary withdrew this document from signature.',
      ),
      'changed': (
        title: 'The document has changed',
        body: 'The text has been edited since this link was sent, so it can '
            'no longer be signed against it. Ask for a new link — this is '
            'the check working, not a fault.',
      ),
    };

    if (state != 'open') {
      final p = problems[state] ??
          (title: 'This link cannot be used', body: 'Ask for a new one.');
      return _Message(
        icon: Icons.link_off,
        title: p.title,
        body: p.body,
        tone: _Tone.warn,
      );
    }

    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.scheme.onSurfaceVariant);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(Env.appName,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: Space.xs),
            Text(
              '${d['company_name']} has asked you to sign as '
              '${d['capacity'] ?? 'a signatory'}.',
              style: muted,
            ),
            const SizedBox(height: Space.lg),
            Text(d['document_title']?.toString() ?? 'Document',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Space.lg),
            Container(
              padding: const EdgeInsets.all(Space.lg),
              decoration: BoxDecoration(
                color: context.scheme.surfaceContainerHighest
                    .withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: SelectableText(d['document_body']?.toString() ?? ''),
            ),
            const SizedBox(height: Space.xl),
            Text(
              'Typing your name below records that you signed this document '
              'as it stands. The text is fingerprinted at that moment, so a '
              'later edit is detectable. This is an electronic signature '
              'under the Electronic Commerce Act 2006 — it is not a digital '
              'signature under the Digital Signature Act 1997.',
              style: muted,
            ),
            const SizedBox(height: Space.md),
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: 'Your full name',
                hintText: d['signatory_name']?.toString(),
              ),
              onSubmitted: (_) => _sign(),
            ),
            const SizedBox(height: Space.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    'This link expires ${Fmt.date(Fmt.parseDate(d['expires_at']))}',
                    style: muted,
                  ),
                ),
                // Both answers, side by side. Offering only "Sign"
                // leaves somebody who will not sign with nothing to do
                // but close the tab, and a line that stays pending for
                // ever reads at the other end as unopened.
                TextButton(
                  key: const ValueKey('decline-with-link'),
                  onPressed: _signing ? null : _decline,
                  child: const Text('I will not sign'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _signing ? null : _sign,
                  icon: _signing
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.draw_outlined, size: 18),
                  label: const Text('Sign'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sign() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter your name')));
      return;
    }

    setState(() => _signing = true);
    try {
      await _client.rpc('corp_sign_with_link',
          params: {'p_token': widget.token, 'p_signed_name': name});
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_readable(e))));
        // Whatever went wrong, the link's state may have moved on.
        setState(() {
          _link = _open();
        });
      }
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  /// The other answer, on the same screen.
  ///
  /// Somebody who reads the document on a link and will not sign it has
  /// to be able to say so here, or they simply do not reply — and a line
  /// that stays pending for ever reads as unopened.
  Future<void> _decline() async {
    final why = await promptForText(
      context,
      title: 'Why are you not signing?',
      label: 'Reason',
      confirmLabel: 'Send this instead',
    );
    if (why == null || !mounted) return;

    setState(() => _signing = true);
    try {
      await _client.rpc('corp_decline_with_link',
          params: {'p_token': widget.token, 'p_reason': why});
      if (mounted) setState(() => _done = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_readable(e))));
        setState(() {
          _link = _open();
        });
      }
    } finally {
      if (mounted) setState(() => _signing = false);
    }
  }

  String _readable(Object e) => errorText(e);
}

enum _Tone { neutral, good, warn }

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.tone = _Tone.neutral,
  });

  final IconData icon;
  final String title;
  final String body;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final colour = switch (tone) {
      _Tone.good => context.colors.success,
      _Tone.warn => context.colors.warning,
      _Tone.neutral => context.scheme.onSurfaceVariant,
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: colour),
            const SizedBox(height: Space.lg),
            Text(title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: Space.sm),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: context.scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
