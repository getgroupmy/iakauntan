import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';
import '../../core/platform_live.dart';
import '../../core/page_waiting.dart';
import '../../core/providers.dart';
import '../../data/reserved_names_repository.dart';
import '../../data/signup_reference_repository.dart';
import 'signup_gate.dart';
import '../../data/site_pages_repository.dart';
import '../../core/searchable_picker.dart';
import '../../core/theme.dart';
import '../landing/landing_content.dart';
import '../onboarding/onboarding_copy.dart';
import 'captcha.dart';
import 'passkey.dart';
import 'confirmation_resend.dart';
import 'password_rules.dart';
import 'phone_number.dart';
import 'reset_cooldown.dart';
import 'demo_accounts.dart';

/// The password, asked in a box of its own.
///
/// At an address that is for somebody in particular the form asks who
/// is there first, and once that is settled the password is the only
/// thing left to say — so it is asked on its own rather than appearing
/// underneath an email box that has already done its job.
///
/// Its own widget, and public, for a reason about testing as much as
/// tidiness: the sign-in screen has proved impossible to pump with a
/// route above it, which is written up at length in
/// `company_door_sign_in_test.dart`. On its own, the thing worth
/// pressing can be pressed.
///
/// [onSubmit] returns null when the password was accepted, and the
/// sentence to show inside the box when it was not — so a mistyped
/// password is corrected where it was typed rather than behind the box
/// that has just closed.
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({
    super.key,
    required this.email,
    required this.label,
    required this.action,
    required this.onSubmit,
  });

  /// Shown so somebody can see which account they are about to open,
  /// having typed it a step ago.
  final String email;
  final String label;
  final String action;
  final Future<String?> Function(String password) onSubmit;

  @override
  State<PasswordDialog> createState() => PasswordDialogState();
}

