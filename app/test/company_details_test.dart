import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/features/settings/company_card.dart';

/// The company's own particulars, which were read-only on screen for
/// no reason anybody chose: `organizations_update` has checked
/// `can_admin` since 0010, so an owner has always been allowed to change
/// them and simply had nowhere to do it.
///
/// The base currency is the one field with a rule behind it worth
/// asserting. Every amount in the ledger is a number in that currency
/// and nothing records which — so changing it once anything is posted
/// re-labels every figure the company has rather than converting it.
/// The field is locked from the moment there is a posting, and the
/// helper text says which of the two situations you are in, because
/// otherwise a locked field looks like a bug.
void main() {
  Organization org({String? tourismTax}) => Organization(
    id: 'o',
    name: 'Sinar Teknologi Sdn Bhd',
    slug: 'sinar',
    entityType: 'sdn_bhd',
    baseCurrency: 'MYR',
    tourismTaxRegNo: tourismTax,
  );

  Widget harness({
    required bool posted,
    bool canAdmin = true,
    String? tourismTax,
  }) => ProviderScope(
    overrides: [
      // Anyone who is not an owner or administrator: the database
      // refuses their update, so the screen should not offer it.
      canAdminProvider.overrideWithValue(canAdmin),
      hasPostingsProvider.overrideWith((_) async => posted),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: CompanyCard(org: org(tourismTax: tourismTax))),
    ),
  );

  Finder editButton() => find.byKey(const ValueKey('edit-company'));
  Finder currency() => find.byKey(const ValueKey('company-currency'));

  testWidgets('an owner is offered the edit the database already allows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(posted: false));
    await tester.pumpAndSettle();

    expect(editButton(), findsOneWidget);
  });

  testWidgets('and somebody who cannot administer the company is not', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(posted: false, canAdmin: false));
    await tester.pumpAndSettle();

    expect(editButton(), findsNothing);
  });

  testWidgets('the base currency is open while nothing has been posted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(posted: false));
    await tester.pumpAndSettle();
    await tester.tap(editButton());
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(currency()).enabled, isTrue);
    expect(find.textContaining('nothing has been posted yet'), findsOneWidget);
  });

  testWidgets('and shuts once something is, saying why', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(posted: true));
    await tester.pumpAndSettle();
    await tester.tap(editButton());
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(currency()).enabled, isFalse);
    // A locked field with no reason beside it reads as a bug.
    expect(find.textContaining('re-label them all'), findsOneWidget);

    // Everything else is still editable — locking one field must not
    // quietly lock the form.
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('company-name')))
          .enabled,
      isTrue,
    );
  });

  // 0642. The column has existed since 0001 beside the SST number and
  // this form is the first thing that ever asked for it.
  group('the Tourism Tax registration', () {
    Finder field() => find.byKey(const ValueKey('company-tourism-tax'));

    testWidgets('is on the form, and starts from what is held', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        harness(posted: false, tourismTax: 'TTX-0001234'),
      );
      await tester.pumpAndSettle();
      await tester.tap(editButton());
      await tester.pumpAndSettle();

      expect(field(), findsOneWidget);
      expect(tester.widget<TextField>(field()).controller!.text,
          'TTX-0001234');
    });

    testWidgets('and says who it is for, because almost nobody is', (
      tester,
    ) async {
      // A field on the company form that most companies must leave
      // blank needs to say so, or it reads as something missing.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(posted: false));
      await tester.pumpAndSettle();
      await tester.tap(editButton());
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      expect(
        find.textContaining('Only for accommodation registered with'),
        findsOneWidget,
      );
    });

    testWidgets('and is shown on the card only where there is one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(posted: false));
      await tester.pumpAndSettle();
      expect(find.text('Tourism Tax'), findsNothing);

      await tester.pumpWidget(
        harness(posted: false, tourismTax: 'TTX-0001234'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tourism Tax'), findsOneWidget);
      expect(find.text('TTX-0001234'), findsOneWidget);
    });
  });

  testWidgets('a company with no name cannot be saved', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(posted: true));
    await tester.pumpAndSettle();
    await tester.tap(editButton());
    await tester.pumpAndSettle();

    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);

    await tester.enterText(find.byKey(const ValueKey('company-name')), '');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });
}
