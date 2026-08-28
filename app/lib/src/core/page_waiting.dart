import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether every question a page's appearance depends on has an answer
/// yet.
///
/// The pages a visitor sees before signing in are all operator-edited,
/// and every one of them drew what the product shipped with while the
/// operator's version was in flight: our labels, our headline, our
/// footer, our colours — and then, a beat later, theirs. Somebody
/// opening their own company's front door saw somebody else's product
/// first, on every load.
///
/// Two of those pages had a written argument for it. The landing page
/// said a spinner would be worse because the sign-in button is on it
/// and somebody may be trying to reach their books; the sign-in screen
/// said a page that starts bare is the honest rendering. Both were
/// arguments about the *fallback* — what to draw when the answer is
/// never coming — and both are still right about that. Neither was an
/// argument for drawing the fallback during the half second before the
/// answer arrives, which is the only thing this changes.
///
/// An error counts as settled. A payload that is never coming is a real
/// answer, and the answer is "draw what we shipped with". It is only
/// the *waiting* that has no honest rendering.
bool settled(AsyncValue<Object?> value) => value.hasValue || value.hasError;

/// Every one of them settled.
bool allSettled(Iterable<AsyncValue<Object?>> values) => values.every(settled);

/// What a page draws while it is still waiting for its own words.
///
/// A circle on the page's own background, and nothing else. Deliberately
/// not a skeleton of the page to come: a skeleton is a guess at a shape
/// that the payload is about to decide — how many bullets, whether there
/// is a panel beside the form — and a guess that turns out wrong is the
/// same flicker in fainter grey.
class PageWaiting extends StatelessWidget {
  const PageWaiting({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surface,
    body: const Center(
      // Sized so it reads as one deliberate thing on an empty page
      // rather than as a stray control.
      child: SizedBox(
        height: 36,
        width: 36,
        child: CircularProgressIndicator(strokeWidth: 3),
      ),
    ),
  );
}
