import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
