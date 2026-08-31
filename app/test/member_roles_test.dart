import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/data/models.dart';

/// What a company may call the people it lets in.
///
/// `memberRoles` is a hand-written map in Dart of `app.member_role`,
/// which is declared in `0001` and extended twice since. Nothing was
/// checking the two still agree, and they had not for two years:
/// `0024` added `hr_manager` and the map never gained it, so the role
/// that `app.can_manage_hr` and `app.can_run_payroll` are built on, and
/// that `0119` and `0121` route expense claims to, could not be given
/// to anybody. Payroll was delegable in the database and admin-only in
/// the app.
///
/// Read out of the migrations rather than copied. A copied list is one
/// that drifts silently, which is the failure this file exists for.
void main() {
  /// Every value `app.member_role` holds, in declaration order: the
  /// `create type` in 0001 plus every `add value` after it.
  List<String> rolesInSql() {
    final dir = Directory('../supabase/migrations');
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final roles = <String>[];
    for (final f in files) {
      final sql = f.readAsStringSync();

      final block = RegExp(
        r"create type app\.member_role as enum \(([^)]*)\)",
      ).firstMatch(sql);
      if (block != null) {
        // Only the quoted values. The block is half comment, and every
        // one of those comments is a sentence about a role.
        roles.addAll(
          RegExp("'([a-z_]+)'")
              .allMatches(block.group(1)!)
              .map((m) => m.group(1)!),
        );
      }

      for (final m in RegExp(
        r"alter type app\.member_role add value if not exists '([a-z_]+)'"
        r"(?:\s+(after|before)\s+'([a-z_]+)')?",
      ).allMatches(sql)) {
        // The `after` clause is the whole point of reading these rather
        // than appending them. `0024` puts `hr_manager` after
        // `accountant`, so in the enum it sits fourth — ahead of two
        // values an earlier file declared later in its own text — and a
        // reconstruction that appended in file order would place it
        // last and then assert the map is wrong for matching the
        // database.
        final anchor = m.group(3);
        if (anchor == null || !roles.contains(anchor)) {
          roles.add(m.group(1)!);
        } else {
          roles.insert(
            roles.indexOf(anchor) + (m.group(2) == 'before' ? 0 : 1),
            m.group(1)!,
          );
        }
      }
    }
    return roles;
  }

  /// `employee`, and the reason it is named here rather than offered.
  ///
  /// `0024` added it alongside `hr_manager`, and unlike `hr_manager` no
  /// SQL anywhere reads it: it appears in no `has_org_role` array, no
  /// policy and no guard. Self-service is scoped by
  /// `app.my_employee_id` — whether a payroll record is linked to the
  /// login — and not by the role at all, so an `employee` may do
  /// precisely what a `viewer` may do.
  ///
  /// Offering both in a dropdown would sell a distinction the database
  /// does not make, and somebody would reasonably read "Employee" as
  /// narrower than "View Only" and give away more than they meant to.
  /// It stays excluded until something enforces the difference, and
  /// this constant is where to delete it from when something does.
  const notOffered = {'employee'};

  test('every role the database has, this company can hand out', () {
    final inSql = rolesInSql().toSet();
    // Guards the two regular expressions above: expressions that matched
    // nothing would make every claim below vacuously true.
    expect(inSql.length, greaterThan(6));
    expect(inSql, contains('owner'));
    expect(inSql, contains('hr_manager'));

    expect(
      inSql.difference(memberRoles.keys.toSet()).difference(notOffered),
      isEmpty,
      reason: 'a role the database allows that nothing can assign',
    );
  });

  test('and offers nothing the database would refuse', () {
    // The other direction, and the one that fails loudly rather than
    // quietly: assigning a role no enum value matches is a 22P02 in the
    // user's face, not a missing option.
    expect(memberRoles.keys.toSet().difference(rolesInSql().toSet()), isEmpty);
  });

  test('in the order the database declares them', () {
    // Not decoration. The map's order is the dropdown's order and the
    // order of the reference card on the team screen, and both read as
    // descending authority. A role appended to the map rather than
    // placed would put HR between Sales and View Only.
    final inSql = rolesInSql().where(
      (r) => !notOffered.contains(r) && memberRoles.containsKey(r),
    );
    expect(memberRoles.keys.toList(), inSql.toList());
  });

  test('ownership is transferred, not handed out', () {
    // The invite dialog and the row's own dropdown each carried their
    // own `e.key != 'owner'`. This is that rule, stated once.
    expect(assignableRoles.map((e) => e.key), isNot(contains('owner')));
    expect(
      assignableRoles.length,
      memberRoles.length - 1,
      reason: 'owner is the only exclusion; nothing else may be dropped',
    );
  });

  test('a role is labelled even when it is one nothing offers', () {
    // `employee` is not in the map and rows can still carry it — the
    // enum allows it and the RPCs take the enum, not the map. The team
    // list has to say something sensible rather than nothing.
    expect(roleLabel('employee'), 'Employee');
    expect(roleLabel('hr_manager'), 'HR Manager');
    expect(roleLabel('accounts_clerk'), 'Accounts Clerk');
  });

  test('and something honest when it is not a role at all', () {
    // Null is the ordinary case here, not a defensive one: an
    // invitation that has not been accepted has no member row behind it.
    expect(roleLabel(null), '—');
    expect(roleLabel(''), '—');
  });

  test('every role says what it can do', () {
    // The reference card renders all of them. A blank description is a
    // row of empty space next to a name somebody is about to pick.
    for (final e in memberRoles.entries) {
      expect(e.value.label, isNotEmpty, reason: e.key);
      expect(e.value.description, isNotEmpty, reason: e.key);
    }
  });
}
