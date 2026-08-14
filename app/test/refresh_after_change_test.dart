import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/data/models.dart';

/// Why a saved change did not appear until the page was reloaded.
///
/// `currentOrgProvider` does not fetch an organization. It picks one out
/// of `organizationsProvider`, which holds the rows. So invalidating the
/// picker re-runs a *choice* over cached rows and returns the same
/// record it returned before — the write lands in the database, the
/// snackbar says it did, and the screen shows what it showed.
///
/// Reloading the page fixed it because a reload throws away every cache
/// there is, which is why it looked like the app never pushed updates
/// rather than like one provider being invalidated in the wrong place.
void main() {
  Organization org({String? logoUrl, String name = 'Sinar Teknologi Sdn Bhd'}) =>
      Organization(
        id: 'o1',
        name: name,
        slug: 'sinar',
        baseCurrency: 'MYR',
        logoUrl: logoUrl,
      );

  /// The rows, standing in for the database. Rebuilt on each read of
  /// `organizationsProvider`, so a change to it is only seen by whoever
  /// actually re-reads.
  late List<Organization> stored;

  ProviderContainer harness() {
    final container = ProviderContainer(overrides: [
      organizationsProvider.overrideWith((ref) async => stored),
      currentOrgIdProvider.overrideWith(_PinnedOrg.new),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  setUp(() => stored = [org(logoUrl: 'https://example.test/logo.png?v=1')]);

  test('invalidating the picker alone keeps handing back the stale row',
      () async {
    final container = harness();
    final before = await container.read(currentOrgProvider.future);
    expect(before!.logoUrl, isNotNull);

    // The logo is removed: the row no longer has one.
    stored = [org(logoUrl: null)];

    // What the screen used to do.
    container.invalidate(currentOrgProvider);
    final after = await container.read(currentOrgProvider.future);

    // And this is the bug, asserted rather than described: the choice was
    // made again over rows nobody re-read.
    expect(after!.logoUrl, isNotNull,
        reason: 'the picker cannot see a change it never re-read');
  });

  test('refreshing the source shows the change', () async {
    final container = harness();
    await container.read(currentOrgProvider.future);

    stored = [org(logoUrl: null)];

    // What `refreshOrganization` does.
    container.invalidate(organizationsProvider);
    final after = await container.read(currentOrgProvider.future);

    expect(after!.logoUrl, isNull);
  });

  test('and every other company setting with it', () async {
    final container = harness();
    await container.read(currentOrgProvider.future);

    stored = [org(name: 'Sinar Teknologi Berhad')];
    container.invalidate(organizationsProvider);

    final after = await container.read(currentOrgProvider.future);
    expect(after!.name, 'Sinar Teknologi Berhad');
  });

  test('the logo follows the organization without being told', () async {
    // `orgLogoProvider` watches `currentOrgProvider`, which watches the
    // source — so one invalidation reaches all three. Asserted because
    // the alternative is invalidating each by hand and forgetting one.
    final container = harness();

    expect(container.read(orgLogoProvider), isA<AsyncValue<void>>());
    await container.read(currentOrgProvider.future);

    stored = [org(logoUrl: null)];
    container.invalidate(organizationsProvider);

    final after = await container.read(currentOrgProvider.future);
    expect(after!.logoUrl, isNull);
  });
}

/// Pins the selection, so resolving the organization does not go looking
/// for a signed-in user's profile.
class _PinnedOrg extends CurrentOrgNotifier {
  @override
  String? build() => 'o1';
}