class PasswordDialogState extends State<PasswordDialog> {
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.onSubmit(_password.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Not dismissable while a password is in the air. The box used to
    // go on a tap outside it or a back gesture, and the sign-in it had
    // already started went on without it -- so the box vanished, the
    // spinner with it, and half a second later somebody was either
    // inside the app or looking at a sentence with no idea what had
    // asked the question. Whatever is running keeps its own box until
    // it has an answer.
    canPop: !_busy,
    child: AlertDialog(
      title: Text(widget.action),
      // One width, and a sensible one.
      //
      // Two things are being fixed at once here and they pull opposite
      // ways. Sizing to the content gives three widths for one dialog —
      // as wide as the email on the way in, wider when a refusal lands
      // under the field, narrower when it clears — which reads as the
      // box fighting the person typing in it. But `double.maxFinite`
      // alone takes *everything* the dialog will allow, and on a desktop
      // that is a password field the width of the window.
      //
      // So: fill the available width, up to a cap. On a phone the cap is
      // never reached and the box is as wide as the screen allows; on a
      // desktop it settles at a width a password actually wants. Either
      // way it is the same width before and after the sentence appears.
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.email,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: _obscure,
                    autofocus: true,
                    enabled: !_busy,
                    autofillHints: const [AutofillHints.password],
                    // Only while there is something to clear: a setState
                    // per keystroke is a rebuild of the box per keystroke,
                    // and that is what typing into it felt like.
                    onChanged: _error == null
                        ? null
                        : (_) => setState(() => _error = null),
                    onSubmitted: (_) => _busy ? null : _go(),
                    decoration: InputDecoration(
                      labelText: widget.label,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _go,
          // The label stays where it is and goes invisible under the
          // spinner, rather than being replaced by it. Swapping a word
          // for a 20px circle resizes the button, which resizes the
          // action row, which moves Cancel out from under the finger
          // that is on its way to it.
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: _busy ? 0 : 1, child: Text(widget.action)),
              if (_busy)
                const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Sign in, then vet, with the router held from before the password
/// leaves until after the answer is in.
///
/// The ordering is the whole of it, and the ordering is what nothing
/// could see. `vettingProvider` was declared, the router honoured it,
/// and for one commit nothing raised it — a rebase resolved a conflict
/// in this file in favour of an older copy and took the two lines with
/// it. Everything still compiled, every test still passed, and the app
/// went back to letting people in and throwing them out again.
///
/// So the sequence is a function with its three moving parts passed in,
/// and asserted directly: raised before [signIn], lowered after [vet],
/// and lowered even when [signIn] throws — because a hold nobody lifts
/// is an app that never moves again.
Future<void> vettedSignIn({
  required Future<void> Function() signIn,
  required Future<void> Function() vet,
  required void Function(bool) hold,
}) async {
  hold(true);
  try {
    await signIn();
    await vet();
  } finally {
    hold(false);
  }
}

/// What to tell somebody refused at a door that is not theirs.
///
/// A company's door names the company. One of ours has no name to give,
/// and "not on 's team" with the name missing reads as a bug rather
/// than as an answer — which is the shape this takes whenever the host
/// lookup has not landed by the time the refusal has.
String notTheirDoorMessage(String? whose) => whose == null
    ? 'That account may not use this address. Sign in at iakauntan.com '
          'to reach your own books.'
    : "That account is not on $whose's team. Sign in at iakauntan.com "
          'to reach your own books.';

/// Whose door this screen is drawing.
///
/// The same form, the same checks and the same refusals; what changes
/// is the page of copy over it. `0348` gives a company's own address a
/// `login` row of its own beside `signin`, because the two are written
/// for different people: somebody at `iakauntan.com` may not have an
/// account yet, and somebody at `sinar.iakauntan.com` works there.
///
/// A scope rather than a second screen, deliberately. The two-step
/// email, the vetting, the password box and the wording of every
/// refusal are the parts that must not drift apart, and a second copy
/// of this file is exactly how they would.
enum SignInScope {
  /// `/signin`, at the bare domain.
  platform,

  /// `/login`, at a company's or a module's own address.
  workspace,
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({
    super.key,
    this.startOnRegister = false,
    this.scope = SignInScope.platform,
  });

  /// Whether to open on the sign-up form rather than the sign-in one.
  ///
  /// The landing page offers both, and somebody who pressed "Create an
  /// account" should not have to find the toggle once they arrive.
  final bool startOnRegister;

  /// Which page of copy to draw. See [SignInScope].
  final SignInScope scope;

  @override
  ConsumerState<SignInScreen> createState() => SignInScreenState();
}

/// Public so a test can reach [showRefusal] — the dialog is the whole
/// of what a refusal is, and the alternative is asserting a fake.
class SignInScreenState extends ConsumerState<SignInScreen> {
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

  /// Whether every question this screen's appearance depends on has an
  /// answer yet.
  ///
  /// The switches above read "not yet known" as "do not draw", which is
  /// right for them and not enough on its own, because the *labels* do
  /// not have a switch: `_brand?.signinEmailLabel ?? 'Email'` draws the
  /// word we shipped with while the payload is in flight and the
  /// operator's word a moment later. So does every other label, and so
  /// does the whole two-column layout — logo and panel absent, then
  /// present. The page an operator has never seen flickers past on the
  /// way to the one they wrote, on every load.
  ///
  /// An error counts as settled. A payload that is never coming is a
  /// real answer — draw what the product shipped with — and it is only
  /// the *waiting* that has no honest rendering.
  bool get _settled => allSettled([
    ref.watch(landingContentProvider),
    ref.watch(workspaceHostProvider),
    ref.watch(workspaceLookupProvider),
    ref.watch(sitePagesProvider),
  ]);

  /// The wording an operator wrote for whichever of the two moods this
  /// screen is in, from `site_pages()`. Null until it arrives and null
  /// if nobody has written it, and both mean the same thing here: use
  /// the sentence the product shipped with.
  SitePage? get _copy {
    final platform = ref.watch(sitePagesProvider).valueOrNull?[_slug];
    if (widget.scope != SignInScope.workspace || _isSignUp) return platform;

    // `0349`. The words over a company's own door are the company's to
    // write, and the platform's `login` row is what a company that has
    // written nothing gets. Carried on the workspace lookup rather than
    // fetched separately: that call is already in flight for the name
    // and the mark on this exact screen, and a second round trip here
    // is a second visible pause on the one page where a pause shows.
    //
    // Field by field, not row by row. A company that wrote a heading
    // and left the lead-in alone should keep ours underneath theirs
    // rather than lose it.
    final workspace = ref.watch(workspaceHostProvider).valueOrNull;
    final title = workspace?['login_title'] as String?;
    final body = workspace?['login_body'] as String?;
    if (title == null && body == null) return platform;
    return SitePage(
      slug: 'login',
      title: title ?? platform?.title,
      body: body ?? platform?.body,
      isPublished: true,
    );
  }

  /// Which of the three auth pages this screen is currently showing.
  ///
  /// Sign-up is always the platform's: `0336` took the offer of an
  /// account off a company's door, so there is no workspace sign-up
  /// page to write and nothing that would draw it.
  String get _slug => _isSignUp
      ? 'signup'
      : widget.scope == SignInScope.workspace
      ? 'login'
      : 'signin';

  /// The words before the name, when nobody has written their own.
  ///
  /// A lead-in rather than a whole sentence: the screen puts the
  /// company's name — or the platform's — after it, so what an operator
  /// types is the half that is theirs to decide.
  String get _defaultLeadIn =>
      _isSignUp ? 'Create your account at' : 'Sign in to continue to';

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

  /// Whether this screen is dressing a company's door rather than the
  /// platform's front desk.
  ///
  /// `0350` gives the login page its own copy of the seven settings
  /// that mean anything at a workspace address, so every read of them
  /// below goes through one of the getters that follow rather than
  /// naming a column directly. Eight `widget.scope ==` checks scattered
  /// through the build method would be eight places to forget one.
  ///
  /// Sign-up is never a door's: `0336` took the offer of an account off
  /// a company's address, so the form can only be in its sign-in mood
  /// here — and if that ever changes, this says which settings it would
  /// be reading.
  bool get _ownDoor => widget.scope == SignInScope.workspace && !_isSignUp;

  String? get _emailLabel =>
      _ownDoor ? _brand?.loginEmailLabel : _brand?.signinEmailLabel;
  String? get _passwordLabel =>
      _ownDoor ? _brand?.loginPasswordLabel : _brand?.signinPasswordLabel;
  String? get _forgotLabel =>
      _ownDoor ? _brand?.loginForgotLabel : _brand?.signinForgotLabel;
  String? get _signInLabel =>
      _ownDoor ? _brand?.loginSignInLabel : _brand?.signInLabel;
  bool get _showHeading => _ownDoor
      ? (_brand?.loginShowHeading ?? false)
      : (_brand?.signinShowHeading ?? false);
  bool get _showHeadline => _ownDoor
      ? (_brand?.loginShowHeadline ?? false)
      : (_brand?.signinShowHeadline ?? false);
  String? get _headline =>
      _ownDoor ? _brand?.loginHeadline : _brand?.signinHeadline;
  List<LandingSection> get _points =>
      (_ownDoor ? _brand?.loginPoints : _brand?.signinPoints) ?? const [];

  /// Whether the logo is drawn, and whether the name is.
  ///
  /// Two questions since `0338`: a logo that already contains the
  /// platform's name does not want the word beside it, and an abstract
  /// mark may want only the word.
  ///
  /// A company at its own subdomain gets both regardless: that mark is
  /// Sinar's, and these switches are about whether *our* marketing
  /// appears on the page. Taking a company's own logo off its own door
  /// because the platform turned its own off would be the wrong reading.
  bool get _showLogo => _workspace != null || (_brand?.signinShowLogo ?? false);
  bool get _showName => _workspace != null || (_brand?.signinShowName ?? false);

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();

  /// The mobile number, in the two halves people type: a dialling code
  /// chosen from a list, and the number itself. Kept apart because the
  /// zero in front of a Malaysian mobile is a trunk prefix and has to
  /// come off before either is stored (`0554`).
  final _phone = TextEditingController();

  /// The password typed a second time, when one is being chosen.
  ///
  /// A password box shows nothing back, so a typo in it is a password
  /// nobody knows — including the person who set it, who finds out at
  /// the next sign-in and has to reset the account they registered
  /// minutes ago.
  final _confirmPassword = TextEditingController();
  bool _obscureConfirm = true;

  /// Where the person registering is. Malaysia and Kuala Lumpur to
  /// begin with, and the dialling code follows the country rather than
  /// being asked for twice.
  /// What they are here for, asked once here so setup does not ask it
  /// one screen later. Business to begin with, which is the commonest
  /// answer and the one the product is named for.
  UseKind _use = UseKind.business;

  /// What a business is asked on top of the five everybody gives.
  ///
  /// Setup asked for both of these as its first act, of somebody who
  /// had typed their company's name into the form above ten seconds
  /// earlier. They ride along on the registration metadata,
  /// `handle_new_user` files them on the profile, and setup offers
  /// them back — see `0590`.
  ///
  /// Not asked of a person, who has no company, and not of a practice:
  /// an accountant's own firm is set up like any company, on the setup
  /// form, and registration is not the moment to start collecting it.
  final _businessName = TextEditingController();
  String _entityType = defaultEntityType;

  /// The Turnstile token, when a captcha is configured.
  ///
  /// Null means "not passed yet", and null again when Turnstile says it
  /// has expired — its tokens last about five minutes, and sending an
  /// expired one is a refusal with nothing on the screen to explain it.
  String? _captchaToken;

  /// How the form asks for a fresh challenge.
  ///
  /// A token is spent by the attempt that used it, so after a refusal
  /// the one in `_captchaToken` is worthless — see [CaptchaController].
  /// Without this a mistyped password left somebody unable to try
  /// again: the second press was answered "captcha protection: request
  /// disallowed", which reads as the check failing rather than as the
  /// password being wrong.
  final _captcha = CaptchaController();

  /// The check could not be drawn, so there is no token coming.
  ///
  /// Kept apart from "not passed yet" because the two need different
  /// sentences: one is something to do, the other is something to
  /// report.
  bool _captchaBroken = false;

  String _country = homeCountryCodeForSignup;
  String? _stateCode = homeStateCode;
  final _stateText = TextEditingController();

  bool get _malaysian => _country == homeCountryCodeForSignup;
  String _dialCode = homeDialCode;

  /// How to address them. The words rather than a code, because that is
  /// what goes on a letter.
  String? _salutation;

  /// When a password reset was last asked for on this screen.
  ///
  /// Null until one is. Kept in the screen rather than anywhere durable
  /// because it guards a courtesy, not a secret: somebody who reloads
  /// the page gets one more attempt, and the server's own limit is
  /// still behind it.
  DateTime? _lastResetAt;

  /// `0613`. Its own clock, not the reset's. Asking for a sign-in link
  /// is not asking for a reset, and sharing the timer would tell
  /// somebody who just reset their password that they cannot have a
  /// link either — for a reason that is about a different button.
  DateTime? _lastLinkAt;

  late bool _isSignUp = widget.startOnRegister;

  bool _busy = false;
  String? _demoBusy;
  bool _obscure = true;
  String? _error;
  String? _notice;

  /// Whether the address this form holds is one that signed in
  /// correctly and was turned away for not being confirmed.
  ///
  /// A latch rather than a reading of the banner, because the offer
  /// has to outlive its own failure. A resend that comes back "the
  /// mail server refused it" replaces the refusal in the banner, and
  /// if the button read the banner it would take itself away at the
  /// moment it is most needed — leaving the dead end this was written
  /// to end.
  bool _unconfirmed = false;

  /// Whether this browser can actually run a passkey ceremony.
  ///
  /// Asked once, because it is a fact about the device rather than
  /// about the form, and asked at all because a desktop with no
  /// fingerprint reader, face camera or device PIN is a real and
  /// common case — drawing the button there offers a door with nothing
  /// behind it.
  ///
  /// Starts false, so the button is absent until the answer is yes.
  /// The other way round would flash a button onto the form and take
  /// it away again.
  bool _passkeyUsable = false;

  @override
  void initState() {
    super.initState();
    // The Sign in button is enabled by what is in these two boxes, so
    // the form has to rebuild as they are typed. A `TextFormField`
    // with a controller does not rebuild its parent on its own, and
    // without this the button stays grey until something else happens
    // to redraw the page.
    for (final c in [_email, _password]) {
      c.addListener(_onTyping);
    }
    if (passkeysAvailable) {
      passkeysUsable().then((yes) {
        if (mounted && yes) setState(() => _passkeyUsable = true);
      });
    }
  }

  /// Sign in with a passkey.
  ///
  /// No email is typed and none is sent: the browser offers whichever
  /// accounts hold a passkey for this site and the person picks one.
  /// That is why this cannot leak which addresses exist — the question
  /// is never asked.
  Future<void> _passkeySignIn() async {
    // The same gate the password form has, and it was missing here.
    // GoTrue checks the captcha before it checks anything else, so a
    // passkey press without a token came back "captcha protection:
    // request disallowed (no captcha_token found)" — a sentence written
    // for whoever wrote GoTrue, in front of somebody who pressed a
    // button with a fingerprint on it.
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final result = await signInWithPasskey(
      ref.read(supabaseProvider).auth,
      captchaToken: _captchaToken,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      // A dismissed prompt says nothing. Somebody who closed it did so
      // on purpose, and "that did not work" is the app arguing with
      // them about a decision they just made.
      _error = result.outcome == PasskeyOutcome.failed
          ? (result.message ?? 'That passkey was not accepted.')
          : null;
    });
    // Anything but a success has spent the token, a dismissed prompt
    // included: the call reached GoTrue either way. The button above
    // is disabled until the check passes again, so without this the
    // screen would sit there with nothing to press.
    if (result.outcome != PasskeyOutcome.signedIn) _challengeAgain();
    // Signed in needs no navigation: `verifyAuthentication` saves the
    // session and fires `signedIn`, and the router is already watching
    // for it — the same ending the password form has.
  }

  @override
  void dispose() {
    for (final c in [_email, _password]) {
      c.removeListener(_onTyping);
    }
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    _phone.dispose();
    _confirmPassword.dispose();
    _businessName.dispose();
    _stateText.dispose();
    _captcha.dispose();
    super.dispose();
  }

  /// Whether this address asks the email first.
  ///
  /// Only a company's door and an address of ours, because only those
  /// are for a known set of people. The bare domain keeps the one-step
  /// form it has always had: there is nobody there to not be.
  ///
  /// Read rather than awaited, and that is safe here in a way it was
  /// not in `_refuseIfNotTheirDoor`: this decides the shape of a form,
  /// not whether somebody gets in. A lookup still in flight shows the
  /// one-step form, and the checks after the password still refuse
  /// whoever should be refused.
  bool get _asksEmailFirst =>
      !_isSignUp &&
      ref.watch(workspaceLookupProvider).valueOrNull?.host ==
          WorkspaceHost.found;

  /// Whether the platform is taking new registrations.
  ///
  /// Read rather than awaited, for `_asksEmailFirst`'s reason and with
  /// a stronger one behind it: this only decides the shape of a form.
  /// The trigger on `auth.users` is what refuses a registration, so a
  /// lookup still in flight — or a deployment whose `signup_reference`
  /// predates `0563` — draws the form and the database still says no.
  ///
  /// Open by default, deliberately. Closing registration because a
  /// query had not answered yet would be the failure of a lookup
  /// wearing the face of a decision.
  bool get _signupsOpen =>
      ref.watch(signupReferenceProvider).valueOrNull?.signupsOpen ?? true;

  /// What to say to somebody who came to register and cannot.
  String? get _signupsClosedNotice => _signupsOpen
      ? null
      : closedNotice(
          ref.watch(signupReferenceProvider).valueOrNull?.closedMessage,
        );

  /// Ask whether this email has any business here, before taking a
  /// password it may be about to refuse.
  Future<void> _checkEmail() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _unconfirmed = false;
    });
    try {
      final allowed =
          await ref
                  .read(supabaseProvider)
                  .rpc(
                    'may_sign_in_here',
                    params: {'p_host': Uri.base.host, 'p_email': email},
                  )
              as bool? ??
          true;
      if (!mounted) return;
      if (!allowed) {
        // The wording asked for. It is the honest answer — this address
        // is for a particular set of people and this is not one of them
        // — and it is also the sentence that makes this an oracle,
        // which `0347` sets out at length.
        setState(() {
          _busy = false;
          _error = 'User not found';
        });
        return;
      }
    } catch (_) {
      // Unreachable server: go on to the password rather than refuse.
      // The checks after it still run, and refusing somebody because a
      // request timed out is the worse of the two wrong answers.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await askForPassword();
  }

