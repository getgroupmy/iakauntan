import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/core/router.dart';
import 'package:iakauntan/src/features/admin/reservations_admin.dart';

/// What a name on our domain is for, and what the console asks to find
/// out.
///
/// `0344`. A name is a company's door, or held by us, or ours and open.
/// The third is the new one, and it is new in a way that reaches the
/// router: an address of ours has no company behind it, so the
/// subscription check that guards a company's door has nothing to
/// check — and asking anyway refuses every one of them, because a
/// platform operator with no company holds no modules at all.
void main() {
  group('reading the purpose off the address', () {
    test('an address of ours says so', () {
      final door = confinementFor(const {
        'module_code': 'pos',
        'landing_path': '/till',
        'purpose': 'admin',
      });

      expect(door, isNotNull);
      expect(door!.ours, isTrue);
      expect(door.landingPath, '/till');
    });

    test("and a company's does not", () {
      final door = confinementFor(const {
        'module_code': 'pos',
        'purpose': 'company',
      });

      expect(door?.ours, isFalse);
    });

    test('a row with no purpose at all reads as a company\'s', () {
      // Every row before `0344`, and anything else that arrives without
      // the column. Guessing "ours" for one of those would drop the
      // entitlement check on every existing company door at once.
      final door = confinementFor(const {'module_code': 'pos'});

      expect(door?.ours, isFalse);
    });
  });

  group('what that changes at the door', () {
    String? go({required bool ours, required bool held}) => routeFor(
      path: '/dashboard',
      signedIn: true,
      recovering: false,
      hasOrg: true,
      isPlatformAdmin: false,
      atCompanyDoor: true,
      confinedTo: '/till',
      confinedAllows: const {'/till'},
      // What the router does with an admin door: it does not ask.
      moduleHeld: ours ? true : held,
    );

    test('a company that has not bought the module is refused', () {
      expect(go(ours: false, held: false), '/no-access');
    });

    test('and one that has is sent to the screen', () {
      expect(go(ours: false, held: true), '/till');
    });

    test('an address of ours opens whether or not anybody subscribed', () {
      // The assertion that matters. `held: false` is what
      // `enabledModulesProvider` answers for somebody with no company,
      // and an address of ours must not be refused for it.
      expect(go(ours: true, held: false), '/till');
    });
  });

  group('what the router asks about a subscription', () {
    // The wiring rather than the rule. A version that reads the
    // purpose, passes it to `routeFor` correctly, and then looks the
    // subscription up anyway passes every test above this one.
    final pos = confinementFor(const {
      'module_code': 'pos',
      'purpose': 'company',
    });
    final ours = confinementFor(const {
      'module_code': 'pos',
      'purpose': 'admin',
    });

    test('an unconfined address is not asked at all', () {
      expect(moduleHeldFor(null, const AsyncValue.data({'pos'})), isNull);
    });

    test("a company's address is asked, and answered", () {
      expect(moduleHeldFor(pos, const AsyncValue.data({'pos'})), isTrue);
      expect(moduleHeldFor(pos, const AsyncValue.data({'hr'})), isFalse);
    });

    test('and while the answer is in flight, nothing is decided', () {
      expect(moduleHeldFor(pos, const AsyncValue.loading()), isNull);
    });

    test('an address of ours is not asked', () {
      // The empty set is what somebody with no company of their own
      // holds, and it must not refuse an address that has no company by
      // design.
      expect(moduleHeldFor(ours, const AsyncValue.data({})), isTrue);
      expect(moduleHeldFor(ours, const AsyncValue.loading()), isTrue);
    });
  });

  group('what the list calls each one', () {
    test('a held name is not a company that went missing', () {
      expect(whoseName(const {'purpose': 'reserved'}), 'Held by us');
      expect(whoseName(const {'purpose': 'admin'}), 'Ours, in use');
    });

    test("and a company's is the company", () {
      expect(
        whoseName(const {'purpose': 'company', 'org_name': 'Sinar Teknologi'}),
        'Sinar Teknologi',
      );
    });

    test('a company row with no name still says something', () {
      expect(whoseName(const {'purpose': 'company'}), 'Unknown company');
    });
  });

  group('the question the console asks first', () {
    Widget wrap(String purpose, void Function(String) onChanged) =>
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: PurposeField(purpose: purpose, onChanged: onChanged),
            ),
          ),
        );

    testWidgets('a company\'s address is not asked the second question',
        (tester) async {
      await tester.pumpWidget(wrap('company', (_) {}));
      await tester.pumpAndSettle();

      expect(find.text("A company's"), findsOneWidget);
      expect(find.text('Ours'), findsOneWidget);
      // Meaningless of a company's door, which is in use by definition.
      expect(find.text('Reserved'), findsNothing);
      expect(find.text('Admin use'), findsNothing);
    });

    testWidgets('and one of ours is', (tester) async {
      await tester.pumpWidget(wrap('reserved', (_) {}));
      await tester.pumpAndSettle();

      expect(find.text('Reserved'), findsOneWidget);
      expect(find.text('Admin use'), findsOneWidget);
    });

    testWidgets('moving to ours parks it rather than guessing', (tester) async {
      final said = <String>[];
      await tester.pumpWidget(wrap('company', said.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Ours'));
      await tester.pumpAndSettle();

      // The plainer of the two, so nothing is put to use by a press
      // that was only answering the first question.
      expect(said, ['reserved']);
    });

    testWidgets('and moving back is a company\'s again', (tester) async {
      final said = <String>[];
      await tester.pumpWidget(wrap('admin', said.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text("A company's"));
      await tester.pumpAndSettle();

      expect(said, ['company']);
    });

    testWidgets('putting a held name to use says so', (tester) async {
      final said = <String>[];
      await tester.pumpWidget(wrap('reserved', said.add));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Admin use'));
      await tester.pumpAndSettle();

      expect(said, ['admin']);
    });

    testWidgets('each answer explains what it means', (tester) async {
      await tester.pumpWidget(wrap('reserved', (_) {}));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nothing answers on it'), findsOneWidget);

      await tester.pumpWidget(wrap('admin', (_) {}));
      await tester.pumpAndSettle();
      expect(find.textContaining('needs nobody to have bought'),
          findsOneWidget);
    });
  });
}
