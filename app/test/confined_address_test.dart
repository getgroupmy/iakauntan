import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/router.dart';
import 'package:iakauntan/src/features/shell/app_shell.dart';

/// An address pointed at one part of the product.
///
/// `0342`. A counter tablet on `till.iakauntan.com` opens the till and
/// nothing else — the module tie is a restriction rather than a nicer
/// starting point, which is the thing easiest to get subtly wrong: a
/// version that merely *lands* on the till and then lets somebody walk
/// into payroll looks identical until somebody walks into payroll.
void main() {
  String? go(
    String path, {
    bool signedIn = true,
    String? confinedTo,
    Set<String> confinedAllows = const {},
    bool? moduleHeld = true,
  }) => routeFor(
    path: path,
    signedIn: signedIn,
    recovering: false,
    hasOrg: true,
    isPlatformAdmin: false,
    atCompanyDoor: true,
    confinedTo: confinedTo,
    confinedAllows: confinedAllows,
    moduleHeld: moduleHeld,
  );

  group('reading the restriction off the address', () {
    test('an address with no module is not confined', () {
      expect(confinementFor(const {'name': 'Sinar'}), isNull);
      expect(confinementFor(const {'module_code': ''}), isNull);
      expect(confinementFor(null), isNull);
    });

    test('a module opens all of that module', () {
      final door = confinementFor(const {'module_code': 'pos'});

      expect(door, isNotNull);
      expect(door!.module, 'pos');
      expect(door.allows, pathsForModule('pos'));
      expect(door.allows, contains(door.landingPath));
      expect(door.allows.length, greaterThan(1),
          reason: 'the point of a module target is that it is more than '
              'one screen');
    });

    test('and one screen opens only that screen', () {
      final door = confinementFor(
        const {'module_code': 'pos', 'landing_path': '/pos/kitchen'},
      );

      expect(door!.landingPath, '/pos/kitchen');
      expect(door.allows, {'/pos/kitchen'});
    });

    test('and the alternate module counts as the same module', () {
      // Property is sold as strata and non-strata and either one opens
      // the portfolio. An address confined to one of them that stopped
      // at the other's door would be a restriction nobody wrote.
      final door = confinementFor(const {'module_code': 'property_nonstrata'});

      expect(door, isNotNull);
      expect(
        door!.allows,
        contains('/property'),
        reason: 'the portfolio is reachable through either half',
      );
    });

    test('a module with no screen in the navigation confines nothing', () {
      // Better than bouncing somebody around an address that opens
      // nothing at all.
      expect(confinementFor(const {'module_code': 'attachments'}), isNull);
    });
  });

  group('where a confined address lets you go', () {
    test('the screen it was pointed at', () {
      expect(go('/pos/till', confinedTo: '/pos/till',
          confinedAllows: {'/pos/till'}), isNull);
    });

    test('and anywhere else in the module when a module was chosen', () {
      final door = confinementFor(const {'module_code': 'pos'})!;
      for (final path in door.allows) {
        expect(
          go(path, confinedTo: door.landingPath, confinedAllows: door.allows),
          isNull,
          reason: path,
        );
      }
    });

    test('but nowhere outside it', () {
      // The assertion the whole feature is for.
      for (final path in const ['/dashboard', '/hr/payroll', '/sales/invoice',
          '/admin', '/contacts']) {
        expect(
          go(path, confinedTo: '/pos/till', confinedAllows: {'/pos/till'}),
          '/pos/till',
          reason: path,
        );
      }
    });

    test('and not to another screen of the same module when one was named',
        () {
      expect(
        go('/pos/kitchen',
            confinedTo: '/pos/till', confinedAllows: {'/pos/till'}),
        '/pos/till',
      );
    });

    test('settings stays open, because sign out lives there', () {
      // An address somebody cannot sign out of is a device nobody can
      // hand to the next shift.
      expect(
        go('/settings', confinedTo: '/pos/till',
            confinedAllows: {'/pos/till'}),
        isNull,
      );
    });
  });

  group('when the company has not got the module', () {
    test('it says so rather than opening or looping', () {
      expect(
        go('/pos/till', confinedTo: '/pos/till', moduleHeld: false),
        '/no-access',
      );
      expect(
        go('/dashboard', confinedTo: '/pos/till', moduleHeld: false),
        '/no-access',
      );
    });

    test('and the page saying so is reachable', () {
      // Without this the redirect points at a page the same redirect
      // then sends away, which is a loop rather than a message.
      expect(
        go('/no-access', confinedTo: '/pos/till', moduleHeld: false),
        isNull,
      );
    });

    test('while the answer is still loading, nothing moves', () {
      // Guessing "allowed" flashes a screen this address is not for;
      // guessing "refused" flashes the refusal at somebody entitled.
      expect(
        go('/pos/till', confinedTo: '/pos/till', moduleHeld: null),
        isNull,
      );
      expect(
        go('/dashboard', confinedTo: '/pos/till', moduleHeld: null),
        isNull,
      );
    });
  });

  group('an ordinary address is untouched', () {
    test('every path behaves as it did before any of this', () {
      for (final path in const ['/dashboard', '/sales/invoice', '/settings']) {
        expect(go(path), isNull, reason: path);
      }
    });

    test('and signing out still lands at the door', () {
      expect(go('/dashboard', signedIn: false), '/signin');
    });
  });

  test('a confined visitor cannot be sent round in a circle', () {
    final door = confinementFor(
      const {'module_code': 'pos', 'landing_path': '/pos/till'},
    )!;
    for (final held in [true, false, null]) {
      for (final start in const [
        '/dashboard', '/pos/till', '/pos/kitchen', '/no-access', '/settings',
        '/nothing-like-this',
      ]) {
        var at = start;
        final seen = <String>{at};
        for (var hop = 0; hop < 10; hop++) {
          final next = go(at,
              confinedTo: door.landingPath,
              confinedAllows: door.allows,
              moduleHeld: held);
          if (next == null) break;
          expect(seen.add(next), isTrue,
              reason: 'loop from $start (held: $held): $seen');
          at = next;
        }
        expect(seen.length, lessThanOrEqualTo(3),
            reason: 'from $start it took ${seen.length} hops: $seen');
      }
    }
  });
}
