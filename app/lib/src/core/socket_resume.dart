/// Coming back to an app whose socket died while it was away.
///
/// One rule, shared by BOTH live feeds. `core/platform_live.dart`
/// carries the platform's own tables — the brand, the module catalogue,
/// the pages around the product — and `core/live_updates.dart` carries
/// everything belonging to a company, which is every table with an
/// `org_id`.
///
/// ## Why it is here and not in one of them
///
/// It was in `platform_live.dart`, applied to the platform feed only,
/// with a comment arguing at length why a phone needs it. The argument
/// was right and the reach was half of what it should have been: the
/// org feed — the one carrying documents, contacts and which features a
/// company has switched on — had no lifecycle handling at all.
///
/// So a change made in the console reached a browser tab and did not
/// reach a phone, and the phone's owner reported it as "it only updates
/// when I relaunch the app". Which is exactly what it was.
///
/// Copying the predicate into the second feed was the other way to fix
/// it, and it is the way that goes wrong later: two copies of a rule
/// about lifecycle states, one of which somebody eventually refines.
/// One function, two callers.
library;

import 'package:flutter/widgets.dart';

/// Whether coming back to [now] from [was] means a change may have been
/// missed.
///
/// A Postgres change and a broadcast are both FIRE AND FORGET: neither
/// is replayed, and a socket that was not open when one was sent never
/// learns of it. On a browser tab that barely matters — the tab stays
/// alive. On a phone it is the ordinary case: iOS and Android suspend
/// the process, the socket dies, and every change made in that window
/// is gone. The providers then hold what they were told last, which is
/// a screen that is confidently out of date and has no reason to
/// refetch.
///
/// So resuming from a state where the socket cannot have been alive is
/// treated as "assume something happened". [AppLifecycleState.paused]
/// and [AppLifecycleState.detached] are those states.
///
/// [AppLifecycleState.inactive] is deliberately NOT one. It is what a
/// phone reports for an incoming call banner, the app switcher, a
/// permission sheet — moments long, with the process running and the
/// socket open. Refreshing on those would be several queries every time
/// somebody glanced at their notifications.
///
/// A null [was] is not a return either: it is the first callback after
/// the observer was registered, and there is nothing to have missed.
bool missedWhileAway(AppLifecycleState? was, AppLifecycleState now) {
  if (now != AppLifecycleState.resumed) return false;
  return was == AppLifecycleState.paused || was == AppLifecycleState.detached;
}
