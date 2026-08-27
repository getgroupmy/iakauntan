import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../data/reserved_names_repository.dart';
import '../../data/site_pages_repository.dart';
import '../../core/theme.dart';
import '../landing/landing_content.dart';
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
  /// What this platform calls itself, or what the product shipped as.
  /// Named rather than inlined because it appears in two sentences and
  /// they must not disagree.
  String get _wordmark =>
      ref.watch(landingContentProvider).valueOrNull?.wordmark ?? 'iAkauntan';

  /// The company whose door this is, when somebody has arrived at their
  /// own subdomain rather than at ours. Null everywhere else, which is
  /// most places.
  String? get _workspace =>
      ref.watch(workspaceHostProvider).valueOrNull?['name'] as String?;

  /// The wording an operator wrote for whichever of the two moods this
  /// screen is in, from `site_pages()`. Null until it arrives and null
  /// if nobody has written it, and both mean the same thing here: use
  /// the sentence the product shipped with.
  SitePage? get _copy =>
      ref.watch(sitePagesProvider).valueOrNull?[_isSignUp ? 'signup' : 'signin'];

  /// Whether the platform is currently offering the demo logins.
  ///
  /// False while the payload is in flight, deliberately: a list of
  /// one-tap logins that appears a moment after the page has settled is
  /// worse than one that never appears, and the safe answer is the one
  /// to show while nothing is known.
  bool get _demoOffered =>
      ref.watch(landingContentProvider).valueOrNull?.demoAccountsEnabled ??
      false;

  /// The brand payload, or null while it is in flight.
  ///
  /// Every switch below reads through this, and every one of them
  /// treats "not yet known" as "do not draw". That is the same choice
  /// the demo list makes and for the same reason: copy that appears a
  /// moment after the form has settled reads as a glitch, and a page
  /// that starts bare and stays bare is the honest rendering of a
  /// platform that has turned everything off.
  LandingContent? get _brand => ref.watch(landingContentProvider).valueOrNull;

  /// Whether the mark is drawn at all.
  ///
  /// A company at its own subdomain always gets one: that mark is
  /// Sinar's, and this switch is about whether *our* marketing appears
  /// on the page. Taking a company's own logo off its own door because
  /// the platform turned its own off would be the wrong reading of it.
  bool get _showMark =>
      _workspace != null || (_brand?.signinShowMark ?? false);

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
        await _refuseIfNotTheirDoor();
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

  /// Turn away somebody who signed in correctly at a door that is not
  /// theirs.
  ///
  /// Read this before relying on it: it is a **door policy, not a
  /// security boundary**. The same person can sign in at
  /// `iakauntan.com` with the same password and reach exactly the same
  /// data, because the data was never protected by which hostname the
  /// browser used — it is protected by RLS on every table, which this
  /// does not touch and does not need to.
  ///
  /// What it buys is that a company's own address behaves like one. A
  /// stranger who lands on Sinar's page, sees Sinar's name and logo and
  /// is let in has been told something untrue about their relationship
  /// to Sinar, even though they only ever reach their own books.
  ///
  /// A failure to reach the server leaves the session alone. Signing
  /// somebody out because a request timed out is a worse answer than
  /// letting a member through on a page that is theirs anyway.
  Future<void> _refuseIfNotTheirDoor() async {
    final workspace = ref.read(workspaceHostProvider).valueOrNull;
    if (workspace == null) return;

    final client = ref.read(supabaseProvider);
    bool allowed;
    try {
      allowed = await client.rpc(
            'may_use_workspace',
            params: {'p_host': Uri.base.host},
          ) as bool? ??
          true;
    } catch (_) {
      return;
    }
    if (allowed) return;

    await client.auth.signOut();
    if (!mounted) return;
    setState(() {
      _error = 'That account is not on ${workspace['name']}\'s team. '
          'Sign in at iakauntan.com to reach your own books.';
    });
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
                // On a phone there is no panel, so this is the only
                // place the mark can appear. Same switch either way.
                if (!wide && _showMark) ...[
                  const _Brand(),
                  const SizedBox(height: 32),
                ],
                if (_brand?.signinShowHeading ?? false) ...[
                  Text(
                    _copy?.title ??
                        (_isSignUp ? 'Create your account' : 'Welcome back'),
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    // At a company's own door the second line names the
                    // company, and it beats anything written in the
                    // console: platform-wide copy cannot say "Sinar",
                    // and that is the one fact somebody standing at
                    // `sinar.iakauntan.com` is checking for.
                    _workspace != null && !_isSignUp
                        ? 'Sign in to continue to $_workspace.'
                        : _copy?.body ??
                            (_isSignUp
                                ? 'Set up your books in a couple of minutes.'
                                : 'Sign in to continue to $_wordmark.'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                ],
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
                // Everything below the Sign in button is about joining
                // the platform, and none of it belongs at a company's
                // own address.
                //
                // Creating an account here would make one that is not on
                // Sinar's team — and the door policy would then turn it
                // away, which is a loop the visitor cannot see the shape
                // of. Somebody who needs an account at Sinar is invited
                // to one by Sinar.
                // And not unless the platform is offering it. Off by
                // default, like everything else `0336` put a switch on:
                // a way in that nobody chose to draw is a way in the
                // operator did not know they were offering.
                //
                // `_isSignUp` is exempt because that half of the button
                // is the way *back* from the form somebody is already
                // looking at, and hiding it would strand them.
                if (_workspace == null &&
                    (_isSignUp || (_brand?.signinShowRegister ?? false))) ...[
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
                          : 'New to $_wordmark? Create an account',
                    ),
                  ),
                ],
                // Not offered halfway through creating an account: the
                // demo is an alternative to signing up, not a step in it.
                //
                // Nor at a company's own address, for its own reason
                // rather than the one above: a row of other companies'
                // demo logins on Sinar's page reads as though those
                // companies are somehow part of Sinar — or worse, that
                // this is not really Sinar's page at all.
                // And not unless a platform administrator has turned
                // them on. `demoModeEnabled` is the outer gate — a
                // build without it does not carry the demo password at
                // all — and this is the inner one, off by default, so
                // that a build which does carry it still shows nothing
                // until somebody decides it should.
                if (showDemoAccounts(
                  buildAllows: demoModeEnabled,
                  platformOffers: _demoOffered,
                  isSignUp: _isSignUp,
                  atCompanyDoor: _workspace != null,
                )) ...[
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

    // A wide window with nothing to put in the panel gets no panel.
    // Half a screen of flat colour beside a login box is worse than a
    // centred form, and with every switch off that is exactly what the
    // two-column layout would draw.
    final hero = _HeroContent(
      showMark: _showMark,
      headline: (_brand?.signinShowHeadline ?? false)
          ? (_brand?.signinHeadline ?? LandingContent.defaultSigninHeadline)
          : null,
      points: _brand?.signinPoints ?? const [],
    );

    if (!wide || hero.isEmpty) return Scaffold(body: form);

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              key: const Key('signin-panel'),
              color: scheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: _Hero(content: hero),
              ),
            ),
          ),
          Expanded(child: form),
        ],
      ),
    );
  }
}

