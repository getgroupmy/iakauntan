/// Coming back to the app after it was suspended.
///
/// Reported as: turning a feature on or off in the console does not show
/// on iOS or Android until the app is relaunched.
///
/// The cause was an asymmetry rather than a bug in either half.
/// `platform_live.dart` carried a lifecycle observer and an argument for
/// why a phone needs one — a suspended process loses its socket, a
/// Postgres change is fire-and-forget and never replayed, so everything
/// sent while away is simply gone. `live_updates.dart`, which carries
/// every table with an `org_id` — documents, contacts, and
/// `org_modules`, which is where a feature being on or off lives — had
/// none of it.
///
/// So the platform's own tables came back on resume and the company's
/// own did not, and nothing short of relaunching the app fixed it.
///
/// What is asserted here is the RULE and the WIRING: that both feeds
/// agree on which transitions mean "you missed something", and that the
/// org feed is now a lifecycle observer at all. The socket itself is
/// Supabase's and needs a server; what this repository owns is the
/// decision to refetch.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/live_updates.dart';
import 'package:iakauntan/src/core/platform_live.dart';
import 'package:iakauntan/src/core/socket_resume.dart';

void main() {
  group('which transitions mean something was missed', () {
    test('resuming from suspended does', () {
      // The two states in which the process was not running, so the
      // socket cannot have been alive.
      expect(
        missedWhileAway(AppLifecycleState.paused, AppLifecycleState.resumed),
        isTrue,
      );
      expect(
        missedWhileAway(AppLifecycleState.detached, AppLifecycleState.resumed),
        isTrue,
      );
    });

    test('a glance at the app switcher does not', () {
      // `inactive` is an incoming call banner, the switcher, a
      // permission sheet -- moments long, process running, socket open.
      // Refetching on those would be several queries every time
      // somebody looked at their notifications.
      expect(
        missedWhileAway(AppLifecycleState.inactive, AppLifecycleState.resumed),
        isFalse,
      );
    });

    test('and neither does going away, only coming back', () {
      for (final now in [
        AppLifecycleState.paused,
        AppLifecycleState.inactive,
        AppLifecycleState.detached,
        AppLifecycleState.hidden,
      ]) {
        expect(
          missedWhileAway(AppLifecycleState.resumed, now),
          isFalse,
          reason: '$now',
        );
      }
    });

    test('the first callback after registering is not a return', () {
      // Null `was` means the observer has only just been attached.
      // There is nothing to have missed.
      expect(missedWhileAway(null, AppLifecycleState.resumed), isFalse);
    });

    test('both feeds decide it the same way', () {
      // The reason `socket_resume.dart` exists. Copying the predicate
      // into the second feed was the other way to fix this, and it is
      // the way that rots: two rules about lifecycle states, one of
      // which somebody eventually refines.
      for (final was in [
        AppLifecycleState.paused,
        AppLifecycleState.detached,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.resumed,
        null,
      ]) {
        for (final now in AppLifecycleState.values) {
          expect(
            platformMissedWhileAway(was, now),
            missedWhileAway(was, now),
            reason: '$was -> $now',
          );
        }
      }
    });
  });

  test('the org feed is a lifecycle observer at all', () {
    // The wiring, and the whole of what was missing. `LiveUpdates` did
    // not mix in `WidgetsBindingObserver`, so there was no callback to
    // register and nothing to register it -- which is why a company's
    // own data went stale on a phone while the platform's came back.
    //
    // A type assertion rather than a behavioural one because the
    // behaviour needs a binding and a socket; that it is the right KIND
    // of object is the part that was false and is now true.
    expect(LiveUpdates(_NoRef()), isA<WidgetsBindingObserver>());
  });

  test('and answering a resume does not require a connection', () {
    // `refreshEverything` on a feed that never connected must be a
    // no-op rather than a crash: the provider is deliberately readable
    // on a signed-out app, where there is no organization to listen for
    // and no socket to have lost.
    expect(() => LiveUpdates(_NoRef()).dispose(), returnsNormally);
  });
}

/// A `Ref` that is never used.
///
/// The two assertions above construct a `LiveUpdates` and never let it
/// reach the container: one asks what type it is, the other disposes an
/// object that never connected. Anything touching `_ref` would be a
/// test asserting something else.
class _NoRef implements Ref<Object?> {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
