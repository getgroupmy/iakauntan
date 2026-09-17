import 'package:flutter_test/flutter_test.dart';
import 'package:iakauntan/src/features/settings/einvoice_credentials.dart';

void main() {
  group('whether removing them leaves the company live against nothing', () {
    test('yes, when it is the environment being submitted to', () {
      expect(
        removingLeavesItLive(
          enabled: true,
          environment: 'production',
          current: 'production',
        ),
        isTrue,
      );
    });

    test('no, when submission is off anyway', () {
      expect(
        removingLeavesItLive(
          enabled: false,
          environment: 'production',
          current: 'production',
        ),
        isFalse,
      );
    });

    test('no, when the other environment is the live one', () {
      // Clearing the sandbox credentials of a company submitting to
      // production changes nothing about whether it can submit.
      expect(
        removingLeavesItLive(
          enabled: true,
          environment: 'sandbox',
          current: 'production',
        ),
        isFalse,
      );
      expect(
        removingLeavesItLive(
          enabled: true,
          environment: 'production',
          current: 'sandbox',
        ),
        isFalse,
      );
    });
  });

  group('what it says before it does it', () {
    test('names the environment', () {
      expect(
        removeCredentialsMessage(
          environment: 'production',
          alsoDisables: false,
        ),
        contains('production'),
      );
      expect(
        removeCredentialsMessage(environment: 'sandbox', alsoDisables: false),
        contains('sandbox'),
      );
    });

    test('says submission goes off, when it does', () {
      final s = removeCredentialsMessage(
        environment: 'production',
        alsoDisables: true,
      );
      expect(s, contains('switched off'));
      expect(s, contains('cannot log in'));
    });

    test('says submission is left alone, when it is', () {
      final s = removeCredentialsMessage(
        environment: 'sandbox',
        alsoDisables: false,
      );
      expect(s, contains('left alone'));
      expect(s, isNot(contains('switched off')));
    });

    test('an unexpected environment still reads as one of the two', () {
      // The column is free text; the sentence should not print
      // something that is neither.
      final s = removeCredentialsMessage(
        environment: 'staging',
        alsoDisables: false,
      );
      expect(s, contains('sandbox'));
    });
  });
}
