import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import 'demo_accounts.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, this.startOnRegister = false});

  /// Whether to open on the sign-up form rather than the sign-in one.
  ///
  /// The landing page offers both, and somebody who pressed "Create an
  /// account" should not have to find the toggle once they arrive.
  final bool startOnRegister;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();

  late bool _isSignUp = widget.startOnRegister;
  bool _busy = false;
  String? _demoBusy;
  bool _obscure = true;
  String? _error;
  String? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    final auth = ref.read(supabaseProvider).auth;
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {'full_name': _fullName.text.trim()},
        );
        // With email confirmation enabled there is no session yet.
        if (res.session == null && mounted) {
          setState(() {
            _notice = 'Check your inbox to confirm your email, then sign in.';
            _isSignUp = false;
          });
        }
      } else {
        await auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on AuthException catch (e) {
      await _noteRefusal(e);
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Tell the company that somebody was refused at its door.
  ///
  /// The only party that knows a password was rejected is this browser:
  /// GoTrue writes no row for a failed sign-in and this project's
  /// `auth.audit_log_entries` is empty, so 0235 has the client report it.
  /// The server takes it as a hint rather than as evidence -- it records
  /// nothing for an address that is not a user, stores neither the
  /// password nor the attempt, and writes at most one row a minute.
  ///
  /// Only for a rejected credential. A network failure or a rate limit is
  /// not somebody trying a password, and filing it as one would teach
  /// whoever reads the log to ignore it.
  ///
  /// Never allowed to interrupt the sign-in screen: if reporting fails,
  /// the person in front of it still needs their error message.
  Future<void> _noteRefusal(AuthException e) async {
    if (_isSignUp) return;
    final email = _email.text.trim();
    if (email.isEmpty) return;
    if (e.statusCode != '400') return;

    try {
      await ref
          .read(supabaseProvider)
          .rpc('report_failed_sign_in', params: {'p_email': email});
    } catch (_) {
      // Deliberately swallowed.
    }
  }

  /// Straight in, no typing.
  ///
  /// Deliberately the same signInWithPassword call the form makes rather
  /// than a side door: the demo account is a real user with a real role,
  /// and it should reach the app the same way everyone else does, so
  /// what a visitor sees is what the product does.
  Future<void> _signInAsDemo(DemoAccount account) async {
    setState(() {
      _demoBusy = account.email;
      _error = null;
      _notice = null;
    });
    try {
      await ref.read(supabaseProvider).auth.signInWithPassword(
            email: account.email,
            password: demoPassword,
          );
    } on AuthException catch (e) {
      if (!mounted) return;
      // The likeliest cause by far is that the demo users were deleted
      // before the project took real books, which is exactly what the
      // README tells you to do. Saying "invalid login credentials" would
      // send somebody hunting for a typo in a password they never typed.
      setState(() => _error = e.statusCode == '400'
          ? 'The demo accounts are not available on this deployment.'
          : e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _demoBusy = null);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email first, then tap reset.');
      return;
    }
    // The database refuses the change these links lead to, so sending one
    // would only waste somebody's time. Said here rather than three
    // screens later, once they have already opened their inbox.
    if (demoAccounts.any((a) => a.email.toLowerCase() == email.toLowerCase())) {
      setState(() => _error =
          'The demo accounts share a fixed password, so it cannot be reset. '
          'Use the buttons below to sign in.');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(supabaseProvider).auth.resetPasswordForEmail(
            email,
            // Aim the link at the reset screen rather than leaving it to
            // the project's Site URL, so a preview deployment sends
            // people back to that preview instead of production. The
            // origin has to be in Supabase's redirect allow list.
            redirectTo: kIsWeb ? '${Uri.base.origin}/#/reset-password' : null,
          );
      if (mounted) {
        setState(() => _notice = 'Password reset link sent to $email.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final form = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!wide) ...[
                  const _Brand(),
                  const SizedBox(height: 32),
                ],
                Text(
                  _isSignUp ? 'Create your account' : 'Welcome back',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  _isSignUp
                      ? 'Set up your books in a couple of minutes.'
                      : 'Sign in to continue to iAkauntan.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                if (_isSignUp) ...[
                  TextFormField(
                    controller: _fullName,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Full name',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: (v) => (v ?? '').trim().isEmpty
                        ? 'Enter your name'
                        : null,
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                  validator: (v) {
                    final value = (v ?? '').trim();
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) {
                    if ((v ?? '').isEmpty) return 'Enter your password';
                    if (_isSignUp && v!.length < 8) {
                      return 'Use at least 8 characters';
                    }
                    return null;
                  },
                ),
                if (!_isSignUp)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _busy ? null : _resetPassword,
                      child: const Text('Forgot password?'),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _Banner(message: _error!, color: context.colors.danger),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  _Banner(message: _notice!, color: context.colors.success),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_isSignUp ? 'Create account' : 'Sign in'),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                            _isSignUp = !_isSignUp;
                            _error = null;
                            _notice = null;
                          }),
                  child: Text(
                    _isSignUp
                        ? 'Already have an account? Sign in'
                        : "New to iAkauntan? Create an account",
                  ),
                ),
                // Not offered halfway through creating an account: the
                // demo is an alternative to signing up, not a step in it.
                if (demoModeEnabled && !_isSignUp) ...[
                  const SizedBox(height: 20),
                  DemoAccountPicker(
                    onPick: _signInAsDemo,
                    busyEmail: _demoBusy,
                    enabled: !_busy,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (!wide) return Scaffold(body: form);

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              color: scheme.primary,
              child: const Padding(
                padding: EdgeInsets.all(48),
                child: _Hero(),
              ),
            ),
          ),
          Expanded(child: form),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onDark ? scheme.onPrimary : scheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: onDark ? scheme.onPrimary : scheme.primary,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.account_balance_wallet,
            color: onDark ? scheme.primary : scheme.onPrimary,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'iAkauntan',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: color,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  static const _points = [
    ('LHDN e-Invoice built in', 'Submit to MyInvois and track validation without leaving your books.'),
    ('Double-entry you can trust', 'Every invoice, bill and payment posts to a balanced ledger.'),
    ('Sales and CRM together', 'Move a deal from lead to paid invoice in one system.'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const _Brand(onDark: true),
        const SizedBox(height: 40),
        Text(
          'Accounting and CRM\nfor Malaysian business.',
          style: TextStyle(
            fontSize: 34,
            height: 1.2,
            fontWeight: FontWeight.w700,
            color: scheme.onPrimary,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 32),
        for (final (title, body) in _points)
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle,
                    color: scheme.onPrimary.withValues(alpha: 0.9), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        body,
                        style: TextStyle(
                          color: scheme.onPrimary.withValues(alpha: 0.75),
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
