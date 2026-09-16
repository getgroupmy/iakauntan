import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

/// A six-digit code as well as a password.
///
/// The third way to prove who you are, beside the password above and
/// the passkey below. It is deliberately the middle one in strength:
/// weaker than a passkey, which cannot be phished at all, and stronger
/// than a password on its own.
///
/// ## Why it is offered when a passkey already is
///
/// Because a passkey is not available everywhere yet — not on this
/// app's Android and iOS builds, and not on an old browser — and
/// because somebody who signs in from a shared machine may not want to
/// leave a key on it. A person who cannot use the strongest thing
/// should not be left with the weakest.
///
/// ## Why the QR code is drawn here rather than shown as sent
///
/// GoTrue returns the QR as an SVG data URL and also returns the
/// `otpauth://` URI it encodes. This draws the URI with `qr_flutter`
/// instead: the app has no SVG renderer, and adding one to display a
/// square of black and white would be a dependency for nothing.
///
/// The secret is shown in text beside it, because scanning is not
/// always possible — somebody setting this up on the same phone their
/// authenticator is on has no second camera to point at the screen.
class TwoFactorCard extends ConsumerStatefulWidget {
  const TwoFactorCard({super.key});

  @override
  ConsumerState<TwoFactorCard> createState() => _TwoFactorCardState();
}

