// ignore_for_file: experimental_member_use
//
// `auth.passkey` is marked `@experimental` in `gotrue`, and the
// analyzer started enforcing that across package boundaries on the SDK
// this repository now pins -- eight warnings, which
// `--fatal-warnings` makes eight errors.
//
// Silenced rather than worked around, because the annotation is
// telling the truth and the truth is already written down:
// `docs/passkeys.md` says passkeys are a BETA feature of the project,
// names the dashboard menu they live under, and warns that the
// relying party ID cannot be changed later without invalidating every
// key already enrolled. There is no stable alternative to move to --
// GoTrue is the only thing that can verify a WebAuthn assertion for
// this project -- so the choice is this API or no passkeys at all.
//
// FILE-level and not line-level on purpose: everything in this file is
// about passkeys, so a per-line ignore would be the same decision
// repeated with more places to forget it. If a call to something else
// experimental ever lands here, it belongs in its own file anyway.
//
// What to do when `gotrue` stabilises it: delete this, and the
// analyzer will say so by having nothing to report.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';
import '../auth/passkey.dart';

/// Saving a passkey, so the next sign-in needs no password.
///
/// This is the half that was missing. `signInWithPasskey` shipped first
/// and `startAuthentication` offers whichever accounts hold a passkey
/// for this site — which, with nothing anywhere able to create one, was
/// none of them. The button on the sign-in screen was a door with
/// nothing behind it for every user in the system.
///
/// ## Why it lives beside Change password
///
/// It is the same decision: how you prove who you are. Somebody who has
/// just been told they can change their password is exactly the person
/// who should be offered the thing that means they will not have to.
///
/// ## Why the list and not just a button
///
/// A passkey is tied to the device that made it. One saved on a laptop
/// that has since been lost is a key somebody else is holding, and an
/// account with no way to see its own keys cannot be tidied — so the
/// list is not a nicety, it is the revocation.
///
/// Names come from the authenticator ("iCloud Keychain", "Windows
/// Hello"), which is what somebody will recognise, and the last-used
/// date is what tells them which one is the laptop they sold.
class PasskeysCard extends ConsumerStatefulWidget {
  const PasskeysCard({super.key});

  @override
  ConsumerState<PasskeysCard> createState() => _PasskeysCardState();
}

class _PasskeysCardState extends ConsumerState<PasskeysCard> {
  List<Passkey>? _keys;
  bool _busy = false;
  String? _error;
  String? _notice;

  /// Whether this browser can run the ceremony at all.
  ///
  /// Asked once, and deliberately NOT "does this machine have a
  /// fingerprint reader". A passkey does not have to live on the
  /// machine you are sitting at: it can go to iCloud Keychain, to
  /// Google Password Manager, to a phone over a QR code, or to a
  /// security key on USB. Asking about the machine hid every one of
  /// those, which is exactly the complaint this answers.
  bool _usable = false;

  @override
  void initState() {
    super.initState();
    // Nothing to ask for on a build that cannot run the ceremony — and
    // asking would reach for Supabase before this screen knows there is
    // one. `settings_no_org_test` caught exactly that: the card threw
    // in `initState` and took the whole settings screen with it, on a
    // build where it was never going to draw anyway.
    if (!passkeysAvailable) return;
    passkeysUsable().then((yes) {
      if (mounted && yes) setState(() => _usable = true);
    });
    _load();
  }

  GoTrueClient get _auth => ref.read(supabaseProvider).auth;

  Future<void> _load() async {
    try {
      final keys = await _auth.passkey.list();
      if (mounted) setState(() => _keys = keys);
    } on AuthException catch (e) {
      // `passkey_disabled` is the project setting being off, which is
      // not this person's problem and not worth a red box on a settings
      // screen they came to for something else. The card simply does
      // not draw.
      if (mounted) {
        setState(() => _keys = e.code == 'passkey_disabled' ? null : const []);
      }
    } catch (_) {
      // Deliberately broad, and this is the one place it is right: this
      // card is optional furniture on a screen full of things somebody
      // actually came for. No Supabase instance, no network, a shape the
      // SDK did not expect — none of them is a reason to take Change
      // password and Change email down with it. `_keys` stays null and
      // the card is absent.
      if (mounted) setState(() => _keys = null);
    }
  }

  Future<void> _add() async {
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await enrolPasskey(_auth);
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A dismissed prompt says nothing. Somebody who closed it decided
      // to, and "that did not work" is the app arguing with them.
      _error = result.outcome == PasskeyOutcome.failed
          ? (result.message ?? 'That passkey was not saved.')
          : null;
      _notice = result.outcome == PasskeyOutcome.signedIn
          ? 'Saved. Next time, choose "Sign in with a passkey".'
          : null;
    });
    if (result.outcome == PasskeyOutcome.signedIn) await _load();
  }

  Future<void> _remove(Passkey key) async {
    final name = key.friendlyName ?? 'this passkey';
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove this passkey?'),
        // Named rather than counted. "Remove passkey 2 of 3" is not
        // something anybody can check before pressing yes.
        content: Text(
          'Sign-ins from $name will stop working. If it is the only one '
          'you have saved, you will need your password again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await _auth.passkey.delete(passkeyId: key.id);
      if (mounted) setState(() => _notice = 'Removed.');
      await _load();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Nothing at all when the project has passkeys off, or this build
    // cannot reach an authenticator. Absent rather than disabled: a
    // greyed-out control invites somebody to work out why, and there is
    // nothing they can do about either.
    if (_keys == null || !passkeysAvailable) return const SizedBox.shrink();

    final keys = _keys!;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader('Passkeys'),
            const Text(
              'A passkey signs you in with a fingerprint, a face or a '
              'PIN instead of a password. Nothing to type and nothing to '
              'remember, and it cannot be phished: the browser will only '
              'ever offer it back to this site.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            // Said out loud because the browser's chooser is the part
            // people do not expect, and somebody who thinks this only
            // works on the machine in front of them will not press the
            // button on a desktop.
            const Text(
              'Where it is kept is your choice when you press the '
              'button: iCloud Keychain or Apple Passwords, Google '
              'Password Manager, your phone by scanning a code, or a '
              'security key. A passkey saved to your phone signs you in '
              'on any computer.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (keys.isEmpty)
              const Text(
                'You have not saved one yet.',
                style: TextStyle(fontSize: 13),
              )
            else
              ...keys.map(
                (k) => ListTile(
                  key: ValueKey('passkey-${k.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.fingerprint),
                  title: Text(k.friendlyName ?? 'Passkey'),
                  subtitle: Text(
                    k.lastUsedAt == null
                        ? 'Saved ${Fmt.date(k.createdAt)} · never used'
                        : 'Saved ${Fmt.date(k.createdAt)} · last used '
                              '${Fmt.date(k.lastUsedAt!)}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    onPressed: _busy ? null : () => _remove(k),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_usable)
              OutlinedButton.icon(
                key: const ValueKey('add-passkey'),
                onPressed: _busy ? null : _add,
                icon: const Icon(Icons.fingerprint, size: 18),
                label: Text(
                  keys.isEmpty ? 'Save a passkey' : 'Save another passkey',
                ),
              )
            else
              Text(
                // Only when the browser has no WebAuthn at all, which
                // means something genuinely old. It is no longer said
                // about a desktop with no fingerprint reader, because
                // that desktop can still save one to a phone.
                'This browser is too old to save a passkey.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (_notice != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _notice!, color: context.colors.success),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _error!, color: context.colors.danger),
            ],
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(Space.md),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(Radii.md),
    ),
    child: Text(message, style: const TextStyle(fontSize: 13)),
  );
}
