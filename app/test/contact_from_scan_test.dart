import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/core/providers.dart';
import 'package:iakauntan/src/core/theme.dart';
import 'package:iakauntan/src/data/entity_types_repository.dart';
import 'package:iakauntan/src/data/models.dart';
import 'package:iakauntan/src/data/ocr_repository.dart';
import 'package:iakauntan/src/data/repository.dart';
import 'package:iakauntan/src/features/contacts/contact_editor.dart';

/// A read letterhead reaches the form's boxes.
///
/// `scanned_contact_test.dart` asserts the mapping. This asserts the
/// WIRING, which is a separate thing and the half that was missing: the
/// reader has been answering sixteen configured columns since `0681`
/// and the form read six properties off the parse, so the legal name,
/// the old registration number, the SST number, the mobile, the city
/// and the state were asked for on every scan and then typed in by hand
/// off the same piece of paper.
///
/// The state is the one that could pass a unit test and still never
/// work: the list comes from a `FutureProvider` nothing has watched at
/// `initState`, so reading it there instead of awaiting it yields the
/// loading state -- null -- and the box stays empty on a real screen
/// while every assertion about the map still passes.
void main() {
  const kinds = [EntityType(code: 'sdn_bhd', label: 'Sdn Bhd', sortOrder: 10)];

  const letterhead = OcrExtraction(
    supplierName: 'MAJU',
    supplierAddress: '99 Jalan Lain\nTaman Berbeza\n11900 Bayan Lepas',
    fields: {
      'name': 'Kedai Runcit Maju',
      'legal_name': 'Kedai Runcit Maju Sdn Bhd',
      'registration_no': '201901001234',
      'old_registration_no': '571389-H',
      'tin': 'C1234567890',
      'sst_registration_no': 'W10-1808-31000001',
      'email': 'akaun@maju.com.my',
      'phone': '03-7788 1234',
      'mobile': '012-345 6789',
      'address_line1': 'Lot 5, Jalan Industri 3',
      'address_line2': 'Kawasan Perindustrian Sri Muda',
      'postcode': '40400',
      'city': 'Shah Alam',
      'state_code': 'Selangor',
    },
  );

  late _FakeRepo repo;

  Widget wrap(OcrExtraction? scanned) => ProviderScope(
    overrides: [
      repoProvider.overrideWithValue(repo),
      currentOrgProvider.overrideWith(
        (ref) async => Organization(id: 'o1', name: 'Kedai Kita', slug: 'kedai'),
      ),
      memberRoleProvider.overrideWith((ref) async => 'owner'),
      allEntityTypesProvider.overrideWith((ref) async => kinds),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ContactEditor(contactType: 'supplier', scanned: scanned),
      ),
    ),
  );

  Future<void> open(WidgetTester tester, OcrExtraction? scanned) async {
    tester.view.devicePixelRatio = 1.0;
    // Tall: the assertions are about what the form HOLDS, and a short
    // viewport would make a filled box below the fold read as empty.
    tester.view.physicalSize = const Size(1400, 3600);
    addTearDown(tester.view.reset);
    repo = _FakeRepo();
    await tester.pumpWidget(wrap(scanned));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // A new contact is asked its kind before the rest of the form
    // appears, and the boxes are not built until it is answered.
    await tester.tap(find.byKey(const ValueKey('contact-entity-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sdn Bhd').last);
    await tester.pumpAndSettle();
  }

  String? boxText(WidgetTester tester, String label) {
    final field = find.widgetWithText(TextFormField, label);
    if (field.evaluate().isEmpty) return null;
    return tester.widget<TextField>(
      find.descendant(of: field.first, matching: find.byType(TextField)),
    ).controller?.text;
  }

  testWidgets('every column the reader answered is in a box', (tester) async {
    await open(tester, letterhead);

    expect(boxText(tester, 'Name *'), 'Kedai Runcit Maju');
    // The eight that had nowhere to land before this.
    expect(boxText(tester, 'Legal name'), 'Kedai Runcit Maju Sdn Bhd');
    expect(boxText(tester, 'Mobile'), '012-345 6789');
    expect(boxText(tester, 'City'), 'Shah Alam');
    expect(boxText(tester, 'Address line 1'), 'Lot 5, Jalan Industri 3');
    expect(boxText(tester, 'Address line 2'),
        'Kawasan Perindustrian Sri Muda');
    expect(boxText(tester, 'Postcode'), '40400');
  });

  testWidgets('the state the reader named is chosen, not typed', (
    tester,
  ) async {
    // `state_code` is a foreign key into `ref_states`, so this is the
    // one field that has to arrive as a code. It also proves the list
    // was awaited: read instead, it is null at `initState` and the
    // dropdown would show nothing here.
    await open(tester, letterhead);

    // By its label, not `.first`: the form's first dropdown is the
    // contact type, which would answer 'supplier' and pass nothing.
    final dropdown = tester.widget<DropdownButtonFormField<String>>(
      find.byWidgetPredicate(
        (w) =>
            w is DropdownButtonFormField<String> &&
            w.decoration.labelText == 'State',
      ),
    );
    expect(dropdown.initialValue, '10');
  });

  testWidgets('and it is what gets saved', (tester) async {
    // Drawing a value and sending it are different things. A form that
    // filled every box and built its `Contact` from somewhere else
    // would pass every assertion above.
    await open(tester, letterhead);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(repo.saved?.legalName, 'Kedai Runcit Maju Sdn Bhd');
    expect(repo.saved?.oldRegistrationNo, '571389-H');
    expect(repo.saved?.sstRegistrationNo, 'W10-1808-31000001');
    expect(repo.saved?.mobile, '012-345 6789');
    expect(repo.saved?.city, 'Shah Alam');
    expect(repo.saved?.stateCode, '10');
  });

  testWidgets('a reading with no columns still fills what it used to', (
    tester,
  ) async {
    // Every scan taken before `0681`. The typed properties are the
    // fallback, and the address is split as it always was.
    await open(
      tester,
      const OcrExtraction(
        supplierName: 'Syarikat Lama',
        supplierPhone: '04-222 3333',
        supplierAddress: '12 Jalan Besar\nTaman Sri Muda\n40300 Shah Alam',
      ),
    );

    expect(boxText(tester, 'Name *'), 'Syarikat Lama');
    expect(boxText(tester, 'Phone'), '04-222 3333');
    expect(boxText(tester, 'Address line 1'), '12 Jalan Besar');
    expect(boxText(tester, 'Postcode'), '40300');
    // Never guessed out of a printed block.
    expect(boxText(tester, 'City'), '');
  });

  testWidgets('a form opened with no scan is empty', (tester) async {
    // The control. Somebody adding a contact by hand must not find a
    // previous letterhead in the boxes.
    await open(tester, null);

    expect(boxText(tester, 'Name *'), '');
    expect(boxText(tester, 'Legal name'), '');
    expect(boxText(tester, 'City'), '');
  });
}

class _FakeRepo implements Repo {
  Contact? saved;

  @override
  Future<Contact> saveContact(Contact contact, {String? id}) async {
    saved = contact;
    return contact;
  }

  /// A Dart extension method binds to the static type, so a fake cannot
  /// override one. The editor's calls that go through an extension land
  /// here instead -- see `contact_credit_limit_test.dart`.
  @override
  Future<dynamic> callRpc(String fn, {Map<String, dynamic>? params}) async =>
      null;

  @override
  Future<List<Map<String, dynamic>>> groupCompanies() async => const [];

  @override
  Future<List<Map<String, dynamic>>> priceLevels() async => const [];

  @override
  Future<List<Map<String, dynamic>>> states() async => const [
    {'code': '10', 'name': 'Selangor'},
    {'code': '14', 'name': 'Wilayah Persekutuan Kuala Lumpur'},
  ];

  @override
  Future<List<Account>> accounts({bool postableOnly = false}) async => const [];

  @override
  Future<String> nextContactCode(String contactType) async => 'S-0002';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    'the contact editor called Repo.${invocation.memberName}, '
    'which this fake does not answer',
  );
}