class _TwoFactorCardState extends ConsumerState<TwoFactorCard> {
  List<Factor>? _factors;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref.read(supabaseProvider).auth.mfa.listFactors();
      if (!mounted) return;
      setState(() => _factors = res.totp);
    } catch (_) {
      // Two-factor is a project-level setting and an older GoTrue
      // answers this with an error rather than an empty list. The card
      // is absent in that case, the same way the passkey card is:
      // there is nothing the person reading it could do.
      if (mounted) setState(() => _factors = null);
    }
  }

  Future<void> _enrol() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    AuthMFAEnrollResponse? enrolled;
    try {
      enrolled = await ref
          .read(supabaseProvider)
          .auth
          .mfa
          .enroll(friendlyName: _suggestName());
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    final totp = enrolled?.totp;
    if (totp == null || !mounted) return;

    final verified = await showDialog<bool>(
      context: context,
      // A stray tap outside leaves a factor enrolled and unverified,
      // which is a row in the account that does nothing and cannot be
      // seen. It is cleaned up on cancel below; this stops the third
      // way out.
      barrierDismissible: false,
      builder: (context) => _VerifyDialog(
        factorId: enrolled!.id,
        uri: totp.uri,
        secret: totp.secret,
      ),
    );

    if (verified != true) {
      // Enrolled and never confirmed. Removed rather than left: an
      // unverified factor is invisible in every list and would collide
      // with the next attempt on the friendly name.
      try {
        await ref.read(supabaseProvider).auth.mfa.unenroll(enrolled!.id);
      } catch (_) {
        // Nothing to tell anybody. They cancelled; the tidying is ours.
      }
    }
    await _load();
  }

  /// A name somebody will recognise in a list of two.
  ///
  /// GoTrue requires it to be unique per user, so a fixed string breaks
  /// the second enrolment — which is the case somebody reaches when
  /// they change phones and add the new one before removing the old.
  String _suggestName() {
    final taken = {for (final f in _factors ?? const <Factor>[]) f.friendlyName};
    if (!taken.contains('Authenticator app')) return 'Authenticator app';
    for (var i = 2; i < 20; i++) {
      final name = 'Authenticator app $i';
      if (!taken.contains(name)) return name;
    }
    return 'Authenticator ${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _remove(Factor factor) async {
    final ok = await confirm(
      context,
      title: 'Remove this authenticator?',
      message:
          'You will sign in with your password alone again. Remove it '
          'if the phone it is on has been lost or replaced — a code '
          'nobody can generate is an account nobody can get into, so do '
          'this BEFORE you wipe the old phone, not after.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).auth.mfa.unenroll(factor.id);
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    // Absent while the list has not loaded, and absent where the
    // project has two-factor off. Same reasoning as the passkey card:
    // a disabled control invites somebody to work out why and there is
    // nothing they can do about a dashboard setting.
    if (_factors == null) return const SizedBox.shrink();
    final factors = _factors!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Two-factor'),
            const Text(
              'A six-digit code from an app on your phone, as well as '
              'your password. Somebody who learns your password still '
              'cannot get in without the phone.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (factors.isEmpty)
              const Text(
                'Not set up. Your password alone gets you in.',
                style: TextStyle(fontSize: 13),
              )
            else
              ...factors.map(
                (f) => ListTile(
                  key: ValueKey('factor-${f.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phonelink_lock_outlined),
                  title: Text(f.friendlyName ?? 'Authenticator app'),
                  subtitle: Text(
                    f.status == FactorStatus.verified
                        ? 'Ready'
                        : 'Not finished — remove it and start again',
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: _busy ? null : () => _remove(f),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 13, color: context.colors.danger),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('add-authenticator'),
              onPressed: _busy ? null : _enrol,
              icon: const Icon(Icons.qr_code_2, size: 18),
              label: Text(
                factors.isEmpty
                    ? 'Set up an authenticator'
                    : 'Add another authenticator',
              ),
            ),
            if (factors.isNotEmpty) ...[
              const SizedBox(height: 8),
              // The thing that locks people out, said where they are
              // deciding. A second authenticator on a second device is
              // the recovery, because there is no recovery code here:
              // GoTrue does not issue them.
              Text(
                'Keep a second one on another device. There are no '
                'recovery codes — an authenticator you cannot reach is '
                'an account you cannot reach, and only a platform '
                'administrator can undo that.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Scan, then prove it worked.
///
/// The code is asked for rather than assumed, and GoTrue requires it:
/// a factor stays unverified until one is accepted. That is the right
/// way round — an authenticator somebody thinks they scanned and did
/// not is an account they are about to be locked out of.
class _VerifyDialog extends ConsumerStatefulWidget {
  const _VerifyDialog({
    required this.factorId,
    required this.uri,
    required this.secret,
  });

  final String factorId;
  final String uri;
  final String secret;

  @override
  ConsumerState<_VerifyDialog> createState() => _VerifyDialogState();
}

class _VerifyDialogState extends ConsumerState<_VerifyDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.replaceAll(RegExp(r'\s'), '');
    if (code.length != 6) {
      setState(() => _error = 'The code is six digits.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final mfa = ref.read(supabaseProvider).auth.mfa;
      await mfa.challengeAndVerify(factorId: widget.factorId, code: code);
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        // The one that happens most, and the answer is not "try
        // again": a code that was right thirty seconds ago is wrong
        // now, and a phone whose clock has drifted is wrong every
        // time.
        _error = e.message.toLowerCase().contains('invalid')
            ? 'That code was not accepted. Codes last about thirty '
                  'seconds — wait for the next one. If every code is '
                  'refused, the phone\'s clock is out; turn on '
                  'automatic time on it.'
            : e.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set up your authenticator'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Scan this with Google Authenticator, Microsoft '
                'Authenticator, 1Password or any app that does '
                'six-digit codes.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: Space.lg),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(Space.md),
                  color: Colors.white,
                  child: QrImageView(
                    key: const ValueKey('totp-qr'),
                    data: widget.uri,
                    size: 180,
                    // The URI is not ours to shorten and a wrong
                    // correction level makes a code a phone cannot
                    // read across a room. Medium is what every
                    // authenticator's own documentation shows.
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                  ),
                ),
              ),
              const SizedBox(height: Space.lg),
              // Not everybody can scan. Somebody setting this up on the
              // same phone their authenticator is on has no second
              // camera to point at the screen.
              const Text(
                'Or type this into the app instead:',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      widget.secret,
                      key: const ValueKey('totp-secret'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: widget.secret),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.lg),
              TextField(
                key: const ValueKey('totp-code'),
                controller: _code,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'The code it shows now',
                  counterText: '',
                ),
                onSubmitted: (_) => _verify(),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.colors.danger,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Turn it on'),
        ),
      ],
    );
  }
}
