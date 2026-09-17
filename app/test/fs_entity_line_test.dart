import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/corp_models.dart';
import 'package:iakauntan/src/features/financials/filing_screen.dart';

/// Which company a set of accounts is for, in the words the card uses.
///
/// `public.fs_set_entity` was granted to `authenticated` by `0391` and
/// called by nothing, so `fs_filings.corp_entity_id` was null on every
/// filing in the product's life. `report_fs_deadlines` returns
/// `coalesce(e.name, o.name)` and the entity's registration number, so
/// a corp-sec practice with forty client companies got forty rows all
/// named after the practice and no registration number on any of them.
///
/// The three states matter separately, and two of them look the same to
/// a careless reading. An organization with no companies on file keeps
/// its own books, and there is nothing to link to -- that is what the
/// `coalesce` is for and it is not a gap. An organization that has
/// companies and a filing that names none of them is a gap, and the
/// deadline list is already misnaming it.
void main() {
  CorpEntity entity({String? reg}) => CorpEntity(
    id: 'e1',
    name: 'Sinar Teknologi Sdn Bhd',
    entityType: 'sdn_bhd',
    status: 'incorporated',
    registrationNo: reg,
  );

  test('a linked company is named, with its registration number', () {
    expect(
      fsEntityLine(entity: entity(reg: '201901000123'), anyEntities: true),
      'Sinar Teknologi Sdn Bhd (201901000123)',
    );
  });

  test('and without one when it has none on file', () {
    expect(
      fsEntityLine(entity: entity(), anyEntities: true),
      'Sinar Teknologi Sdn Bhd',
    );
  });

  /// An empty string is not a registration number. Left unguarded the
  /// label reads "Sinar Teknologi Sdn Bhd ()", which looks like the
  /// number failed to load rather than like there is none.
  test('nor when the field is present but blank', () {
    expect(
      fsEntityLine(entity: entity(reg: ''), anyEntities: true),
      'Sinar Teknologi Sdn Bhd',
    );
  });

  test('an organization with no companies keeps its own books', () {
    expect(
      fsEntityLine(entity: null, anyEntities: false),
      "This organization's own accounts",
    );
  });

  /// The one the defect produced. Companies exist, this filing names
  /// none, and the deadline list is showing the practice's own name
  /// against it. Saying "this organization's own accounts" here would
  /// describe the gap as if it were the settled case.
  test('but one that has them and names none is unlinked, not its own', () {
    expect(fsEntityLine(entity: null, anyEntities: true),
        'Not linked to a company');
  });
}
