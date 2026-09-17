import 'package:flutter_test/flutter_test.dart';

import 'package:iakauntan/src/data/reserved_names_repository.dart';

/// The two rules the reservation screens apply before the server does.
///
/// Neither is the authority — `app.check_host_label` refuses the same
/// names for the same reasons, and `workspace_by_host` decides whose
/// door a host is. What these buy is a person being told their name is
/// no good while they are still typing it, and a sign-in page not
/// making a request that could only ever come back empty.
///
/// So the interesting cases are the ones where the two must agree, and
/// the ones where asking at all is the mistake.
void main() {
  group('the name a company may ask for', () {
    // The blocklist as the table holds it, scope and all.
    const reserved = [
      {'name': 'lhdn', 'scope': 'both', 'reason': 'reads as a government agency'},
      {'name': 'www', 'scope': 'subdomain', 'reason': 'the platform itself'},
      {'name': 'postmaster', 'scope': 'mailbox', 'reason': 'required by RFC 5321'},
    ];

    String? check(String name, {String scope = 'subdomain'}) =>
        checkName(name, scope: scope, reserved: reserved);

    test('an ordinary name passes', () {
      expect(check('sinar'), isNull);
      expect(check('sinar-teknologi'), isNull);
      expect(check('abc'), isNull, reason: 'three characters is the floor');
    });

    test('and is folded the way the database folds it', () {
      expect(normalizeName('  Sinar  '), 'sinar');
      expect(check('SINAR'), isNull);
    });

    test('two characters is too short', () {
      // The regex that lets this through is the one with the middle run
      // marked optional, which is the bug this catches.
      expect(check('ab'), isNotNull);
    });

    test('63 is the limit, 64 is past it', () {
      expect(check('a' * 63), isNull);
      expect(check('a' * 64), isNotNull);
    });

    test('a hyphen may not start or end it', () {
      expect(check('-sinar'), isNotNull);
      expect(check('sinar-'), isNotNull);
    });

    test('and a dot, an underscore or a space is not a name at all', () {
      expect(check('sinar.teknologi'), isNotNull);
      expect(check('sinar_teknologi'), isNotNull);
      expect(check('sinar teknologi'), isNotNull);
      expect(check(''), isNotNull);
    });

    test('a punycode prefix is refused', () {
      // Otherwise a name could be spelled in a script this cannot read,
      // which is how one company's door comes to look like another's.
      expect(check('xn--sinar'), isNotNull);
    });

    test('a reserved name is refused, and says why', () {
      expect(check('lhdn'), contains('government agency'));
      expect(check('LHDN'), isNotNull, reason: 'folded before it is looked up');
    });

    test('and scope is honoured rather than ignored', () {
      // `www` is the platform's front page and meaningless as a mailbox;
      // `postmaster` is owed to RFC 5321 and harmless as a subdomain.
      expect(check('www', scope: 'subdomain'), isNotNull);
      expect(check('www', scope: 'mailbox'), isNull);
      expect(check('postmaster', scope: 'mailbox'), isNotNull);
      expect(check('postmaster', scope: 'subdomain'), isNull);
    });
  });

  group('whose door a host is', () {
    test('a company subdomain is worth asking about', () {
      expect(workspaceLabel('sinar.iakauntan.com'), 'sinar');
      expect(workspaceLabel('Sinar.iakauntan.com'), 'sinar');
      expect(workspaceLabel('sinar.iakauntan.com:443'), 'sinar');
      expect(workspaceLabel('sinar.staging.iakauntan.com'), 'sinar');
    });

    test('the bare domain is not', () {
      // Two labels means nothing in front of the domain. Asking would
      // be asking whether the platform is one of its own tenants.
      expect(workspaceLabel('iakauntan.com'), isNull);
    });

    test('nor are the platform\'s own hosts', () {
      for (final host in ['www', 'app', 'api', 'staging', 'dev']) {
        expect(workspaceLabel('$host.iakauntan.com'), isNull,
            reason: '$host is ours');
      }
    });

    test('nor a native build, which has no host', () {
      expect(workspaceLabel(''), isNull);
      expect(workspaceLabel('localhost'), isNull);
    });

    test('nor an address typed as a number', () {
      expect(workspaceLabel('127.0.0.1'), isNull);
      expect(workspaceLabel('192.168.1.10'), isNull);
    });
  });
}
