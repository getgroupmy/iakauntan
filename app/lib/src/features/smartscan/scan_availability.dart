import '../../data/ocr_repository.dart';

/// Why AI SmartScan cannot run, said before the camera opens.
///
/// From a report: photographing a document in a company that had never
/// switched scanning on produced
///
///     Could not read it: FunctionException(status: 403, details:
///     {error: Document scanning is switched off for this organization.
///     An administrator turns it on in Settings., details: null},
///     reasonPhrase: )
///
/// in a snackbar, AFTER the photograph was taken, and then the module
/// asked which kind of document it was — of a scan that never happened.
///
/// Two things were wrong and the second is the one worth naming. The
/// raw `FunctionException` is ugly; asking somebody to photograph a
/// document in order to find out that the feature is off is the actual
/// failure. `settings_screen` already draws this line for the same
/// setting: "a screen that could have predicted its own refusal and did
/// not" is the thing to avoid, so the flow predicts it.
class ScanBlock {
  const ScanBlock({
    required this.title,
    required this.message,
    this.actionLabel,
    this.route,
  });

  final String title;
  final String message;

  /// The way out, where the person looking at it has one. Null for
  /// somebody who cannot fix it themselves — an ordinary user cannot
  /// turn scanning on, because `set_ocr_settings` refuses anybody but
  /// an administrator, and a button that leads to a screen they will be
  /// refused at is worse than no button.
  final String? actionLabel;
  final String? route;

  bool get hasAction => actionLabel != null && route != null;
}

/// The block that applies, or null when scanning can go ahead.
///
/// [canAdmin] decides what is offered rather than what is said: the
/// reason is the same for everybody, and only the way out differs.
ScanBlock? scanBlock(
  OcrSettings? ocr, {
  required bool canAdmin,
}) {
  // Not loaded. Not a block: the flow goes ahead, the edge function is
  // the real gate, and refusing on a question that has not come back
  // yet would be this file inventing an outage.
  if (ocr == null) return null;

  // A module before it is a setting. `0682`. Not something an
  // administrator can fix in Settings — the switch is under
  // Subscription and it is an OWNER's — so this offers no shortcut
  // there, which would be a door onto a control they cannot work.
  if (!ocr.hasModule) {
    return const ScanBlock(
      title: 'AI SmartScan is not switched on for this company',
      message:
          'It is a module rather than a setting, so it is switched on '
          'under Subscription by an owner. Once it is, photographing a '
          'bill, a receipt, a name card or a bank statement reads it and '
          'fills the form in.',
    );
  }

  if (!ocr.enabled) {
    // The free reader, named, because the alternative reading of "turn
    // it on" is "start paying for something". It runs on the device --
    // ML Kit on a phone, Tesseract in a browser -- so it costs nothing
    // and the file never leaves the machine.
    final free = ocr.providers
        .where((p) => p.isActive && p.price == 0)
        .firstOrNull;
    final freeSentence = free == null
        ? ''
        : ' There is a free reader on the list — ${free.name} — so this '
            'does not have to mean buying credit.';

    return ScanBlock(
      title: 'AI SmartScan is not switched on yet',
      message: canAdmin
          ? 'Switch it on and choose which reader to use, and this '
              'document is read the moment it is photographed.$freeSentence'
          : 'An administrator switches it on in Settings, and only an '
              'administrator can — so nothing here will let you.'
              '$freeSentence',
      // The route only where it leads somewhere the person can act.
      actionLabel: canAdmin ? 'Open Settings' : null,
      route: canAdmin ? '/settings' : null,
    );
  }

  return null;
}
