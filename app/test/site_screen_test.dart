import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/core/widgets.dart';
import 'package:iakauntan/src/features/property/site_screen.dart';

/// A property, and the Schedule of Parcels underneath a strata one.
///
/// Two things live only in this widget.
///
/// THE SHARE UNITS ADD UP TO THE DENOMINATOR. Every strata charge is
/// apportioned on share units, so the total is what every parcel's
/// share is measured against. The screen's own comment says why it is
/// on the page: a Schedule of Parcels that has been HALF ENTERED looks
/// exactly like a complete one until somebody adds the column up. Get
/// the total wrong and every charge raised against every parcel is
/// wrong, on a page that looks finished.
///
/// AND A STRATA SCHEME IS NOT A FREEHOLD SITE. Three tabs either way
/// and three different ones: parcels, charges and arrears against
/// units, tenancies and quit rent. The tenure decides, and showing
/// somebody the wrong three is showing them a different legal animal.
void main() {
  Map<String, dynamic> site({
    String name = 'Menara Ampang',
    String tenure = 'strata',
  }) => {'id': 's1', 'name': name, 'tenure': tenure};

  Map<String, dynamic> unit({
    String unitNo = 'A-12-03',
    num? shareUnits = 120,
    num? builtUpSqft = 1150,
    String? ownerName = 'Puan Aminah',
    bool isChargeable = true,
  }) => {
    'id': 'u-$unitNo',
    'unit_no': unitNo,
    'share_units': shareUnits,
    'built_up_sqft': builtUpSqft,
    'contacts': ownerName == null ? null : {'name': ownerName},
    'is_chargeable': isChargeable,
  };

  Widget wrap({
    Map<String, dynamic>? theSite,
    List<Map<String, dynamic>> units = const [],
    String role = 'owner',
  }) => ProviderScope(
    overrides: [
      propertySiteProvider('s1').overrideWith((ref) async => theSite ?? site()),
      propertyUnitsProvider('s1').overrideWith((ref) async => units),
      strataSchemeProvider('s1').overrideWith((ref) async => null),
      tenanciesProvider('s1').overrideWith((ref) async => const []),
      propertyStatutoryChargesProvider('s1')
          .overrideWith((ref) async => const []),
      memberRoleProvider.overrideWith((ref) async => role),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const PropertySiteScreen(siteId: 's1'),
    ),
  );

  Future<void> show(
    WidgetTester tester, {
    Map<String, dynamic>? theSite,
    List<Map<String, dynamic>> units = const [],
    String role = 'owner',
  }) async {
    await tester.pumpWidget(wrap(theSite: theSite, units: units, role: role));
    await tester.pumpAndSettle();
  }

  group('the share units add up to the denominator', () {
    testWidgets('the total is every parcel on the schedule', (tester) async {
      // 120 + 95 + 140 = 355. A schedule missing one parcel reads as
      // complete until this line disagrees with the deed.
      await show(tester, units: [
        unit(unitNo: 'A-12-03', shareUnits: 120),
        unit(unitNo: 'A-12-04', shareUnits: 95),
        unit(unitNo: 'A-12-05', shareUnits: 140),
      ]);

      expect(find.text('3 parcels, 355 share units allocated'),
          findsOneWidget);
    });

    testWidgets('a parcel with no share units entered counts as none',
        (tester) async {
      // Half-entered is the case the line exists for. 120 and a blank
      // is 120, not an error and not a guess -- and the count of
      // parcels says three, so the two figures together show the gap.
      await show(tester, units: [
        unit(unitNo: 'A-12-03', shareUnits: 120),
        unit(unitNo: 'A-12-04', shareUnits: null),
        unit(unitNo: 'A-12-05', shareUnits: null),
      ]);

      expect(find.text('3 parcels, 120 share units allocated'),
          findsOneWidget);
    });

    testWidgets('and a freehold site is not told about share units',
        (tester) async {
      // The control. Share units are a strata concept; a row of houses
      // has none, and a line reading "0 share units allocated" invites
      // somebody to go looking for them.
      await show(tester, theSite: site(tenure: 'freehold'), units: [
        unit(unitNo: '12 Jalan Ampang', shareUnits: null),
      ]);

      expect(find.textContaining('share units allocated'), findsNothing);
    });
  });

  group('what a parcel says', () {
    testWidgets('its share, its size and who owns it', (tester) async {
      await show(tester, units: [
        unit(unitNo: 'A-12-03', shareUnits: 120, builtUpSqft: 1150,
            ownerName: 'Puan Aminah'),
      ]);

      expect(find.text('A-12-03'), findsOneWidget);
      expect(find.text('120 share units · 1150 sq ft · Puan Aminah'),
          findsOneWidget);
    });

    testWidgets('a parcel nobody is registered against says so',
        (tester) async {
      // Not a blank. An unsold parcel is the developer's, and its
      // charges still fall due on somebody.
      await show(tester, units: [unit(ownerName: null)]);

      expect(find.textContaining('No owner on record'), findsOneWidget);
    });

    testWidgets('and a parcel excluded from charges is marked',
        (tester) async {
      // Excluding one parcel raises everybody else's share of the same
      // budget, so it is not a quiet setting.
      await show(tester, units: [
        unit(unitNo: 'A-12-03', isChargeable: false),
      ]);

      expect(find.byType(StatusChip), findsOneWidget);
      expect(find.text('Not charged'), findsOneWidget);
    });

    testWidgets('while an ordinary one is not', (tester) async {
      await show(tester, units: [unit(isChargeable: true)]);

      expect(find.byType(StatusChip), findsNothing);
    });
  });

  group('a strata scheme is not a freehold site', () {
    testWidgets('strata gets parcels, charges and arrears', (tester) async {
      await show(tester, theSite: site(tenure: 'strata'));

      expect(find.text('Parcels'), findsOneWidget);
      expect(find.text('Charges'), findsOneWidget);
      expect(find.text('Arrears'), findsOneWidget);
      expect(find.text('Units'), findsNothing);
    });

    testWidgets('and freehold gets units, tenancies and quit rent',
        (tester) async {
      await show(tester, theSite: site(tenure: 'freehold'));

      expect(find.text('Units'), findsOneWidget);
      expect(find.text('Tenancies'), findsOneWidget);
      expect(find.text('Quit rent & assessment'), findsOneWidget);
      expect(find.text('Parcels'), findsNothing);
    });

    testWidgets('the empty schedule is worded for the tenure it belongs to',
        (tester) async {
      await show(tester, theSite: site(tenure: 'strata'), units: const []);

      expect(find.text('No parcels yet'), findsOneWidget);
      // And says what a Schedule of Parcels is, since somebody seeing
      // this has not entered one.
      expect(find.textContaining('Schedule of Parcels'), findsOneWidget);
    });

    testWidgets('and a freehold site is told about units instead',
        (tester) async {
      await show(tester, theSite: site(tenure: 'freehold'), units: const []);

      expect(find.text('No units yet'), findsOneWidget);
      expect(find.text('No parcels yet'), findsNothing);
    });
  });

  group('who may change the schedule', () {
    testWidgets('somebody who may write can open a parcel', (tester) async {
      await show(tester, units: [unit()]);

      final tile = tester.widget<ListTile>(find.byType(ListTile).first);
      expect(tile.onTap, isNotNull);
    });

    testWidgets('and a viewer cannot', (tester) async {
      // A share unit is the denominator of everybody's charge. Reading
      // the schedule is not editing it.
      await show(tester, units: [unit()], role: 'viewer');

      final tile = tester.widget<ListTile>(find.byType(ListTile).first);
      expect(tile.onTap, isNull);
      // Still fully readable.
      expect(find.text('A-12-03'), findsOneWidget);
    });
  });
}