/// What the panel beside the form has to draw, if anything.
///
/// A record rather than three arguments so that "is there anything at
/// all" is one question with one answer, asked in the place that
/// decides whether to draw the panel and answered by the same value
/// that fills it. Two separate conditions would eventually disagree,
/// and the way they would disagree is an empty teal half-screen.
class _HeroContent {
  const _HeroContent({
    required this.showMark,
    required this.headline,
    required this.points,
  });

  final bool showMark;
  final String? headline;
  final List<LandingSection> points;

  bool get isEmpty => !showMark && headline == null && points.isEmpty;
}

/// The platform's mark, on the way in.
///
/// Reads the same brand the landing page does. Before this it was a
/// hardcoded wallet icon and the literal string "iAkauntan", so an
/// operator who uploaded a logo saw it on the front page and then signed
/// in to somebody else's product.
///
/// Falls back to exactly what was here before whenever no logo is set,
/// which is every platform that has not opened the console — so nothing
/// changes for them.
/// What the sign-in screen showed before anybody uploaded anything.
class _Wallet extends StatelessWidget {
  const _Wallet({required this.onDark});

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
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
    );
  }
}

class _Brand extends ConsumerWidget {
  const _Brand({this.onDark = false});

  /// Sitting on the primary colour rather than on the page, which is
  /// where the dark variant of a logo earns its keep.
  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = onDark ? scheme.onPrimary : scheme.primary;
    final brand = ref.watch(landingContentProvider).valueOrNull;

    // A company that has been given a subdomain owns this page: at
    // `sinar.iakauntan.com` the mark is Sinar's, not ours. Everywhere
    // else this is null and nothing below changes.
    final workspace = ref.watch(workspaceHostProvider).valueOrNull;

    // On the primary panel the light logo is the wrong one: same rule
    // the landing page uses, for the same reason.
    final url = workspace?['logo_url'] as String? ??
        (onDark ? brand?.logoDarkUrl : null) ??
        brand?.logoUrl;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (url != null)
          Image.network(
            url,
            height: 40,
            // A logo that will not load must not take the sign-in form
            // with it — this is the one screen nobody can route around.
            errorBuilder: (_, _, _) => _Wallet(onDark: onDark),
          )
        else
          _Wallet(onDark: onDark),
        const SizedBox(width: 12),
        Text(
          workspace?['name'] as String? ?? brand?.wordmark ?? 'iAkauntan',
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

/// The panel beside the form.
///
/// Everything on it is now an operator's decision. Before `0336` this
/// was our mark, our headline and three claims about what the product
/// does, compiled in — on every deployment, including one run by
/// somebody who had never said any of it.
class _Hero extends StatelessWidget {
  const _Hero({required this.content});

  final _HeroContent content;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (content.showMark) ...[
          const _Brand(onDark: true),
          const SizedBox(height: 40),
        ],
        if (content.headline != null) ...[
          Text(
            content.headline!,
            style: TextStyle(
              fontSize: 34,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: scheme.onPrimary,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: 32),
        ],
        for (final point in content.points)
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
                        point.title,
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      if (point.body != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          point.body!,
                          style: TextStyle(
                            color: scheme.onPrimary.withValues(alpha: 0.75),
                            fontSize: 13,
                            height: 1.4,
                          ),
                        ),
                      ],
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
