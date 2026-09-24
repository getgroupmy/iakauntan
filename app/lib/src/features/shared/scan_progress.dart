import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// What the app is doing to a document somebody just handed it.
///
/// Coarse on purpose. Neither half of this reports real progress:
/// `uploadBinary` gives no byte count, and the edge function answers
/// once — there is no stream of "40% read" to draw. A bar filling
/// smoothly to somebody's own schedule would be a more convincing lie
/// than no bar at all, so what moves here is the STEP, and the sentence
/// under it says which one.
enum ScanStage {
  /// Putting the file in the bucket. Ours, and usually the quick half.
  attaching(
    step: 1,
    fraction: 0.35,
    said: 'Attaching the file',
    detail: 'Keeping a copy before anything else happens to it.',
  ),

  /// The reader has it. This is the half that takes the time, and the
  /// half that is somebody else's server.
  reading(
    step: 2,
    fraction: 0.75,
    said: 'Reading the document',
    detail: 'Finding the supplier, the date and the figures.',
  ),

  /// `0703`. The chosen reader would not answer and this machine is
  /// having a go instead. Named rather than hidden: it is why the wait
  /// just got longer, and it is also why the answer may be thinner —
  /// the local reader reads the printing rather than understanding the
  /// document.
  readingHere(
    step: 2,
    fraction: 0.85,
    said: 'Reading it on this device instead',
    detail: 'The reader that was chosen did not answer.',
  );

  const ScanStage({
    required this.step,
    required this.fraction,
    required this.said,
    required this.detail,
  });

  final int step;
  final double fraction;
  final String said;
  final String detail;

  static const steps = 2;
}

/// How long somebody is made to wait before they are offered a way out.
///
/// The request was "block all activity till its 100% completed", and
/// that is what this does — for three quarters of a minute. After that
/// there is a button, because the alternative is an app that has to be
/// force-quit when a request never comes back, and a scan CAN hang: the
/// edge function answers a vendor that is sometimes not answering
/// anybody.
///
/// Pressing it does not cancel anything. The upload and the reading
/// carry on, the scan row is still written, and the inbox will show
/// whatever came of it — what the button returns is the screen.
const scanWaitBeforeEscape = Duration(seconds: 45);

/// Holds the screen while a document is attached and read.
///
/// One modal, no barrier dismiss, no back gesture, and every exit goes
/// through the same `finally` — a progress dialog that outlives the work
/// it is about is worse than no progress dialog, because the only way
/// out of it is to reload the page.
///
/// [action] is handed a reporter to call as it moves between stages.
/// Whatever it returns is returned from here, and whatever it throws is
/// rethrown, so wrapping a call in this changes nothing about how the
/// caller handles it.
Future<T> whileScanning<T>(
  BuildContext context, {
  ScanStage from = ScanStage.attaching,
  required Future<T> Function(void Function(ScanStage) report) action,
}) async {
  final stage = ValueNotifier<ScanStage>(from);

  // The dialog's OWN context, captured as it builds, and popped through
  // that rather than through the caller's navigator. Popping "the
  // current route" from out here would pop whatever happens to be on
  // top by the time the work finishes, which on a slow scan is not
  // necessarily this.
  BuildContext? inside;
  var done = false;

  // Not awaited: `showDialog`'s future completes when the dialog is
  // DISMISSED, so awaiting it here would wait for the thing this
  // function is responsible for closing.
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (dialogContext) {
      inside = dialogContext;
      // A rescan has no upload, so it starts at step two of two and
      // the counter would be the only thing on screen implying a step
      // one that never happened.
      return _ScanProgressDialog(
        stage: stage,
        showSteps: from == ScanStage.attaching,
      );
    },
  ));

  try {
    return await action((next) {
      if (!done) stage.value = next;
    });
  } finally {
    done = true;
    final dialogContext = inside;
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext).pop();
    }
    stage.dispose();
  }
}

class _ScanProgressDialog extends StatefulWidget {
  const _ScanProgressDialog({required this.stage, required this.showSteps});

  final ValueNotifier<ScanStage> stage;
  final bool showSteps;

  @override
  State<_ScanProgressDialog> createState() => _ScanProgressDialogState();
}

class _ScanProgressDialogState extends State<_ScanProgressDialog> {
  Timer? _timer;
  bool _mayLeave = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(scanWaitBeforeEscape, () {
      if (mounted) setState(() => _mayLeave = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // The whole point. A back gesture on a phone and the browser's
      // back button both reach a dialog, and either one would leave the
      // upload running behind a screen that says nothing about it.
      canPop: false,
      child: AlertDialog(
        title: const Text('Scanning'),
        content: ValueListenableBuilder<ScanStage>(
          valueListenable: widget.stage,
          builder: (context, stage, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(stage.said, style: theme.textTheme.titleSmall),
              const SizedBox(height: Space.xs),
              Text(stage.detail, style: theme.textTheme.bodySmall),
              const SizedBox(height: Space.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: stage.fraction,
                  minHeight: 6,
                ),
              ),
              if (widget.showSteps) ...[
                const SizedBox(height: Space.xs),
                Text(
                  'Step ${stage.step} of ${ScanStage.steps}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: Space.sm),
              Text(
                'Keep this open until it finishes.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        // Null rather than an empty list for the first three quarters
        // of a minute: `actions: []` still draws the button strip, and
        // an empty strip under a progress bar reads as a dialog whose
        // buttons failed to load.
        actions: _mayLeave
            ? [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Leave it running'),
                ),
              ]
            : null,
      ),
    );
  }
}
