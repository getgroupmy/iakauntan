import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/features/admin/ios_release.dart';
import 'package:iakauntan/src/features/admin/mobile_app_admin.dart';

/// What the console says about a release, and about a build it is
/// watching.
///
/// The button itself reaches an edge function which reaches GitHub, and
/// none of that runs here. What does run here is the part that decides
/// what a person is told — and the failures in that are the ones nobody
/// reports, because a screen that says "Uploaded" about a build that
/// failed looks exactly like a screen that is working.
void main() {
  group('what each lane promises', () {
    test('TestFlight reaches your own testers', () {
      final blurb = releaseBlurb('testflight');
      expect(blurb, contains('TestFlight'));
      expect(blurb, contains('testers'));
    });

    test('and the App Store lane does not promise a release', () {
      // The assertion this file exists for. Nothing here can shorten
      // App Review, so the copy must not imply the button ships the
      // app — it uploads a build that is then ready to submit.
      final blurb = releaseBlurb('appstore');
      expect(blurb, contains('review'));
      expect(blurb, contains('hours to days'));
    });

    test('and it says where the submitting happens', () {
      // Both lanes export with `method: app-store` and both call
      // `xcrun altool --upload-app`: the lane changes what the run
      // SUMMARY says and nothing else. Somebody comparing two buttons
      // would reasonably assume picking this one submits the app, so
      // the copy has to name the place where that actually happens —
      // otherwise the screen is accurate and still leaves them with no
      // next action.
      expect(releaseBlurb('appstore'), contains('App Store Connect'));
      // And the TestFlight lane must not claim it: a build reaches
      // testers without anybody opening App Store Connect at all.
      expect(releaseBlurb('testflight'), isNot(contains('submit')));
    });

    test('and an unknown lane gets the more cautious of the two', () {
      // Rather than an empty string or a throw. If a lane ever reaches
      // here that this build does not know, the safer sentence is the
      // one that warns about review.
      expect(releaseBlurb('something-else'), releaseBlurb('appstore'));
    });
  });

  group('what a run is called', () {
    test('a run that has not finished is building, whatever else it says', () {
      // Conclusion is null while a run is in flight, and `queued` is a
      // status of its own. Both are "building" to somebody watching.
      expect(releaseState('queued', null).label, 'Building');
      expect(releaseState('in_progress', null).label, 'Building');
      // And a stale conclusion on a re-run must not win over a status
      // that says the work is happening now.
      expect(releaseState('in_progress', 'failure').label, 'Building');
    });

    test('a finished one is named by its conclusion', () {
      expect(releaseState('completed', 'success').label, 'Uploaded');
      expect(releaseState('completed', 'failure').label, 'Failed');
      expect(releaseState('completed', 'cancelled').label, 'Cancelled');
      expect(releaseState('completed', 'timed_out').label, 'Timed out');
    });

    test('a timeout is not filed under failed', () {
      // Ninety minutes of macOS runner that produced nothing, and a
      // build Apple refused, need different things looking at. Folding
      // them together would send somebody to the wrong log.
      expect(
        releaseState('completed', 'timed_out').label,
        isNot(releaseState('completed', 'failure').label),
      );
    });

    test('and a conclusion nobody has seen before is not called success', () {
      // GitHub has more conclusions than this handles — `neutral`,
      // `action_required`, `stale`. The one thing that must never
      // happen is a build being reported as uploaded when it was not.
      for (final unknown in ['neutral', 'action_required', 'stale', null]) {
        expect(releaseState('completed', unknown).label, isNot('Uploaded'));
      }
    });

    test('every state has an icon of its own', () {
      // A row is read at a glance, and two states sharing a glyph is
      // the same as one of them not being shown.
      final icons = <IconData>{
        releaseState('in_progress', null).icon,
        releaseState('completed', 'success').icon,
        releaseState('completed', 'failure').icon,
        releaseState('completed', 'cancelled').icon,
        releaseState('completed', 'timed_out').icon,
      };
      expect(icons, hasLength(5));
    });
  });

  /// What a refusal from the function means, and what it is called.
  ///
  /// This group exists because of a defect that shipped: the repository
  /// checked `res.status >= 400` on the value `functions.invoke`
  /// returns, and `invoke` does not RETURN a failure — it THROWS
  /// `FunctionException`. So the whole sentence-extraction path below
  /// was written, reviewed and never executed, and the console drew a
  /// raw `FunctionException(status: 503, details: {error: ...})` under
  /// the words "Something went wrong" at somebody whose only mistake
  /// was not having added a secret yet.
  ///
  /// The assertions are on these functions rather than on the
  /// repository because the repository needs a Supabase client. What
  /// they cannot prove is that the repository CATCHES — that is what
  /// `analyzer` and the call site have to carry, and it is why the
  /// catch clause names the mistake in a comment.
  group('a refusal, and whether it is one to worry about', () {
    test('503 is the one that means nobody has set this up', () {
      expect(releaseNotConfigured(503), isTrue);
    });

    test('and every other refusal is not', () {
      // Each of these needs something different doing about it, and
      // none of them is "add a secret". Folding them together would
      // send somebody to the wrong place: a 403 is a person without
      // the right to release, a 502 is GitHub being unreachable.
      for (final status in [400, 401, 403, 404, 500, 502, 504]) {
        expect(releaseNotConfigured(status), isFalse, reason: '$status');
      }
    });

    test('the sentence comes out of the envelope', () {
      expect(
        releaseRefusalLine({'error': 'Releasing from here is not configured.'}),
        'Releasing from here is not configured.',
      );
    });

    test('and a body that is not the envelope does not become the message', () {
      // The failure this guards is a JSON blob, or a proxy's HTML error
      // page, arriving in a snack bar — which is what made a 503 look
      // like a crash in the first place.
      expect(releaseRefusalLine(null), 'The release could not be started');
      expect(releaseRefusalLine({'unexpected': 'shape'}),
          'The release could not be started');
      expect(releaseRefusalLine({'error': 42}),
          'The release could not be started');
      expect(releaseRefusalLine({'error': '   '}),
          'The release could not be started');
      expect(releaseRefusalLine('<html><body>502 Bad Gateway</body></html>'),
          'The release could not be started');
      expect(releaseRefusalLine('x' * 400), 'The release could not be started');
    });

    test('but a short plain-text refusal is worth showing', () {
      // Something answered before the function did, and said why in a
      // sentence. Better than this screen's generic line.
      expect(releaseRefusalLine('Gateway timeout'), 'Gateway timeout');
    });

    test('and the caller can say what to fall back to', () {
      // The build LIST and the build BUTTON fail differently, and
      // "The release could not be started" is wrong on a page that
      // was only reading.
      expect(
        releaseRefusalLine(null, orElse: 'The build list could not be read'),
        'The build list could not be read',
      );
    });
  });

  group('what the card is holding', () {
    test('a list of runs is configured', () {
      expect(const IosReleases.runs([]).isConfigured, isTrue);
      expect(const IosReleases.runs([]).unavailable, isNull);
    });

    test('and "not set up" is a result, not an error', () {
      // The whole point of the type. If this were a thrown exception
      // the console would draw `ErrorState` for it, which is the
      // behaviour being fixed.
      const r = IosReleases.unavailable('It needs GITHUB_RELEASE_TOKEN.');
      expect(r.isConfigured, isFalse);
      expect(r.unavailable, 'It needs GITHUB_RELEASE_TOKEN.');
      // And it holds no runs to draw, rather than null to guard.
      expect(r.runs, isEmpty);
    });
  });
}
