/// The pages a stranger may open, named once.
///
/// `0651` added Terms of Service to the routes and to the footer and to
/// the consent line under the register button — and not to the
/// redirect's list of paths a signed-out visitor is let past. So the
/// link drew, was tappable, and bounced the reader to the sign-in form.
///
/// A page that exists, is linked from three places, and cannot be
/// opened is the exact failure a list repeated in three files produces,
/// and the only durable fix is that there is now one list. These
/// assertions are what makes that true rather than merely tidy: they
/// read the constant and the router's own behaviour, so a fifth page
/// added to one and not the other fails here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/router.dart';
import 'package:iakauntan/src/features/landing/site_page_screen.dart';

void main() {
  test('the four pages the footer links to are all public', () {
    expect(publicSitePageSlugs, [
      'terms',
      'terms-of-service',
      'privacy',
      'contact',
    ]);
  });

  test('every one of them is let past the sign-in redirect', () {
    // The assertion that would have caught `0651`. `signInRedirect`
    // returns null for a path a stranger may have, and anything else is
    // where it sends them instead.
    for (final slug in publicSitePageSlugs) {
      expect(
        publicPathNeedsNoSession('/$slug'),
        isTrue,
        reason: '/$slug is linked but not public',
      );
    }
  });

  test('and a page that is not on the list is not let past', () {
    // The control. Without it, a predicate that answered "public" to
    // everything would pass the test above and wave the whole product
    // through.
    for (final path in ['/dashboard', '/settings', '/terms-of-services']) {
      expect(publicPathNeedsNoSession(path), isFalse, reason: path);
    }
  });

  test('the terms of use and the terms of service are separate paths', () {
    // Two documents, two slugs. A rename would have been the other way
    // to satisfy the request and would have silently replaced whatever
    // an operator had already written into the terms of use.
    expect(publicSitePageSlugs.contains('terms'), isTrue);
    expect(publicSitePageSlugs.contains('terms-of-service'), isTrue);
  });
}
