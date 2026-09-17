import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/router.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/reserved_names_repository.dart';

/// The router decides once per navigation and then waits to be told.
///
/// Every input to `routeFor` that can still be loading has to reach
/// `AuthRefresh`, or the visitor keeps whatever screen the loading state
/// produced. `0333` added `atCompanyDoor` and not its listener, and the
/// symptom was precisely the thing that rule exists to prevent: the
/// platform's front page at a company's own address, permanently,
/// because the lookup resolved a moment after the only evaluation.
void main() {
  /// Everything `AuthRefresh` subscribes to, held still. Each is
  /// overridden so the real one is never built — they reach Supabase,
  /// which is not running here, and the point is the wiring anyway.
  ProviderContainer containerWith({
    required Future<WorkspaceLookup> workspace,
  }) =>
      ProviderContainer(overrides: [
        organizationsProvider.overrideWith((ref) async => <Organization>[]),
        isPlatformAdminProvider.overrideWith((ref) async => false),
        workspaceLookupProvider.overrideWith((ref) => workspace),
      ]);

  test('fires when the workspace lookup lands', () async {
    final container = containerWith(
      workspace: Future.delayed(
        const Duration(milliseconds: 10),
        () => (host: WorkspaceHost.found, workspace: {'name': 'Sinar'}),
      ),
    );
    addTearDown(container.dispose);

    final refresh = container.read(_probe);
    var fired = 0;
    refresh.addListener(() => fired++);

    // Nothing has resolved yet: this is the moment the redirect runs and
    // sees `atCompanyDoor: false`.
    expect(fired, 0);

    await container.read(workspaceLookupProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(
      fired,
      greaterThan(0),
      reason: 'the router was never told the answer arrived, so a visitor '
          'at a company address keeps the front page',
    );
  });
}

/// Builds the notifier the router uses, from a `Ref` a test can reach.
final _probe = Provider<AuthRefresh>(AuthRefresh.new);
