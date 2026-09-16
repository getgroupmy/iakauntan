import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/features/secretarial/entity_screen.dart';

/// One company's file: the registers the Companies Act 2016 requires a
/// secretary to keep.
///
/// 2,070 lines and no test. What only lives here is the reading of the
/// registers — each one says something about a company that a secretary
/// would otherwise have to work out from dates, and three of those
/// sentences are ones somebody acts on.
///
/// THE SENTENCES ARE NOT DECORATION. "The company has no validly
/// appointed secretary" and "the charge is void against the liquidator"
/// are the two strongest things this app says about anybody, both in
/// the danger colour, and `7cd0e51` found each of them being said a day
/// early. The boundary cases are here so the next change to those
/// getters has to come past them.
///
/// A REGISTER IS NOT A LIST OF THE CURRENT. s.57 keeps former officers,
/// s.357 keeps satisfied charges, s.60B keeps people who have ceased to
/// be beneficial owners. Each is kept because somebody searching the
/// file is asking what WAS true, and each is drawn differently from the
/// current entry rather than mixed in with it.
///
/// AND A SHARE MOVEMENT HAS A DIRECTION. An allotment has no transferor
/// and a cancellation has no transferee; a transfer has both, and
/// reading it backwards is a register saying the shares went the other
/// way. The three are one `switch` and nothing else checks it.
void main() {
  CorpEntity entity({String name = 'Tepat Masa Sdn Bhd'}) => CorpEntity(
    id: 'e1',
    name: name,
    entityType: 'sdn_bhd',
    status: 'active',
    registrationNo: '202601234567',
  );

  CorpOfficer officer({
    String id = 'o1',
    String name = 'Puan Aminah',
    String role = 'director',
    DateTime? appointedOn,
    DateTime? resignedOn,
    DateTime? consentReceivedOn,
    DateTime? declarationReceivedOn,
    String? licenceNo,
    String? licenceBody,
    DateTime? licenceExpiresOn,
  }) => CorpOfficer(
    id: id,
    personId: 'p-$id',
    role: role,
    appointedOn: appointedOn ?? DateTime(2020, 3, 1),
    name: name,
    identifier: '800101-14-5566',
    resignedOn: resignedOn,
    consentReceivedOn: consentReceivedOn,
    declarationReceivedOn: declarationReceivedOn,
    licenceNo: licenceNo,
    licenceBody: licenceBody,
    licenceExpiresOn: licenceExpiresOn,
  );

  CorpMember member({
    String id = 'm1',
    String name = 'Puan Aminah',
    double shares = 500000,
    double percent = 50,
  }) => CorpMember(
    personId: 'p-$id',
    name: name,
    shareClass: 'ORD',
    shares: shares,
    percent: percent,
    nric: '800101-14-5566',
    firstAcquired: DateTime(2020, 3, 1),
  );

  CorpShareEvent event({
    String id = 'ev1',
    String eventType = 'transfer',
    String? fromName = 'Encik Lim',
    String? toName = 'Puan Aminah',
    double quantity = 100000,
  }) => CorpShareEvent(
    id: id,
    eventType: eventType,
    eventDate: DateTime(2026, 4, 1),
    quantity: quantity,
    shareClass: 'ORD',
    fromName: fromName,
    toName: toName,
  );

  CorpCharge charge({
    String id = 'c1',
    String chargeeName = 'Maybank Islamic Berhad',
    DateTime? createdOn,
    DateTime? registeredOn,
    DateTime? satisfiedOn,
    double? amountSecured = 250000,
  }) => CorpCharge(
    id: id,
    chargeeName: chargeeName,
    createdOn: createdOn ?? DateTime(2026, 1, 1),
    registeredOn: registeredOn,
    satisfiedOn: satisfiedOn,
    amountSecured: amountSecured,
    chargeType: 'Debenture',
  );

  CorpBeneficialOwner owner({
    String id = 'b1',
    String name = 'Puan Aminah',
    double? percent = 55,
    bool shares = true,
    DateTime? ceasedOn,
  }) => CorpBeneficialOwner(
    id: id,
    personId: 'p-$id',
    name: name,
    identifier: '800101-14-5566',
    percent: percent,
    holds20pcShares: shares,
    ceasedOn: ceasedOn,
  );

  /// Today in Malaysia, which is what a CA 2016 deadline falls on and
  /// what `corpToday()` reads. Not the device's date: see
  /// `corp_filing_clock_test.dart`.
  DateTime today() => corpToday();

  Widget wrap({
    bool missing = false,
    CorpEntity? theEntity,
    List<CorpOfficer> officers = const [],
    List<CorpMember> members = const [],
    List<CorpShareEvent> events = const [],
    List<CorpCharge> charges = const [],
    List<CorpBeneficialOwner> owners = const [],
    String role = 'owner',
  }) => ProviderScope(
    overrides: [
      memberRoleProvider.overrideWith((ref) async => role),
      // An explicit flag, not `theEntity ?? entity()`. A `?? default`
      // in a fixture helper turns "this company is not on file" back
      // into an ordinary company, so the empty-state test fails against
      // a screen that works -- lesson 8 in docs/widget-tests.md, which
      // is how this was written the first time.
      corpEntityProvider(
        'e1',
      ).overrideWith((ref) async => missing ? null : theEntity ?? entity()),
      corpOfficersProvider('e1').overrideWith((ref) async => officers),
      corpMembersProvider('e1').overrideWith((ref) async => members),
      corpShareEventsProvider('e1').overrideWith((ref) async => events),
      corpShareClassesProvider('e1').overrideWith((ref) async => const []),
      corpBeneficialOwnersProvider('e1').overrideWith((ref) async => owners),
      corpChargesProvider('e1').overrideWith((ref) async => charges),
      corpResolutionsProvider('e1').overrideWith((ref) async => const []),
      corpDocumentsProvider('e1').overrideWith((ref) async => const []),
    ],
    child: MaterialApp.router(
      theme: AppTheme.light(),
      routerConfig: GoRouter(
        initialLocation: '/secretarial/e1',
        routes: [
          GoRoute(
            path: '/secretarial/e1',
            builder: (_, __) => const CorpEntityScreen(entityId: 'e1'),
          ),
          GoRoute(
            path: '/secretarial',
            builder: (_, __) => const Scaffold(body: Text('the list')),
          ),
        ],
      ),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    bool missing = false,
    CorpEntity? theEntity,
    List<CorpOfficer> officers = const [],
    List<CorpMember> members = const [],
    List<CorpShareEvent> events = const [],
    List<CorpCharge> charges = const [],
    List<CorpBeneficialOwner> owners = const [],
    String role = 'owner',
    String? tab,
  }) async {
    // Wide, because this screen is seven scrollable tabs of register
    // and the phone layout is not what is being asserted here.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1200);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(
      missing: missing,
      theEntity: theEntity,
      officers: officers,
      members: members,
      events: events,
      charges: charges,
      owners: owners,
      role: role,
    ));
    await tester.pumpAndSettle();
    if (tab != null) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
    }
  }

  /// The colour a flag is drawn in, which is the difference between a
  /// note and an alarm.
  Color? colourOf(WidgetTester tester, Finder f) =>
      tester.widget<Text>(f).style?.color;

  group('the register of officers', () {
    testWidgets('says a company with nobody on it is in breach',
        (tester) async {
      // Not "no officers yet". s.196 requires at least one director
      // ordinarily resident in Malaysia, so an empty register is a
      // statement about the company rather than about the data.
      await show(tester, tab: 'Officers');

      expect(
        find.textContaining('at least one director who ordinarily resides'),
        findsOneWidget,
      );
    });

    testWidgets('flags a director with no s.201 consent on file',
        (tester) async {
      await show(
        tester,
        tab: 'Officers',
        officers: [officer(consentReceivedOn: null)],
      );

      expect(
        find.text('No s.201 consent or s.198 declaration on file'),
        findsOneWidget,
      );
    });

    testWidgets('and does not flag one whose paperwork is complete',
        (tester) async {
      // The control. Without it, "the flag is shown" passes against a
      // register that flags every director on the file.
      await show(
        tester,
        tab: 'Officers',
        officers: [
          officer(
            consentReceivedOn: DateTime(2020, 3, 1),
            declarationReceivedOn: DateTime(2020, 3, 1),
          ),
        ],
      );

      expect(find.textContaining('No s.201 consent'), findsNothing);
    });

    testWidgets('and asks a secretary for neither', (tester) async {
      // s.201 and s.198 are asked of directors. A secretary flagged for
      // want of a director's consent is a register inventing an
      // obligation, and the secretary is usually the person reading it.
      await show(
        tester,
        tab: 'Officers',
        officers: [officer(role: 'secretary', name: 'Encik Rahim')],
      );

      expect(find.textContaining('No s.201 consent'), findsNothing);
    });
  });

  group('a secretary whose licence has run out', () {
    CorpOfficer sec(DateTime expires) => officer(
      role: 'secretary',
      name: 'Encik Rahim',
      licenceNo: 'LS0001234',
      licenceBody: 'MAICSA',
      licenceExpiresOn: expires,
    );

    const line = 'Secretary’s licence has expired — the company has no '
        'validly appointed secretary';

    testWidgets('is not said on the day it expires', (tester) async {
      // 7cd0e51. `licence_expires_on` is a date column, so against
      // `DateTime.now()` this was said from 00:01 on the expiry day —
      // about a company whose secretary was validly appointed until
      // midnight, in the danger colour.
      await show(tester, tab: 'Officers', officers: [sec(today())]);

      expect(find.text(line), findsNothing);
      expect(find.text('MAICSA LS0001234 · expires ${_d(today())}'),
          findsOneWidget);
    });

    testWidgets('and is said the day after, in the danger colour',
        (tester) async {
      await show(
        tester,
        tab: 'Officers',
        officers: [sec(today().subtract(const Duration(days: 1)))],
      );

      final f = find.text(line);
      expect(f, findsOneWidget);
      expect(colourOf(tester, f), AppTheme.light().extension<AppColors>()!.danger);
    });
  });

  group('a register keeps what stopped being true', () {
    testWidgets('a former officer is struck through, not dropped',
        (tester) async {
      // s.57. Somebody searching the file is asking who WAS a director
      // when a thing happened, so the row stays — and is drawn so it
      // cannot be read as a sitting officer.
      await show(
        tester,
        tab: 'Officers',
        officers: [
          officer(id: 'o1', name: 'Puan Aminah'),
          officer(
            id: 'o2',
            name: 'Encik Lim',
            resignedOn: DateTime(2025, 6, 30),
          ),
        ],
      );

      expect(
        tester.widget<Text>(find.text('Encik Lim')).style?.decoration,
        TextDecoration.lineThrough,
      );
      expect(
        tester.widget<Text>(find.text('Puan Aminah')).style?.decoration,
        isNot(TextDecoration.lineThrough),
      );
      expect(find.textContaining('ceased 30/06/2025'), findsOneWidget);

      // And is asked for nothing. s.201 consent and the s.198
      // declaration are obligations of a SITTING director; raising them
      // against somebody who resigned last year puts a warning on every
      // historical row in the file, which is how a flag stops being
      // read. Neither of these officers has either date on file, so
      // without the `isCurrent` guard both rows would carry it.
      expect(find.textContaining('No s.201 consent'), findsOneWidget);
    });

    testWidgets('and a satisfied charge stays on the register',
        (tester) async {
      // s.357 requires it kept, and a charge discharged last year is
      // exactly what a lender's solicitor is searching for.
      await show(
        tester,
        tab: 'Charges',
        charges: [
          charge(
            id: 'c1',
            chargeeName: 'Maybank Islamic Berhad',
            registeredOn: DateTime(2026, 1, 10),
          ),
          charge(
            id: 'c2',
            chargeeName: 'CIMB Bank Berhad',
            registeredOn: DateTime(2025, 1, 10),
            satisfiedOn: DateTime(2025, 12, 1),
          ),
        ],
      );

      // The HEADING, not the chip on the row -- `StatusChip('satisfied')`
      // renders the same word, so an unscoped finder counts two and
      // would count one on a screen with no heading at all.
      expect(find.byType(SectionHeader), findsNWidgets(2));
      expect(
        tester
            .widgetList<SectionHeader>(find.byType(SectionHeader))
            .map((h) => h.title),
        contains('Satisfied'),
      );
      expect(
        tester.widget<Text>(find.text('CIMB Bank Berhad')).style?.decoration,
        TextDecoration.lineThrough,
      );
      expect(
        tester
            .widget<Text>(find.text('Maybank Islamic Berhad'))
            .style
            ?.decoration,
        isNot(TextDecoration.lineThrough),
      );
    });

    testWidgets('and the satisfied section is absent when none is',
        (tester) async {
      // The control. An empty "Satisfied" heading on every company's
      // file is a section that says nothing.
      await show(
        tester,
        tab: 'Charges',
        charges: [charge(registeredOn: DateTime(2026, 1, 10))],
      );

      expect(
        tester
            .widgetList<SectionHeader>(find.byType(SectionHeader))
            .map((h) => h.title),
        isNot(contains('Satisfied')),
      );
      expect(find.text('No charges outstanding.'), findsNothing);
    });
  });

  group('the thirty days a charge has', () {
    const line = 'Not registered within thirty days of creation — the '
        'charge is void against the liquidator (s.352)';

    testWidgets('day thirty is not yet void', (tester) async {
      // 7cd0e51 again, and the more serious of the two: this was said
      // on day thirty, which is still inside the thirty days, to a
      // secretary who had until the end of the day to lodge it.
      await show(
        tester,
        tab: 'Charges',
        charges: [charge(createdOn: today().subtract(const Duration(days: 30)))],
      );

      expect(find.text(line), findsNothing);
    });

    testWidgets('and day thirty-one is, in the danger colour',
        (tester) async {
      await show(
        tester,
        tab: 'Charges',
        charges: [charge(createdOn: today().subtract(const Duration(days: 31)))],
      );

      final f = find.text(line);
      expect(f, findsOneWidget);
      expect(colourOf(tester, f), AppTheme.light().extension<AppColors>()!.danger);
    });

    testWidgets('and a charge registered in time never is, however old',
        (tester) async {
      await show(
        tester,
        tab: 'Charges',
        charges: [
          charge(
            createdOn: DateTime(2019, 1, 1),
            registeredOn: DateTime(2019, 1, 20),
          ),
        ],
      );

      expect(find.text(line), findsNothing);
      expect(find.textContaining('registered 20/01/2019'), findsOneWidget);
    });
  });

  group('a share movement has a direction', () {
    // An allotment has no transferor and a cancellation has no
    // transferee. A transfer has both, and reading it backwards is a
    // register saying the shares went the other way — which is the
    // whole of what a register of members is for.
    testWidgets('an allotment names only who got the shares',
        (tester) async {
      await show(
        tester,
        tab: 'Members',
        events: [
          event(eventType: 'allotment', fromName: null, toName: 'Puan Aminah'),
        ],
      );

      expect(find.text('100,000 ORD to Puan Aminah'), findsOneWidget);
    });

    testWidgets('a cancellation names only who lost them', (tester) async {
      await show(
        tester,
        tab: 'Members',
        events: [
          event(eventType: 'cancellation', fromName: 'Encik Lim', toName: null),
        ],
      );

      expect(find.text('100,000 ORD from Encik Lim'), findsOneWidget);
    });

    testWidgets('and a transfer names both, the right way round',
        (tester) async {
      // The whole line, with the arrow. `textContaining('Encik Lim')`
      // would pass against a register that had the two names the wrong
      // way round.
      await show(
        tester,
        tab: 'Members',
        events: [
          event(fromName: 'Encik Lim', toName: 'Puan Aminah'),
        ],
      );

      expect(
        find.text('100,000 ORD Encik Lim → Puan Aminah'),
        findsOneWidget,
      );
      expect(
        find.text('100,000 ORD Puan Aminah → Encik Lim'),
        findsNothing,
      );
    });
  });

  group('the twenty per cent mark', () {
    // s.60B is one of the statutory tests for a beneficial owner. The
    // flag is ADVISORY — it says "consider the register" rather than
    // entering anybody on it, and the determinative thing is the
    // checkbox a secretary ticks in the declare sheet.
    //
    // The boundary asserted here is the one the code has: STRICTLY
    // more than 20. Whether s.60B reads "more than" or "not less than
    // twenty per centum" is worth checking against the Act — if it is
    // the latter, a member on exactly 20.00% should be prompted and is
    // not, and `CorpMember.triggersBeneficialOwnership` changes by one
    // character. Nothing in this repository states the threshold in the
    // statute's own words, so it is pinned as it stands rather than
    // altered on a recollection.
    const line = 'Over 20% — consider the s.60B register';

    testWidgets('is not reached at exactly twenty', (tester) async {
      await show(tester, tab: 'Members', members: [member(percent: 20)]);

      expect(find.text(line), findsNothing);
    });

    testWidgets('and is passed just above it', (tester) async {
      await show(tester, tab: 'Members', members: [member(percent: 20.01)]);

      expect(find.text(line), findsOneWidget);
    });

    testWidgets('and a minority holder is not prompted', (tester) async {
      // The control at the other end: without it, "the flag is there"
      // passes against a register that prompts about everybody.
      await show(
        tester,
        tab: 'Members',
        members: [
          member(id: 'm1', name: 'Puan Aminah', percent: 55),
          member(id: 'm2', name: 'Encik Lim', percent: 5),
        ],
      );

      expect(find.text(line), findsOneWidget);
    });
  });

  group('the register of beneficial owners', () {
    testWidgets('says an empty one is itself a statement', (tester) async {
      // A company with nobody identified must record the steps it took
      // to find somebody. "No beneficial owners" would read as nothing
      // to do.
      await show(tester, tab: 'Beneficial owners');

      expect(
        find.textContaining('an empty register is itself a statement'),
        findsOneWidget,
      );
    });

    testWidgets('and keeps somebody who has ceased to be one',
        (tester) async {
      await show(
        tester,
        tab: 'Beneficial owners',
        owners: [
          owner(id: 'b1', name: 'Puan Aminah'),
          owner(id: 'b2', name: 'Encik Lim', ceasedOn: DateTime(2025, 9, 1)),
        ],
      );

      expect(find.text('Puan Aminah'), findsOneWidget);
      expect(find.text('Encik Lim'), findsOneWidget);
      expect(
        find.textContaining('an empty register is itself a statement'),
        findsNothing,
      );
    });
  });

  group('somebody who may only look', () {
    testWidgets('is offered none of the registers to write to',
        (tester) async {
      // Every one of these opens a sheet that writes to a statutory
      // register. RLS refuses a viewer anyway, so the buttons would
      // only ever produce a refusal.
      await show(tester, role: 'viewer', tab: 'Officers');
      expect(find.byKey(const ValueKey('appoint-officer')), findsNothing);
      expect(find.byKey(const ValueKey('change-particulars')), findsNothing);

      await tester.tap(find.text('Charges'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('register-charge')), findsNothing);

      await tester.tap(find.text('Beneficial owners'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('declare-owner')), findsNothing);
    });

    testWidgets('and somebody who may write is offered all of them',
        (tester) async {
      // The control. Without it, every assertion above passes against a
      // screen with no buttons at all.
      await show(tester, tab: 'Officers');
      expect(find.byKey(const ValueKey('appoint-officer')), findsOneWidget);
      expect(find.byKey(const ValueKey('change-particulars')), findsOneWidget);

      await tester.tap(find.text('Charges'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('register-charge')), findsOneWidget);

      await tester.tap(find.text('Beneficial owners'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('declare-owner')), findsOneWidget);
    });
  });

  testWidgets('a company that is not there says so', (tester) async {
    await show(tester, missing: true);

    expect(find.text('Company not found'), findsOneWidget);
  });
}

String _d(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')}/${d.year}';