  /// The second step: the password, in a box of its own.
  ///
  /// Separated from [_checkEmail] so a test can open it without an
  /// email round trip, and named without an underscore for the same
  /// reason [showRefusal] is.
  @visibleForTesting
  Future<void> askForPassword() => showDialog<void>(
    context: context,
    // Nothing outside the box dismisses it. See the `PopScope` in
    // [PasswordDialogState.build] for why.
    barrierDismissible: false,
    builder: (dialogContext) => PasswordDialog(
      email: _email.text.trim(),
      label: _passwordLabel ?? 'Password',
      action: _signInLabel ?? 'Sign in',
      onSubmit: (password) => _signInWithPassword(password, dialogContext),
    ),
  );

  /// Sign in with what was typed in the box, and say what to put back
  /// in it — null when there is nothing to say and the box should go.
  ///
  /// The box stays up until there is an answer, and a refusal arrives
  /// inside it. It used to close the moment the password was accepted
  /// and then spend two round trips deciding — a window with no box, no
  /// spinner and a form that answered nothing, which is most of what
  /// made this feel broken. There is still never a dialog on top of a
  /// dialog, because now there is only ever the one.
  Future<String?> _signInWithPassword(
    String password,
    BuildContext dialogContext,
  ) async {
    String? failure;
    await vettedSignIn(
      hold: (held) => ref.read(vettingProvider.notifier).state = held,
      signIn: () async {
        try {
          await ref
              .read(supabaseProvider)
              .auth
              .signInWithPassword(
                email: _email.text.trim(),
                password: password,
                captchaToken: _captchaToken,
              );
        } on AuthException catch (e) {
          await _noteRefusal(e);
          failure = e.message;
        }
      },
      vet: () async {
        if (failure != null) return;
        final refusal = await _refusal();
        if (refusal == null) {
          if (dialogContext.mounted) Navigator.pop(dialogContext);
          return;
        }
        // Signed out first, and that is what keeps them here: the
        // router sends a signed-in visitor at `/signin` on to their
        // books, so leaving the session in place would move them off
        // the page the message is on.
        await ref.read(supabaseProvider).auth.signOut();
        failure = refusal;
      },
    );
    return failure;
  }

  /// Redraw when what is typed changes whether the button may be
  /// pressed, and not otherwise.
  ///
  /// Guarded rather than a bare `setState`: this fires on every
  /// keystroke, and rebuilding a form of fifteen fields per character
  /// is work nobody asked for. Only the transition matters.
  bool _wasReady = false;
  void _onTyping() {
    final ready = _formReady;
    if (ready == _wasReady) return;
    setState(() => _wasReady = ready);
  }

  /// Whether the form has everything it needs to be submitted.
  ///
  /// The button is DISABLED rather than refusing on press. A press that
  /// answers "complete the security check first" is a press that taught
  /// somebody nothing they could not see, and the check is right there
  /// above the button saying whether it has passed.
  ///
  /// Three things, and each is skipped when it does not apply:
  ///
  ///   * the check, when one is configured at all. A deployment with no
  ///     Turnstile key has no widget and nothing to wait for;
  ///   * an email, always;
  ///   * a password -- except on a company's door, where the first step
  ///     asks only for the address and the password box is not drawn
  ///     yet. Requiring one there would be a button that never enables.
  bool get _formReady {
    if (_email.text.trim().isEmpty) return false;
    if (!_asksEmailFirst && _password.text.isEmpty) return false;
    return !_captchaPending;
  }

