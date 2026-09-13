import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../landing/landing_content.dart';
import '../../core/page_waiting.dart';

/// Where a password reset link lands.
///
/// Redeeming the link gives Supabase a session, so by the time this
/// screen appears the person is technically signed in. That is exactly
/// why the screen exists: without it they would arrive at the dashboard
/// with the password they had forgotten still in force, having proved
/// only that they can read their own e-mail.
///
/// No current password is asked for here — they do not have one they can
/// remember, and possession of the link is the proof. Changing a password
/// from Settings is the other case, and that one does ask.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  String get _wordmark =>
      ref.watch(landingContentProvider).valueOrNull?.wordmark ?? Env.appName;

  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(supabaseProvider)
          .auth
          .updateUser(UserAttributes(password: _password.text));
      // Only now is the recovery over; until this call returned, the old
      // password was still the live one.
      ref.read(passwordRecoveryProvider.notifier).done();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password changed. You are signed in.')),
        );
        context.go('/dashboard');
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The way out for somebody who did not ask for this e-mail.
  Future<void> _abandon() async {
    ref.read(passwordRecoveryProvider.notifier).done();
    await ref.read(supabaseProvider).auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    // The wordmark is on this page twice, and `?? Env.appName` drew the
    // name we ship with until the operator's landed.
    if (!settled(ref.watch(landingContentProvider))) return const PageWaiting();

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Choose a new password',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        user?.email == null
                            // The platform's own name, not the one the
                            // product was compiled with. `Env.appName` is
                            // a constant and cannot know it was rebranded.
                            ? 'Set a new password for your $_wordmark account.'
                            : 'Set a new password for ${user!.email}.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: context.scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: Space.lg),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'New password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: validatePassword,
                      ),
                      const SizedBox(height: Space.md),
                      TextFormField(
                        controller: _confirm,
                        obscureText: _obscure,
                        decoration: const InputDecoration(
                          labelText: 'Confirm new password',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        validator: (v) => v == _password.text
                            ? null
                            : 'The two passwords do not match',
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: Space.md),
                        Text(
                          _error!,
                          style: TextStyle(color: context.colors.danger),
                        ),
                      ],
                      const SizedBox(height: Space.lg),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Set password'),
                      ),
                      const SizedBox(height: Space.sm),
                      TextButton(
                        onPressed: _busy ? null : _abandon,
                        child: const Text('I did not ask for this — sign out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Supabase's own minimum is six characters. Eight is the floor here
/// because this is somebody's accounting system, and the rule is stated
/// rather than left for the server to reject after the fact.
String? validatePassword(String? value) {
  final v = value ?? '';
  if (v.length < 8) return 'Use at least 8 characters';
  if (v.trim().isEmpty) return 'A password of spaces is not a password';
  return null;
}
