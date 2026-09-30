import '../../core/surface.dart';
import '../onboarding/onboarding_copy.dart';

/// Which kinds of account a surface offers, and whether to ask at all.
///
/// "What is this for?" has three answers — a business, an accountant,
/// somebody invoicing under their own name — and not every deployment
/// wants all three on every surface. A platform selling only to
/// practices does not want a stranger registering a sole trader; one
/// whose app-store listing describes a personal invoicing app should
/// not offer "Accountant" inside the app while offering it on the web.
///
/// Per surface rather than once, for the reason `0638` gives about the
/// registration link itself: an app store has rules about who may open
/// an account and what it costs, those rules are not the website's, and
/// they change on different days. One switch between the two would mean
/// closing a door on the surface that never asked for it closed.
class SignupKinds {
  const SignupKinds._(this.offered, this.chosen);

  /// The answers to draw, in the order they are drawn. Empty when the
  /// operator has switched all three off.
  final List<UseKind> offered;

  /// What the registration is for when nobody is asked — the single
  /// remaining answer, or [UseKind.personal] where there is none.
  final UseKind chosen;

  /// Whether to draw the question.
  ///
  /// One answer is not a question. A segmented bar with a single
  /// segment is a button that cannot be pressed and cannot be
  /// unpressed, and it invites somebody to look for the other options.
  bool get asks => offered.length > 1;
}

/// What this surface offers, given the six switches.
///
/// The order is the order on screen and is deliberate: a business
/// first, because it is what most registrations are; the practice
/// second, because it is the answer that brings a paid module with it;
/// the individual last, because it is the fallback in every sense —
/// including this one.
///
/// **All three off falls back to [UseKind.personal] and asks nothing.**
/// The alternative is a registration form that cannot be submitted,
/// and an operator who has switched everything off has said what they
/// want the form to be rather than that they want no form. Personal is
/// the answer that needs nothing else to be true: no SSM number, no
/// registered name, no module.
///
/// Desktop counts as the web, the way [passkeyOffered] has it: there is
/// no desktop build, and a rule about app stores must not silently
/// become a rule about a binary nobody ships.
SignupKinds signupKinds(
  Surface surface, {
  required bool businessOnWeb,
  required bool businessInTheApps,
  required bool accountantOnWeb,
  required bool accountantInTheApps,
  required bool personalOnWeb,
  required bool personalInTheApps,
}) {
  final app = surface.isApp;
  final offered = <UseKind>[
    if (app ? businessInTheApps : businessOnWeb) UseKind.business,
    if (app ? accountantInTheApps : accountantOnWeb) UseKind.accountant,
    if (app ? personalInTheApps : personalOnWeb) UseKind.personal,
  ];
  return SignupKinds._(
    offered,
    offered.isEmpty ? UseKind.personal : offered.first,
  );
}

/// The answer to register as, given what somebody picked.
///
/// A selection can go stale: the bar is drawn from a payload, the
/// payload is re-read while the form is open, and an operator can
/// switch off the very answer somebody had already tapped. Registering
/// them as a kind the platform has withdrawn is worse than moving them,
/// so what is not offered is not what gets sent.
UseKind settledUse(SignupKinds kinds, UseKind picked) =>
    kinds.offered.contains(picked) ? picked : kinds.chosen;