  /// Throw the spent token away and run the check again.
  ///
  /// Called after every refusal that leaves somebody on this screen
  /// wanting another go. GoTrue spends the token on the attempt
  /// whether the attempt succeeded or not, so carrying on with it is
  /// how one mistyped password turns into a form that cannot be
  /// submitted at all.
  void _challengeAgain() {
    if (!captchaOn(_brand?.turnstileSiteKey)) return;
    setState(() => _captchaToken = null);
    _captcha.reset();
  }

  /// Whether the security check still has to be passed.
  ///
  /// Asked before anything is sent, because GoTrue's refusal for a
  /// missing token names the token rather than the box on the screen,
  /// and somebody reading that has no idea what to do next.
  bool get _captchaPending =>
      captchaOn(_brand?.turnstileSiteKey) && _captchaToken == null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _unconfirmed = false;
    });

    final auth = ref.read(supabaseProvider).auth;
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          captchaToken: _captchaToken,
          // The number goes as two halves and the database puts them
          // together — `app.phone_e164`, called by `handle_new_user` —
          // so the trunk-prefix zero is dropped by the same rule
          // whoever is registering somebody.
          data: {
            'full_name': _fullName.text.trim(),
            'salutation': _salutation ?? '',
            'phone_dial': _dialCode,
            'phone_national': _phone.text.trim(),
            'use_kind': storedUseKind(_use),
            // Only what was actually asked. An empty string for a
            // person would be a person with a blank company name on
            // their profile, and `handle_new_user` would have to
            // decide what that meant.
            if (_use == UseKind.business) ...{
              'business_name': _businessName.text.trim(),
              'entity_type': _entityType,
            },
            'country_code': _country,
            // A `ref_states` code inside Malaysia and whatever was
            // typed outside it, which is what `create_organization`
            // already does with the same column and for the same
            // reason: storing a Malaysian code for a Thai province
            // would be the dishonest half of the two.
            'state_code': _malaysian
                ? (_stateCode ?? '')
                : _stateText.text.trim(),
          },
        );
        // With email confirmation enabled there is no session yet.
        if (res.session == null && mounted) {
          setState(() {
            _notice = 'Check your inbox to confirm your email, then sign in.';
            _isSignUp = false;
          });
        }
      } else {
        // The hold goes up before the password is sent, not after it
        // comes back: the session appears the instant
        // `signInWithPassword` returns and the router watches the
        // session, so a gap there is long enough to move somebody into
        // the app on a session these checks are about to revoke. That
        // is the "in, then out, then a dialog" that made a decision
        // look like a fault.
        await vettedSignIn(
          hold: (held) => ref.read(vettingProvider.notifier).state = held,
          signIn: () => auth.signInWithPassword(
            email: _email.text.trim(),
            password: _password.text,
            captchaToken: _captchaToken,
          ),
          // Two ways a correct password is still the wrong way in, and
          // the second is only worth asking once the first has passed:
          // a refusal signs the session out, and asking "may this
          // account open the till" with no account gets the answer no
          // for a reason that is not theirs.
          vet: () async {
            if (await _refuseIfNotTheirDoor()) return;
            await _refuseIfModuleNotActive();
          },
        );
      }
    } on AuthException catch (e) {
      await _noteRefusal(e);
      if (mounted) {
        setState(() {
          _error = e.message;
          // Kept beside the message because the code is the stable
          // half: older GoTrue sends only the sentence, newer ones
          // send both, and the offer below has to work against either.
          _unconfirmed = looksUnconfirmed(code: e.code, message: e.message);
        });
        // The attempt spent the token even though it failed. Without a
        // fresh one the next press is refused for the captcha rather
        // than for the password, and one typo becomes a dead end.
        _challengeAgain();
      }
    } catch (e) {
      // The readable half, never the class name and the status code.
      if (mounted) {
        setState(() => _error = resendFailureDetail('$e'));
        _challengeAgain();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sends the confirmation link again.
  ///
  /// Offered only where it is the answer: an address that exists and
  /// has not been confirmed. Everything else about a failed sign-in --
  /// wrong password, no such account -- is a different problem, and a
  /// button that emailed somebody in those cases would be a way to
  /// find out whether an address is registered.
  Future<void> _resendConfirmation() async {
    final email = _email.text.trim();
    if (email.isEmpty) return;
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref
          .read(supabaseProvider)
          .auth
          .resend(
            type: OtpType.signup,
            email: email,
            // Back to this page, where the sign-in form is. Web only: on
            // mobile the deep link is configured in the project rather
            // than sent per request, and passing an http URL there would
            // send somebody to a browser instead of the app.
            emailRedirectTo: kIsWeb ? '${Uri.base.origin}/#/signin' : null,
            captchaToken: _captchaToken,
          );
      if (mounted) {
        setState(() => _notice = resendConfirmationSent(email));
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (looksRateLimited(code: e.code, message: e.message)) {
          _notice = resendConfirmationTooSoon;
        } else if (looksMailFailure(code: e.code, message: e.message)) {
          // Not the address: the mail server turned away the login
          // GoTrue makes to it (`docs/email-setup.md`), and the only
          // thing anybody reading the banner can do about that is
          // tell somebody who can change the setting.
          _error = resendConfirmationMailBroken;
        } else {
          _error = resendConfirmationFailed(resendFailureDetail(e.message));
        }
      });
    } catch (e) {
      if (mounted) {
        // Whatever this is, it is not a sentence: a JSON body or a
        // `toString` naming a class. `resendFailureDetail` keeps the
        // part somebody can read and drops the rest.
        setState(
          () => _error = resendConfirmationFailed(resendFailureDetail('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Turn away somebody whose account cannot open what this address
  /// opens.
  ///
  /// `0346`. `pos.iakauntan.com` is the till and nothing else, so an
  /// account with no till has nowhere to arrive. The app used to let
  /// them in and then redirect to a screen saying no, which is a screen
  /// where a sentence would do — and which leaves somebody signed in to
  /// a product they cannot use, the way out being to find Sign out on a
  /// page that exists to tell them off.
  ///
  /// So: signed out again, left on the form they were already looking
  /// at, and told which module it is in a dialog rather than in small
  /// red text under a field. The dialog is deliberate — this is not a
  /// typo in a password, it is the wrong account for this address, and
  /// the next thing to do is sign in as somebody else.
  ///
  /// A failure to reach the server leaves the session alone, the same
  /// choice [_refuseIfNotTheirDoor] makes: refusing somebody because a
  /// request timed out is worse than letting them through to a screen
  /// the router will hold anyway.
  Future<void> _refuseIfModuleNotActive() async {
    final message = await _moduleRefusal();
    if (message == null) return;
    await refuse(title: 'Not activated', message: message);
  }

  /// What to say about the module, or null when there is nothing to
  /// say.
  ///
  /// Split from [_refuseIfModuleNotActive] so the two-step form can put
  /// the sentence inside the box the password was typed in, instead of
  /// closing that box and opening another one behind it.
  Future<String?> _moduleRefusal() async {
    final client = ref.read(supabaseProvider);
    String? refused;
    try {
      refused =
          await client.rpc(
                'workspace_module_refusal',
                params: {'p_host': Uri.base.host},
              )
              as String?;
    } catch (_) {
      return null;
    }
    if (refused == null) return null;
    return 'This address opens $refused, and that is not switched '
        'on for your company. Ask whoever looks after your '
        'subscription, or sign in at iakauntan.com to reach the rest '
        'of your books.';
  }

  /// Sign the session out and say why, without moving anybody.
  ///
  /// A dialog rather than the small red text under a field, and the
  /// difference is what kind of problem this is. Red text under a field
  /// is for a typo — try again, the form is still the thing you are
  /// doing. Neither of these is a typo: the password was right and the
  /// account is wrong for this address, so the next thing to do is sign
  /// in as somebody else, and that deserves an interruption.
  ///
  /// Signed out first, and that is what keeps them here: the router
  /// sends a signed-in visitor at `/signin` on to their books, so
  /// leaving the session in place would move them off the page the
  /// message is on.
  Future<void> refuse({required String title, required String message}) async {
    await ref.read(supabaseProvider).auth.signOut();
    if (!mounted) return;
    await showRefusal(title: title, message: message);
  }

  /// The saying-so half of [refuse], separately because it is the half
  /// worth pressing: what a refusal *looks* like is the whole of this
  /// change, and a test that has to stand up a signed-in Supabase to
  /// see it would be asserting the fake.
  @visibleForTesting
  Future<void> showRefusal({required String title, required String message}) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );

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
  Future<bool> _refuseIfNotTheirDoor() async {
    // Asked at every address, always. It used to start with
    //
    //     final workspace = ref.read(workspaceHostProvider).valueOrNull;
    //     if (workspace == null) return false;
    //
    // which is a synchronous read of an asynchronous lookup: null means
    // "not back yet" just as often as it means "not a company's door",
    // and the two were treated the same. Somebody who typed a password
    // faster than the lookup came back was not refused — the check
    // simply did not run, silently, and Sinar's door let anybody in.
    //
    // The guard bought nothing either. `may_use_workspace` answers
    // *true* for the bare domain and for a name nobody holds, and says
    // in its own comment why it has to: answering false there would
    // lock everybody out of the platform. There was never a host it was
    // unsafe to ask about.
    final message = await _doorRefusal();
    if (message == null) return false;
    await refuse(title: 'Not your workspace', message: message);
    return true;
  }

  /// What to say about the door, or null when the door is theirs.
  ///
  /// The other half of [_refuseIfNotTheirDoor], split for the reason
  /// [_moduleRefusal] is.
  Future<String?> _doorRefusal() async {
    final client = ref.read(supabaseProvider);
    bool allowed;
    try {
      allowed =
          await client.rpc(
                'may_use_workspace',
                params: {'p_host': Uri.base.host},
              )
              as bool? ??
          true;
    } catch (_) {
      return null;
    }
    if (allowed) return null;

    // Only now is the name wanted, and only for the wording — so a
    // lookup still in flight costs a less specific sentence rather than
    // the whole refusal.
    return notTheirDoorMessage(
      ref.read(workspaceHostProvider).valueOrNull?['name'] as String?,
    );
  }

  /// Both questions at once, the door's answer first.
  ///
  /// They used to be asked one after the other, which is two round
  /// trips end to end between the password being accepted and anything
  /// appearing — and, because the box had already closed, two round
  /// trips of a form that looks idle and answers nothing. They do not
  /// depend on each other, so they go together and cost one.
  Future<String?> _refusal() async {
    final answers = await Future.wait([_doorRefusal(), _moduleRefusal()]);
    return answers[0] ?? answers[1];
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
    // A demo account is an ordinary account, so GoTrue asks it for a
    // captcha token like anybody else. Without this the press was
    // refused with a 400 and reported below as "the demo accounts are
    // not available on this deployment" -- a wrong cause, confidently
    // stated, about accounts that were there all along.
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }
    setState(() {
      _demoBusy = account.email;
      _error = null;
      _notice = null;
    });
    try {
      // Held and checked like the form's own sign-in. A demo account is
      // an ordinary account with its password written on the screen, so
      // it reaches a company's door and a confined address exactly as
      // anybody else's does — and without this it did so unvetted,
      // which made it the one way into the app that asked nothing.
      await vettedSignIn(
        hold: (held) => ref.read(vettingProvider.notifier).state = held,
        signIn: () => ref
            .read(supabaseProvider)
            .auth
            .signInWithPassword(
              email: account.email,
              password: demoPassword,
              captchaToken: _captchaToken,
            ),
        vet: () async {
          if (await _refuseIfNotTheirDoor()) return;
          await _refuseIfModuleNotActive();
        },
      );
    } on AuthException catch (e) {
      if (!mounted) return;
      // The likeliest cause by far is that the demo users were deleted
      // before the project took real books, which is exactly what the
      // README tells you to do. Saying "invalid login credentials" would
      // send somebody hunting for a typo in a password they never typed.
      // A 400 that mentions the captcha is the security check refusing,
      // not an absent account. Reporting it as absent sends somebody to
      // look for a deployment problem that is not there -- which is
      // exactly what happened once the dashboard protection went on.
      final captchaRefusal = e.message.toLowerCase().contains('captcha');
      setState(
        () => _error = captchaRefusal
            ? captchaNotDone
            : e.statusCode == '400'
            ? 'The demo accounts are not available on this deployment.'
            : e.message,
      );
      // The same spent token as the form's. A visitor who pressed the
      // wrong demo role, or pressed once while the check was stale,
      // should be able to press another.
      _challengeAgain();
    } catch (e) {
      if (mounted) {
        setState(() => _error = resendFailureDetail('$e'));
        _challengeAgain();
      }
    } finally {
      if (mounted) setState(() => _demoBusy = null);
    }
  }

  /// A link in the inbox instead of a password in the box.
  ///
  /// Deliberately the same shape as [_resetPassword] below, down to the
  /// order of the checks: they are the same form, the same box, and the
  /// same way of filling somebody's inbox using nothing but their
  /// address. What differs is the clock — asking for a sign-in link is
  /// not asking for a reset — and what arrives.
  Future<void> _sendMagicLink() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email first.');
      return;
    }
    // The demo accounts share a fixed password and nobody reads their
    // inbox. Said here rather than after somebody has gone looking.
    if (demoAccounts.any((a) => a.email.toLowerCase() == email.toLowerCase())) {
      setState(
        () => _error =
            'The demo accounts have no inbox to send a link to. Use the '
            'buttons below to sign in.',
      );
      return;
    }
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }
    if (!looksLikeAnAddress(email)) {
      setState(() {
        _notice = null;
        _error = resetBadAddress;
      });
      return;
    }

    final left = remainingWait(_lastLinkAt, DateTime.now());
    if (left > Duration.zero) {
      setState(() {
        _error = null;
        _notice = magicLinkTooSoon(left);
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref
          .read(supabaseProvider)
          .auth
          .signInWithOtp(
            email: email,
            // Aimed at this deployment rather than left to the
            // project's Site URL, for the reason the reset link is: a
            // preview build otherwise sends people to production.
            emailRedirectTo: kIsWeb ? Uri.base.origin : null,
            // `false`, and it is the whole of the difference between
            // this and registration. The default CREATES an account for
            // any address typed into the box, so a sign-in form would
            // silently become a sign-up form — on a platform whose
            // operator may have switched registration off entirely.
            shouldCreateUser: false,
            captchaToken: _captchaToken,
          );
      if (mounted) {
        setState(() {
          _lastLinkAt = DateTime.now();
          _notice = magicLinkSent(email);
        });
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        final wait = statedWait(e.message);
        if (wait != null) {
          // The server's own rate limit. Its clock, not ours: told to
          // wait forty seconds, saying "sixty" would be a second wrong
          // answer on top of the first.
          _lastLinkAt = DateTime.now().subtract(resetCooldown - wait);
          _notice = magicLinkTooSoon(wait);
        } else {
          // Everything else, including "signups not allowed" — which is
          // what GoTrue answers for an address with no account when
          // `shouldCreateUser` is false, and which must NOT be shown as
          // itself: it would turn this form into a way to find out who
          // has an account here by typing.
          _notice = magicLinkSent(email);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
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
      setState(
        () => _error =
            'The demo accounts share a fixed password, so it cannot be reset. '
            'Use the buttons below to sign in.',
      );
      return;
    }
    if (_captchaPending) {
      setState(() => _error = _captchaBroken ? captchaBroken : captchaNotDone);
      return;
    }

    // The half of "no such account" that can be answered honestly with
    // nothing but the text in the box. A missing @ or a domain with no
    // dot is a typo we can name on the spot, and naming it beats
    // sending a link nowhere and leaving somebody waiting for it.
    if (!looksLikeAnAddress(email)) {
      setState(() {
        _notice = null;
        _error = resetBadAddress;
      });
      return;
    }

    // Held here rather than only at the server. The project's security
    // interval is seconds, and a reset link that can be asked for every
    // few seconds is a way to fill somebody's inbox using nothing but
    // their address.
    final left = remainingWait(_lastResetAt, DateTime.now());
    if (left > Duration.zero) {
      setState(() {
        _error = null;
        _notice = tooSoonMessage(left);
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref
          .read(supabaseProvider)
          .auth
          .resetPasswordForEmail(
            email,
            // Aim the link at the reset screen rather than leaving it to
            // the project's Site URL, so a preview deployment sends
            // people back to that preview instead of production. The
            // origin has to be in Supabase's redirect allow list.
            redirectTo: kIsWeb ? '${Uri.base.origin}/#/reset-password' : null,
            captchaToken: _captchaToken,
          );
      if (mounted) {
        setState(() {
          _lastResetAt = DateTime.now();
          _notice = resetSent(email);
        });
      }
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        if (looksUnknownAddress(code: e.code, message: e.message)) {
          // Only where the SERVER said it. Current GoTrue answers the
          // same for an address it knows and one it does not, on
          // purpose — two different answers here would let anybody
          // find out who has an account by typing addresses — so this
          // repeats what was already said rather than asking.
          _error = resetNoAccount;
        } else if (looksTooSoon(code: e.code, message: e.message)) {
          // Waiting is not a failure, so it is a notice rather than an
          // error — and the wait shown is ours where the server names a
          // shorter one, because the next request would be refused by
          // this screen anyway.
          final stated = statedWait(e.message) ?? resetCooldown;
          final wait = stated < resetCooldown ? resetCooldown : stated;
          _lastResetAt = DateTime.now().subtract(resetCooldown - wait);
          _notice = tooSoonMessage(wait);
        } else {
          _error = resendConfirmationFailed(resendFailureDetail(e.message));
        }
      });
    } catch (e) {
      // Never the raw exception. `AuthApiException(message: ...,
      // statusCode: 429, code: ...)` in front of somebody who pressed
      // one button tells them the name of a Dart class and buries the
      // one fact they needed.
      if (mounted) {
        setState(
          () => _error = resendConfirmationFailed(resendFailureDetail('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Opens the socket for somebody who is not signed in, so a change
    // in the console reaches this page while it is open. Everything on
    // this screen is an operator's setting now, and a settings screen
    // whose effect you can only see by reloading is one people stop
    // trusting.
    ref.watch(platformLiveProvider);

    final scheme = Theme.of(context).colorScheme;

    // TWO questions, and they are not the same question.
    //
    // Is there room for a second column? That is width, and 900 is the
    // number: the form is capped at 400 and the panel needs the rest.
    //
    // And is this a phone? That is the SHORTEST side, which does not
    // change when the device is rotated, so it asks what kind of screen
    // this is rather than which way up it is being held. A phone held
    // sideways is 915 by 412, and on the strength of that 915 it used to
    // get the desktop layout -- which put the Sign in button below the
    // fold on a screen 412 tall, so the one thing the page exists for
    // was off-screen and the panel beside it was decoration. 600 is the
    // conventional line between a handset and everything larger.
    //
    // Asking only the second question is what this was for one commit,
    // and it took the panel off every DESKTOP. The reasoning written
    // here was "a laptop is at least 900 both ways round", which is
    // simply false: a laptop is 1440 by about 760 once the browser's own
    // chrome is off the viewport, so `shortestSide >= 900` is false on
    // very nearly every desktop there is. The points beside the form
    // went missing and it was reported from a browser within the hour.
    //
    // Both, then. A shape only counts as wide if it is wide AND is not a
    // handset.
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 900 && size.shortestSide >= 600;

    // Nothing but the circle until there is something true to draw.
    // A page that is loading looks like a page that is loading; the
    // shipped labels and no panel, replaced a moment later, is a
    // different product appearing and then leaving.
    if (!_settled) return const PageWaiting();

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
                if (!wide && (_showLogo || _showName)) ...[
                  _Brand(logo: _showLogo, name: _showName),
                  const SizedBox(height: 32),
                ],
                if (_showHeading) ...[
                  Text(
                    _copy?.title ??
                        (_isSignUp ? 'Create your account' : 'Welcome back'),
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    // Three pieces, and only two of them are anybody's
                    // to type: the heading above, this lead-in, and the
                    // name — which is the company's at its own door and
                    // the platform's everywhere else, and is never
                    // typed here because platform-wide copy cannot say
                    // "Sinar".
                    //
                    // Joined here rather than stored as one sentence so
                    // that an operator writing "Log masuk untuk teruskan
                    // ke" gets their words in front of a name they did
                    // not have to know.
                    '${_copy?.body ?? _defaultLeadIn} '
                    '${_workspace ?? _wordmark}.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                ],
                if (_isSignUp) ...[
                  // Every one of these is required. A registration that
                  // takes a title and a number when it feels like it is
                  // a profile that is half empty and a letter nobody
                  // can address.
                  // Asked here rather than on the first screen of
                  // setup. Registration already collects five things;
                  // handing somebody to a screen whose first act is to
                  // ask a sixth is a question in the wrong place.
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      useQuestion(SetupAudience.own),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Three answers and no icons. Two fitted a phone
                  // with a glyph each; three do not, and a
                  // SegmentedButton does not wrap -- it clips, so the
                  // third answer would be a truncated word somebody
                  // taps without being able to read. The words carry
                  // it on their own.
                  SegmentedButton<UseKind>(
                    key: const ValueKey('signup-use'),
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: UseKind.business,
                        label: Text(businessTitle),
                      ),
                      ButtonSegment(
                        value: UseKind.accountant,
                        label: Text(accountantTitle),
                      ),
                      ButtonSegment(
                        value: UseKind.personal,
                        label: Text(personalTitle(SetupAudience.own)),
                      ),
                    ],
                    selected: {_use},
                    onSelectionChanged: (v) => setState(() => _use = v.first),
                  ),
                  // What the answer means, in one line. A word on a
                  // segment cannot say that "Accountant" brings
                  // Multi-Company with it, and somebody choosing
                  // between three answers is entitled to know what
                  // each one does before they choose.
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(switch (_use) {
                      UseKind.business => businessBlurb,
                      UseKind.accountant => accountantBlurb,
                      UseKind.personal => personalBlurb(SetupAudience.own),
                    }, style: Theme.of(context).textTheme.bodySmall),
                  ),
                  const SizedBox(height: 14),
                  // Asked here rather than on the first screen of
                  // setup, for the same reason the question above is:
                  // setup's opening act was to ask a company for its
                  // name, which is the one thing somebody registering
                  // a company has certainly got to hand.
                  if (_use == UseKind.business) ...[
                    TextFormField(
                      key: const ValueKey('signup-business-name'),
                      controller: _businessName,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Company name *',
                        hintText: 'e.g. Sinar Teknologi Sdn Bhd',
                      ),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Enter the company name'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    Consumer(
                      builder: (context, ref, _) {
                        // `0607`. The kinds of business are a table an
                        // administrator adds to, and they reach this
                        // screen through `signup_reference()` because
                        // nobody here is signed in.
                        //
                        // The constant is the fallback rather than the
                        // source: a deployment whose function predates
                        // 0607 answers without the list, and a sign-up
                        // form that cannot offer an entity type is a
                        // sign-up form nobody can finish.
                        final offered = signupEntityTypes(
                          ref
                              .watch(signupReferenceProvider)
                              .valueOrNull
                              ?.entityTypes,
                        );
                        return DropdownButtonFormField<String>(
                          key: const ValueKey('signup-entity-type'),
                          // Without this the longest label -- "Limited
                          // Liability Partnership" -- is laid out at
                          // its natural width and overflows the sign-up
                          // column, which in a release web build is not
                          // a striped bar but a line of text running
                          // off the card. It ellipsises instead.
                          isExpanded: true,
                          value: offered.containsKey(_entityType)
                              ? _entityType
                              : offered.keys.first,
                          decoration: const InputDecoration(
                            labelText: 'Entity type',
                          ),
                          items: [
                            for (final e in offered.entries)
                              DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                          ],
                          onChanged: (v) => setState(
                            () => _entityType = v ?? offered.keys.first,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 14),
                  ],
                  Consumer(
                    builder: (context, ref, _) {
                      final titles =
                          ref
                              .watch(signupReferenceProvider)
                              .valueOrNull
                              ?.salutations ??
                          const <Map<String, dynamic>>[];
                      // A picker rather than a dropdown: there are more
                      // than a hundred of these, and somebody looking
                      // for Datuk Seri Panglima should be able to type
                      // it. The group is a keyword as well as a second
                      // line, so "royal" or "religious" finds a row
                      // whose title alone would not.
                      return SearchablePicker<String>(
                        key: const ValueKey('signup-salutation'),
                        label: '$salutationFieldLabel *',
                        value: _salutation,
                        options: [
                          for (final t in titles)
                            PickerOption(
                              value: '${t['name']}',
                              label: '${t['name']}',
                              sublabel: salutationSublabel(t),
                              keywords: [
                                '${t['grouping'] ?? ''}',
                                '${t['note'] ?? ''}',
                                '${t['code'] ?? ''}',
                              ],
                            ),
                        ],
                        onChanged: (v) => setState(() => _salutation = v),
                        validator: (_) => salutationError(_salutation),
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _fullName,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: _brand?.signinNameLabel ?? 'Full name',
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Enter your name' : null,
                  ),
                  const SizedBox(height: 14),
                  Consumer(
                    builder: (context, ref, _) {
                      final reference = ref
                          .watch(signupReferenceProvider)
                          .valueOrNull;
                      final codes = withDialCodes(
                        reference?.dialCodes ?? const <Map<String, dynamic>>[],
                      );
                      // One question. The dialling code is not asked
                      // for: it is read off the country, so the two
                      // cannot disagree.
                      return SearchablePicker<String>(
                        key: const ValueKey('signup-country'),
                        label: countryFieldLabel,
                        value: codes.any((c) => c['code'] == _country)
                            ? _country
                            : null,
                        options: [
                          for (final c in codes)
                            PickerOption(
                              value: '${c['code']}',
                              label: countryPickerLabel(c),
                              sublabel: countryPickerSublabel(c),
                              keywords: [
                                '${c['alpha2']}',
                                '+${dialOf(c)}',
                                dialOf(c),
                              ],
                            ),
                        ],
                        onChanged: (v) => setState(() {
                          _country = v ?? homeCountryCodeForSignup;
                          _dialCode = dialFor(codes, _country);
                          // A state chosen for one country means
                          // nothing in another, and the list itself is
                          // Malaysian.
                          _stateCode = _malaysian ? homeStateCode : null;
                          if (!_malaysian) _stateText.clear();
                        }),
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  Consumer(
                    builder: (context, ref, _) {
                      final states =
                          ref
                              .watch(signupReferenceProvider)
                              .valueOrNull
                              ?.states ??
                          const <Map<String, dynamic>>[];
                      // The thirteen states and three federal
                      // territories are Malaysia's. Offering that list
                      // to somebody in Thailand would be offering a
                      // wrong answer, so elsewhere the box is a box.
                      if (!_malaysian) {
                        return TextFormField(
                          key: const ValueKey('signup-state-text'),
                          controller: _stateText,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            labelText: '$stateElsewhereLabel *',
                            prefixIcon: Icon(Icons.map_outlined),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'Enter your state or province'
                              : null,
                        );
                      }
                      return SearchablePicker<String>(
                        key: const ValueKey('signup-state'),
                        label: '$stateFieldLabel *',
                        value: states.any((st) => st['code'] == _stateCode)
                            ? _stateCode
                            : null,
                        options: [
                          for (final st in states)
                            PickerOption(
                              value: '${st['code']}',
                              label: '${st['name']}',
                            ),
                        ],
                        onChanged: (v) => setState(() => _stateCode = v),
                        validator: (_) =>
                            _stateCode == null ? 'Choose your state' : null,
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const ValueKey('signup-phone'),
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: '$phoneFieldLabel *',
                      prefixIcon: const Icon(Icons.phone_outlined),
                      // What the country answered, shown where the
                      // number is typed rather than in a box of its
                      // own.
                      prefixText: '+$_dialCode ',
                      // Said out loud rather than done quietly: the
                      // zero is being taken off what they typed, and a
                      // form that does that in silence gets accused of
                      // losing a digit.
                      helperText: phoneNote(
                        dialCode: _dialCode,
                        number: _phone.text,
                      ),
                      helperMaxLines: 2,
                    ),
                    validator: (v) =>
                        phoneError(dialCode: _dialCode, number: v ?? ''),
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  onFieldSubmitted: (_) =>
                      _asksEmailFirst ? _checkEmail() : null,
                  decoration: InputDecoration(
                    labelText: _emailLabel ?? 'Email',
                    prefixIcon: const Icon(Icons.mail_outline),
                  ),
                  validator: (v) {
                    final value = (v ?? '').trim();
                    if (value.isEmpty) return 'Enter your email';
                    if (!value.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                if (!_asksEmailFirst) ...[
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.password],
                    onFieldSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: _passwordLabel ?? 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (v) => passwordError(v, isNew: _isSignUp),
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const ValueKey('signup-confirm-password'),
                      controller: _confirmPassword,
                      obscureText: _obscureConfirm,
                      decoration: InputDecoration(
                        labelText: confirmPasswordLabel,
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscureConfirm
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () => setState(
                            () => _obscureConfirm = !_obscureConfirm,
                          ),
                        ),
                      ),
                      onFieldSubmitted: (_) => _submit(),
                      validator: (v) => confirmPasswordError(
                        password: _password.text,
                        confirm: v,
                      ),
                    ),
                  ],
                  if (!_isSignUp)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _resetPassword,
                        child: Text(_forgotLabel ?? 'Forgot password?'),
                      ),
                    ),
                ],
                // The security check, when one is configured. Empty
                // site key means no widget and no token, which is what
                // every one of these forms did before `0556`.
                CaptchaField(
                  key: const ValueKey('auth-captcha'),
                  siteKey: _brand?.turnstileSiteKey,
                  controller: _captcha,
                  onToken: (t) => setState(() => _captchaToken = t),
                  onFailed: () => setState(() => _captchaBroken = true),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  _Banner(message: _error!, color: context.colors.danger),
                  // The one refusal with something to do about it. An
                  // unconfirmed address used to be a dead end: every
                  // attempt answered "Email not confirmed" and the only
                  // way on was to register again with the same address,
                  // which the form does not allow.
                  if (_unconfirmed)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('resend-confirmation'),
                        onPressed: _busy ? null : _resendConfirmation,
                        icon: const Icon(
                          Icons.mark_email_unread_outlined,
                          size: 18,
                        ),
                        label: const Text(resendConfirmationLabel),
                      ),
                    ),
                ],
                if (_notice != null) ...[
                  const SizedBox(height: 12),
                  _Banner(message: _notice!, color: context.colors.success),
                ],
                // Said where the button is, rather than instead of the
                // form. Somebody who arrived here to register has to
                // read why they cannot, and a page that simply lost its
                // Create account button reads as a fault.
                if (_isSignUp && _signupsClosedNotice != null) ...[
                  const SizedBox(height: 12),
                  _Banner(
                    message: _signupsClosedNotice!,
                    color: context.colors.warning,
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  // `_asksEmailFirst` is the company-door first step,
                  // which asks `may_sign_in_here` and never GoTrue --
                  // so it needs the address and nothing else. See
                  // `_formReady`.
                  onPressed:
                      _busy ||
                          (_isSignUp && !_signupsOpen) ||
                          (_asksEmailFirst
                              ? _email.text.trim().isEmpty
                              : !_formReady)
                      ? null
                      : (_asksEmailFirst ? _checkEmail : _submit),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : _asksEmailFirst
                      ? const Text('Continue')
                      // `registerLabel` and `signInLabel` have been on
                      // `landing_page` since 0290 and this button was
                      // ignoring both, so renaming it in the console
                      // changed the landing page and not the form the
                      // button leads to.
                      : Text(
                          _isSignUp
                              ? (_brand?.registerLabel ?? 'Create account')
                              : (_signInLabel ?? 'Sign in'),
                        ),
                ),
                // `0579`. A passkey instead of a password, and only
                // when all three are true: the console switch is on,
                // the build can reach an authenticator, and the person
                // is looking at the sign-in half rather than the
                // sign-up half — there is nothing to assert against an
                // account that does not exist yet.
                //
                // Absent rather than disabled when any is missing. A
                // disabled control invites somebody to work out why,
                // and there is nothing they can do about a dashboard
                // setting or a laptop with no fingerprint reader.
                if (!_isSignUp &&
                    _passkeyUsable &&
                    (_brand?.signinShowPasskey ?? false)) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('passkey-sign-in'),
                    // The check and nothing else: a passkey IS the
                    // email and the password, so neither box has to be
                    // filled in for this to be pressable.
                    onPressed: _busy || _captchaPending ? null : _passkeySignIn,
                    icon: const Icon(Icons.fingerprint, size: 18),
                    label: const Text('Sign in with a passkey'),
                  ),
                ],
                // `0613`. A link in the inbox instead of a password.
                // Two conditions rather than the passkey's three:
                // there is no device capability to check — every
                // browser can open an email — so it is the console
                // switch and the sign-in half.
                //
                // Not on the sign-up half, and the reason is the one
                // line in `_sendMagicLink` that matters:
                // `shouldCreateUser: false`. A link that made an
                // account for any address typed into the box would
                // turn this into a registration form, on a platform
                // whose operator may have switched registration off.
                if (!_isSignUp && (_brand?.signinShowMagicLink ?? false)) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(
                    key: const ValueKey('magic-link'),
                    onPressed: _busy || _captchaPending
                        ? null
                        : _sendMagicLink,
                    icon: const Icon(Icons.mail_outline, size: 18),
                    label: const Text('Email me a link instead'),
                  ),
                ],
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
                // And not while the platform has stopped taking
                // registrations. `0563`: the trigger is what refuses
                // one, and this is so nobody is walked up to a door
                // that will not open.
                if (_workspace == null &&
                    offersRegistration(
                      signupsOpen: _signupsOpen,
                      alreadyThere: _isSignUp,
                    ) &&
                    (_isSignUp || (_brand?.signinShowRegister ?? false))) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _isSignUp = !_isSignUp;
                            _error = null;
                            _notice = null;
                            // Leaving it behind would refuse a
                            // sign-in that has nothing to confirm,
                            // and would confirm a password nobody
                            // typed on the way back.
                            _confirmPassword.clear();
                          }),
                    child: Text(
                      _isSignUp
                          ? (_brand?.signinSigninPrompt ??
                                'Already have an account? Sign in')
                          : (_brand?.signinRegisterPrompt ??
                                'New to $_wordmark? Create an account'),
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
      // The brand colour, as Material derives it. `0337` briefly let
      // this be set again on the sign-in screen; `0340` took that back
      // out — a platform has one colour, chosen once under Branding,
      // and a second field for it is a second answer to the same
      // question.
      panel: scheme.primary,
      ink: scheme.onPrimary,
      showLogo: _showLogo,
      showName: _showName,
      headline: _showHeadline
          ? (_headline ?? LandingContent.defaultSigninHeadline)
          : null,
      points: _points,
    );

    if (!wide || hero.isEmpty) return Scaffold(body: form);

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              key: const Key('signin-panel'),
              // The operator's colour if they chose one, and the brand
              // colour if they did not — which is what the panel was
              // before there was anything to choose.
              color: hero.panel,
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
    required this.showLogo,
    required this.showName,
    required this.headline,
    required this.points,
    required this.panel,
    required this.ink,
  });

  final bool showLogo;
  final bool showName;
  final String? headline;
  final List<LandingSection> points;

  /// The colour the panel is actually painted.
  final Color panel;

  /// Ink that can be read on it.
  ///
  /// `onPrimary` rather than something derived here: the panel is
  /// `primary`, and Material guarantees the pair is legible however
  /// the operator's brand colour was seeded. Deriving it again would be
  /// a second opinion about a question the scheme has already answered.
  final Color ink;

  bool get isEmpty =>
      !showLogo && !showName && headline == null && points.isEmpty;
}

/// The mark, on the way in.
///
/// Reads the same brand the landing page does — the uploaded logo and
/// the wordmark, or a company's own where this is a company's own door.
///
/// ## There is no drawn fallback any more
///
/// Until `0337` a platform with no logo uploaded got a compiled-in
/// wallet icon in a rounded square. That is this product's mark, drawn
/// on somebody else's sign-in page, and a visitor cannot tell it from a
/// real one — which makes it worse than nothing rather than a
/// placeholder. So a missing logo, or one whose address will not load,
/// leaves the wordmark standing alone.
class _Brand extends ConsumerWidget {
  const _Brand({
    this.onDark = false,
    this.ink,
    this.logo = true,
    this.name = true,
  });

  /// Which halves to draw. Both default true because every caller
  /// outside the sign-in screen wants the whole mark; the sign-in
  /// screen passes `0338`'s two switches.
  final bool logo;
  final bool name;

  /// Sitting on the panel rather than on the page, which is where the
  /// dark variant of a logo earns its keep.
  final bool onDark;

  /// The colour to write the wordmark in.
  ///
  /// Passed from the panel since `0337`, because the panel's colour is
  /// the operator's own and `onPrimary` need not be readable on it.
  /// Null off the panel, where the brand colour on the page is right.
  final Color? ink;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final color = ink ?? (onDark ? scheme.onPrimary : scheme.primary);
    final brand = ref.watch(landingContentProvider).valueOrNull;

    // A company that has been given a subdomain owns this page: at
    // `sinar.iakauntan.com` the mark is Sinar's, not ours. Everywhere
    // else this is null and nothing below changes.
    final workspace = ref.watch(workspaceHostProvider).valueOrNull;

    // On the panel the light logo is the wrong one: same rule the
    // landing page uses, for the same reason.
    final url =
        workspace?['logo_url'] as String? ??
        (onDark ? brand?.logoDarkUrl : null) ??
        brand?.logoUrl;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (logo && url != null) ...[
          Image.network(
            url,
            height: 40,
            // A logo that will not load must not take the sign-in form
            // with it — this is the one screen nobody can route around
            // — and must not put our icon there instead.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          if (name) const SizedBox(width: 12),
        ],
        if (name)
          Text(
            // No literal here any more. `landing_page.wordmark` is NOT
            // NULL, so the backend answers; `LandingContent` supplies
            // the app's own build-time name only when there is no
            // payload at all, which is the one case where inventing a
            // name is worst.
            workspace?['name'] as String? ?? brand?.wordmark ?? Env.appName,
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
    final ink = content.ink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (content.showLogo || content.showName) ...[
          _Brand(
            onDark: true,
            ink: ink,
            logo: content.showLogo,
            name: content.showName,
          ),
          const SizedBox(height: 40),
        ],
        if (content.headline != null) ...[
          Text(
            content.headline!,
            style: TextStyle(
              fontSize: 34,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: ink,
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
                Icon(
                  Icons.check_circle,
                  color: ink.withValues(alpha: 0.9),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        point.title,
                        style: TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                      if (point.body != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          point.body!,
                          style: TextStyle(
                            color: ink.withValues(alpha: 0.75),
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
