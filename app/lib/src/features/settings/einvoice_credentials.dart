import 'package:flutter/material.dart';

/// Taking the MyInvois credentials back out.
///
/// `clear_einvoice_credentials` has been in the schema since companies
/// were allowed their own LHDN credentials, and had no caller: a client
/// id and secret, once entered, could be overwritten but never removed.
/// A company leaving the product, changing intermediary, or handing an
/// accountant's sandbox credentials back had no way to do it, and the
/// secret stayed server-side indefinitely.

/// Whether removing these credentials would leave the company flagged
/// live against nothing.
///
/// The card already learned this in the other direction: a failed save
/// once "left the organization flagged as e-Invoice-enabled with a
/// client id and no secret anywhere — a company marked live against a
/// submitter that cannot log in". Removing the credentials of the
/// environment the company is actually submitting to arrives at the
/// same state on purpose, so submission is switched off with them.
bool removingLeavesItLive({
  required bool enabled,
  required String environment,
  required String current,
}) =>
    enabled && environment == current;

/// What removing them is going to do, said before it happens.
String removeCredentialsMessage({
  required String environment,
  required bool alsoDisables,
}) {
  final which = environment == 'production' ? 'production' : 'sandbox';
  return alsoDisables
      ? 'The $which client id and secret are deleted, and e-Invoice '
          'submission is switched off with them — a company left enabled '
          'with no credentials is one marked live against a submitter '
          'that cannot log in.'
      : 'The $which client id and secret are deleted. Submission is '
          'pointed at the other environment and is left alone.';
}

/// Ask before deleting a secret nobody can read back.
Future<bool> askRemoveCredentials(
  BuildContext context, {
  required String environment,
  required bool alsoDisables,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove these credentials?'),
        content: Text(
          removeCredentialsMessage(
            environment: environment,
            alsoDisables: alsoDisables,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            key: const ValueKey('remove-einvoice-credentials'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    ) ??
    false;
