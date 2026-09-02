import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import 'contact_records.dart' show contactRoleLabel, contactRoleIcon;

/// What the editor says when the contact being typed is already on
/// file, decided apart from how it looks.
///
/// `contact_lookalikes` answers with the records of the company that
/// carry the same registration number, ID, TIN or name -- and whether
/// each is already in the role being typed. Two things follow, and
/// both are said before Save rather than refused at it, because the
/// database cannot tell a duplicated record from a number typed
/// wrongly:
///
///   * the same role is already on file: Save would make a second
///     supplier record for the same company, with a second code and
///     bills split between them. The record on file is offered
///     instead.
///   * another role is on file: the same company, and Save links the
///     new record to it -- 0481's trigger does that on the way in --
///     so the sheet on either shows both.
///
/// A name is neither. Two "Ali Enterprise"s in one town are ordinary,
/// so a name match is mentioned and links nothing.
enum LookalikeKind {
  /// A record already in the role being typed, on an identifier.
  duplicate,

  /// The same company in another role, on an identifier.
  sameCompany,

  /// The same name, and nothing else.
  sameName,
}

class Lookalike {
  const Lookalike({
    required this.id,
    required this.code,
    required this.name,
    required this.contactType,
    required this.matchedOn,
    required this.sameRole,
  });

  /// One row of `contact_lookalikes`.
  factory Lookalike.fromJson(Map<String, dynamic> row) => Lookalike(
    id: '${row['id']}',
    code: '${row['code'] ?? ''}',
    name: '${row['name'] ?? ''}',
    contactType: '${row['contact_type'] ?? ''}',
    matchedOn: '${row['matched_on'] ?? ''}',
    sameRole: row['same_role'] == true,
  );

  final String id;
  final String code;
  final String name;
  final String contactType;

  /// `registration_no`, `id`, `tin` or `name`: the strongest reason
  /// the database had.
  final String matchedOn;
  final bool sameRole;

  LookalikeKind get kind => matchedOn == 'name'
      ? LookalikeKind.sameName
      : sameRole
      ? LookalikeKind.duplicate
      : LookalikeKind.sameCompany;

  /// The reason, as a phrase: "the same registration number".
  String get reason => switch (matchedOn) {
    'registration_no' => 'the same registration number',
    'id' => 'the same ID number',
    'tin' => 'the same TIN',
    'name' => 'the same name',
    _ => 'the same details',
  };

  /// The one line: what is on file, and as what.
  String get title {
    final role = contactRoleLabel(contactType).toLowerCase();
    return switch (kind) {
      LookalikeKind.duplicate => 'Already on file as $role $code',
      LookalikeKind.sameCompany => 'The same company as $role $code',
      LookalikeKind.sameName => 'Same name as $role $code',
    };
  }

  /// What follows from it, said in full: the sentence that tells the
  /// person what Save will do.
  String get detail => switch (kind) {
    LookalikeKind.duplicate =>
      '${_cap(reason)} as $name. Saving makes a second record '
          'with its own code; open the one on file instead.',
    LookalikeKind.sameCompany =>
      '${_cap(reason)} as $name. This record will be linked '
          'to it, and both show on the company\'s records.',
    LookalikeKind.sameName =>
      'A name alone does not make it the same company; the records '
          'will not be linked.',
  };
}

String _cap(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Whether there is enough typed to be worth asking about.
///
/// An identifier of any length is: `1234567-X` is short and specific.
/// A name is worth asking about from its third letter, so "Al" does
/// not match every Al there is while the rest is being typed.
bool worthAskingAbout({
  required String name,
  String? registrationNo,
  String? tin,
  String? idValue,
}) {
  bool has(String? s) => s != null && s.trim().isNotEmpty;
  return has(registrationNo) ||
      has(tin) ||
      has(idValue) ||
      name.trim().length >= 3;
}

/// The notice under the identity fields: one row per record on file,
/// the ones Save would duplicate first, in the colour of what they
/// mean. Nothing at all when there are none -- a notice shown every
/// time is one nobody reads when it matters.
class ContactLookalikesNotice extends StatelessWidget {
  const ContactLookalikesNotice({
    super.key,
    required this.rows,
    this.onOpen,
  });

  final List<Lookalike> rows;

  /// Where "Open" goes. Defaults to the contact's own editor, which
  /// replaces this one -- the point being not to save this one.
  final void Function(Lookalike)? onOpen;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Column(
          children: [
            for (final (i, r) in rows.indexed) ...[
              if (i > 0) const Divider(height: 1),
              ListTile(
                key: ValueKey('lookalike-${r.id}'),
                dense: true,
                leading: Icon(
                  switch (r.kind) {
                    LookalikeKind.duplicate => Icons.copy_all_outlined,
                    LookalikeKind.sameCompany => Icons.link,
                    LookalikeKind.sameName =>
                      contactRoleIcon(r.contactType),
                  },
                  size: 20,
                  color: switch (r.kind) {
                    LookalikeKind.duplicate => context.colors.warning,
                    LookalikeKind.sameCompany => context.colors.info,
                    LookalikeKind.sameName => theme.colorScheme.outline,
                  },
                ),
                title: Text(
                  r.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: switch (r.kind) {
                      LookalikeKind.duplicate => context.colors.warning,
                      LookalikeKind.sameCompany => context.colors.info,
                      LookalikeKind.sameName => null,
                    },
                  ),
                ),
                subtitle: Text(r.detail, style: theme.textTheme.bodySmall),
                trailing: TextButton(
                  onPressed: () => onOpen != null
                      ? onOpen!(r)
                      : context.go('/contacts/${r.id}'),
                  child: const Text('Open'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
