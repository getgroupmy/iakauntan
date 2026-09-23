import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'scan_availability.dart';

/// Says why scanning cannot run, and offers the way out where there is
/// one.
///
/// A dialog rather than a snackbar because it is a decision rather than
/// a notice: somebody pressed Scan and nothing is going to happen until
/// a setting changes, and a message that slides away after four seconds
/// leaves them pressing the button again.
Future<void> showScanBlocked(BuildContext context, ScanBlock block) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('scan-blocked'),
        icon: const Icon(Icons.auto_awesome_outlined),
        title: Text(block.title),
        content: Text(block.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            // "Close" rather than "Cancel": nothing was started, so
            // there is nothing to cancel.
            child: Text(block.hasAction ? 'Not now' : 'Close'),
          ),
          if (block.hasAction)
            FilledButton(
              key: const ValueKey('scan-blocked-go'),
              onPressed: () {
                Navigator.of(ctx).pop();
                context.go(block.route!);
              },
              child: Text(block.actionLabel!),
            ),
        ],
      ),
    );
