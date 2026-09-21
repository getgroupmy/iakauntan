/// The line under the register button that says what pressing it means.
///
/// Asked for as: `By clicking "Register", you agree to iAkauntan's terms
/// of service and privacy policy.` Two words in that sentence are not
/// literals, and both would have been wrong on somebody's deployment.
///
/// ## The button's name, not the word "Register"
///
/// `landing_page.registerLabel` has been settable from the console
/// since `0290`, and the button reads it — so it says "Create account"
/// out of the box and whatever an operator typed after that. A consent
/// line quoting a button nobody can see is a sentence that reads as a
/// mistake, and on a legal notice that is worse than untidy: it is the
/// one sentence that has to describe the act it is attached to.
///
/// So the label is passed in and quoted, and
/// `signup_consent_test.dart` asserts the two move together.
///
/// ## The platform's name, not iAkauntan
///
/// `landing_page.wordmark` is the product's name and this codebase is
/// white-labelled — `LandingContent.wordmark` defaults to `Env.appName`
/// precisely so one place decides. A deployment that has renamed itself
/// telling its customers they agree to iAkauntan's terms would be
/// stating an agreement with a company they have never heard of.
///
/// ## Linked only where there is something to read
///
/// Terms of Service and Privacy are gated on being published (`0334`,
/// and `0651` for the second of them). An unpublished page answers
/// nothing, so a link to it lands on "this page has not been written
/// yet" — which, under a sentence claiming the reader has agreed to it,
/// is worse than no link at all.
///
/// Where the page is not published the words are still said and simply
/// are not a link. That is a deliberate half-measure: the sentence is
/// what was asked for, and the platform that has not written its terms
/// yet should see the words it is failing to back up rather than have
/// them quietly disappear.
library;

/// One run of the sentence, with the page it points at if any.
typedef ConsentSpan = ({String text, String? slug});

/// The slugs this sentence can link to, in the order it names them.
///
/// Named here rather than typed into the builder so the screen and the
/// test agree with the router about which pages exist.
const consentSlugs = <String>['terms-of-service', 'privacy'];

/// `Company's` or `Companies'`, depending on how the name ends.
///
/// A white-label whose name is already plural — "Akauntans", "Books" —
/// would otherwise be handed "Akauntans's". Small, but this is the one
/// sentence on the form somebody may read closely.
String possessive(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed.endsWith('s') || trimmed.endsWith('S')
      ? "$trimmed'"
      : "$trimmed's";
}

/// The consent sentence, split so the two page names can be links.
///
/// [buttonLabel] is what the button actually says. [brand] is the
/// product's own name. [published] is the set of site-page slugs that
/// are published; a slug outside it is named in the sentence but not
/// linked, for the reason in the library comment.
List<ConsentSpan> signupConsent({
  required String buttonLabel,
  required String brand,
  required Set<String> published,
}) {
  final label = buttonLabel.trim().isEmpty ? 'Register' : buttonLabel.trim();
  final who = possessive(brand);
  return [
    (
      text: who.isEmpty
          ? 'By clicking "$label", you agree to the '
          : 'By clicking "$label", you agree to $who ',
      slug: null,
    ),
    (
      text: 'terms of service',
      slug: published.contains('terms-of-service') ? 'terms-of-service' : null,
    ),
    (text: ' and ', slug: null),
    (
      text: 'privacy policy',
      slug: published.contains('privacy') ? 'privacy' : null,
    ),
    (text: '.', slug: null),
  ];
}

/// The whole sentence as one string, for a reader that cannot show
/// links — a screen reader label, a log line, an assertion.
String signupConsentText({
  required String buttonLabel,
  required String brand,
  required Set<String> published,
}) => signupConsent(
  buttonLabel: buttonLabel,
  brand: brand,
  published: published,
).map((s) => s.text).join();
