import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The reload loop, and the one property that stops it.
///
/// Diagnosed from a browser network log on the live site: opening
/// Settings reloaded the page every 1.5 to 2 seconds and, after enough
/// cycles, dropped the person at the sign-in form. 17 token refreshes
/// in one visit, every one HTTP 200, against a JWT with 57 minutes left
/// on it.
///
/// Two halves. `settings/two_factor_card.dart` holds the trigger --
/// `mfa.listFactors()` refreshes the session as a side effect of
/// reading, and it was called from `initState`. This file holds the
/// amplifier: `currentUserProvider` re-derived on EVERY auth event,
/// `tokenRefreshed` included, and twelve files watch it. One refresh
/// reloaded the whole shell, which disposed and re-created the card
/// that had asked, which asked again.
///
/// It ended in a sign-out because `/auth/v1/token` is rate-limited per
/// IP. When the loop drained the bucket the refresh came back 429, and
/// GoTrue treats a non-network `AuthException` on a refresh as fatal --
/// it drops the session and emits `signedOut`.
///
/// So the assertion that matters is a NEGATIVE one: a token refresh
/// must not change the identity. Everything else here exists so that
/// assertion cannot pass by the provider having stopped noticing
/// anything at all.
void main() {
  User user(String id, {String? updatedAt}) => User(
    id: id,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: DateTime.utc(2026, 1, 1).toIso8601String(),
    updatedAt: updatedAt,
  );

  Session session(User u) =>
      Session(accessToken: 'jwt-for-${u.id}', tokenType: 'bearer', user: u);

  AuthState event(AuthChangeEvent kind, User? u) =>
      AuthState(kind, u == null ? null : session(u));

  /// A container whose auth events this test controls, and a count of
  /// how many times the identity actually changed.
  ({
    ProviderContainer container,
    StreamController<AuthState> auth,
    List<({String? id, DateTime? updated})> seen,
  })
  harness() {
    final auth = StreamController<AuthState>();
    final container = ProviderContainer(
      overrides: [authStateProvider.overrideWith((_) => auth.stream)],
    );
    final seen = <({String? id, DateTime? updated})>[];
    container.listen(
      userIdentityProvider,
      (_, next) => seen.add(next),
      fireImmediately: false,
    );
    // Read once so the notifier is built and its listener attached.
    container.read(userIdentityProvider);
    addTearDown(() {
      container.dispose();
      auth.close();
    });
    return (container: container, auth: auth, seen: seen);
  }

  Future<void> send(
    ({
      ProviderContainer container,
      StreamController<AuthState> auth,
      List<({String? id, DateTime? updated})> seen,
    })
    h,
    AuthState state,
  ) async {
    h.auth.add(state);
    // Two pumps: one for the stream to deliver, one for Riverpod to
    // propagate.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('a token refresh does not change who is signed in', () async {
    // THE WHOLE POINT. Everything downstream of `currentUserProvider`
    // reloads when this value changes, and a refresh is not a change of
    // person.
    // This also covers the SLOW version of the same bug, which was
    // live and survivable and nobody had connected to the loop: the
    // SDK refreshes about a minute before the hourly JWT expiry, and
    // that hourly event reloaded the shell and re-created whatever
    // screen was open. A spinner, and the unsaved form state and the
    // scroll position with it, once an hour, for everybody.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    final after = h.seen.length;

    for (var i = 0; i < 5; i++) {
      await send(h, event(AuthChangeEvent.tokenRefreshed, user('u1')));
    }

    expect(h.seen.length, after, reason: 'refreshes: ${h.seen}');
  });

  test('signing in changes it', () async {
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));

    expect(h.seen.map((s) => s.id), ['u1']);
  });

  test('signing out changes it', () async {
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(h, event(AuthChangeEvent.signedOut, null));

    expect(h.seen.map((s) => s.id), ['u1', null]);
  });

  test('a different person changes it', () async {
    // The one that would be a security problem if it were filtered out:
    // the previous user's data left on screen under a new session.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(h, event(AuthChangeEvent.signedIn, user('u2')));

    expect(h.seen.map((s) => s.id), ['u1', 'u2']);
  });

  test('a changed record changes it', () async {
    // Somebody changing their email address must reach the screens that
    // print it, so `userUpdated` is not filtered.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(
      h,
      event(
        AuthChangeEvent.userUpdated,
        user('u1', updatedAt: DateTime.utc(2026, 9, 18).toIso8601String()),
      ),
    );

    expect(h.seen.length, 2);
    expect(h.seen.last.updated, DateTime.utc(2026, 9, 18));
  });

  test('a refresh AFTER a record change is still not a change', () async {
    // The reason the stamp is held in state rather than computed in a
    // `select`. A selector cannot see what it returned last, so the
    // stamp would appear on `userUpdated` and vanish on the next
    // `tokenRefreshed` -- which is a second change and a second full
    // reload of the shell, an hour after every email change.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(
      h,
      event(
        AuthChangeEvent.userUpdated,
        user('u1', updatedAt: DateTime.utc(2026, 9, 18).toIso8601String()),
      ),
    );
    final after = h.seen.length;

    await send(h, event(AuthChangeEvent.tokenRefreshed, user('u1')));

    expect(h.seen.length, after, reason: 'refreshes: ${h.seen}');
  });

  test('two record changes in a row are two changes', () async {
    // Guards against the stamp being kept so hard that a second edit is
    // swallowed -- which would leave a screen showing the address from
    // the edit before.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(
      h,
      event(
        AuthChangeEvent.userUpdated,
        user('u1', updatedAt: DateTime.utc(2026, 9, 18).toIso8601String()),
      ),
    );
    await send(
      h,
      event(
        AuthChangeEvent.userUpdated,
        user('u1', updatedAt: DateTime.utc(2026, 9, 19).toIso8601String()),
      ),
    );

    expect(h.seen.length, 3);
    expect(h.seen.last.updated, DateTime.utc(2026, 9, 19));
  });

  test('a record change with no stamp on it is still a change', () async {
    // GoTrue need not send `updated_at`. Falling back to "now" is what
    // keeps the event from being silently dropped -- and dropping it
    // would mean an email change that never reaches the screen.
    final h = harness();
    await send(h, event(AuthChangeEvent.signedIn, user('u1')));
    await send(h, event(AuthChangeEvent.userUpdated, user('u1')));

    expect(h.seen.length, 2);
    expect(h.seen.last.updated, isNotNull);
  });

  test('the notifier builds without Supabase being initialised', () {
    // It used to seed itself from `auth.currentUser`, and
    // `supabaseProvider` asserts when Supabase has not been stood up --
    // so a provider that every screen depends on could throw on build.
    // `initialSession` supplies the same value through the listener a
    // moment later.
    final h = harness();

    expect(h.container.read(userIdentityProvider), (id: null, updated: null));
  });
}
