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
  // administrator can fix under “How it reads” either — the switch is
  // under Subscription and it is an OWNER's — so this offers no
  // shortcut there, which would be a door onto a control they cannot
  // work.
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
          : 'An administrator switches it on under “How it reads” on '
              'the AI SmartScan screen, and only an administrator can — '
              'so nothing here will let you.$freeSentence',
      // The route only where it leads somewhere the person can act.
      actionLabel: canAdmin ? 'Open the setup' : null,
      route: canAdmin ? '/smartscan' : null,
    );
  }

  return null;
}

/// The readers on offer here that open a PDF, named for a sentence.
///
/// Only the ones that say so. A reader whose kind the database has not
/// heard of answers null, and null is NOT taken as a yes here: this
/// list becomes a promise on screen — "X reads them" — and a promise
/// that turns into the same refusal one setting later is worse than
/// saying nothing.
List<OcrProvider> pdfReaders(
  OcrSettings ocr, {
  required bool deviceReadsPdf,
  String? besides,
}) =>
    [
      for (final p in ocr.providers)
        if (p.isActive &&
            p.ready &&
            p.code != besides &&
            (p.runsOnDevice ? deviceReadsPdf : p.readsPdf == true))
          p,
    ];

/// "A and B", "A, B and C", or "A".
String namesList(Iterable<String> names) {
  final all = names.toList();
  if (all.isEmpty) return '';
  if (all.length == 1) return all.first;
  return '${all.sublist(0, all.length - 1).join(', ')} and ${all.last}';
}

/// A PDF handed to a reader that cannot open one, said before the
/// upload.
///
/// From a report, with the PDF attached. A supplier bill was uploaded
/// into AI SmartScan by a company on Gemini, and the inbox came back
///
///     This reader takes photographs, not PDFs. Photograph the
///     document, or switch to Claude, which reads PDFs.
///
/// That refusal is `supabase/functions/ocr/index.ts` inside
/// `readOpenAiShaped`, and it is right: chat-completions takes an image
/// part, and a PDF would be a different endpoint on every vendor
/// wearing that shape. What is wrong is WHEN it arrives — after the
/// upload, after the charge and after the refund, for a question that
/// could have been answered before the file was chosen. The same
/// argument [scanBlock] was written for, one step further in.
///
/// [deviceReadsPdf] is passed rather than read, because it differs by
/// platform — `pdf.js` in a browser, ML Kit on a phone — and this
/// function has to stay pure enough to put a table of cases through.
/// The database declines to answer for the on-device reader for the
/// same reason (`app.reader_reads_pdf`, `0697`).
ScanBlock? pdfBlock(
  OcrSettings? ocr, {
  required bool isPdf,
  required bool canAdmin,
  required bool deviceReadsPdf,
}) {
  if (!isPdf) return null;

  // Not loaded, or a reader the status does not describe. Not a block,
  // for the reason `scanBlock` gives: the edge function is the real
  // gate, and refusing on a question that has not come back yet would
  // be this file inventing an outage.
  if (ocr == null) return null;
  final current = ocr.current;
  if (current == null) return null;

  // Unknown reads as yes HERE and as no in [pdfReaders], and the
  // asymmetry is deliberate. Refusing on an unknown would withdraw a
  // reader the platform had just added; recommending one would promise
  // something nobody has checked.
  final takesIt =
      current.runsOnDevice ? deviceReadsPdf : current.readsPdf != false;
  if (takesIt) return null;

  final others = pdfReaders(ocr,
      deviceReadsPdf: deviceReadsPdf, besides: current.code);
  final whoSwitches = canAdmin
      ? '“How it reads” on the AI SmartScan screen is where the reader '
          'is chosen.'
      : 'An administrator chooses the reader under “How it reads”, '
          'and only an administrator can.';
  final alternatives = others.isEmpty
      // No promise. A company whose platform offers nothing else is
      // told to photograph the page, which always works, rather than
      // sent to a screen that cannot help.
      ? 'No other reader on offer here opens one either.'
      : '${namesList(others.map((p) => p.name))} '
          '${others.length == 1 ? 'opens' : 'open'} them, and $whoSwitches';

  final who =
      current.runsOnDevice ? 'The reader on this device' : current.name;

  return ScanBlock(
    title: 'This reader does not open PDFs',
    // The last sentence is unconditional on purpose. Whatever the
    // platform offers and whoever is asking, a photograph of the page
    // is read by every reader there is — so nobody is left holding a
    // document with no way forward.
    message: '$who reads photographs, not PDFs. $alternatives '
        'Photographing the page works whichever reader is in force.',
    // Only where there is something to switch TO, and only for
    // somebody who can switch it. A door onto a screen that will not
    // help is worse than no door — the whole of `2f012feb`.
    actionLabel: canAdmin && others.isNotEmpty ? 'Open the setup' : null,
    route: canAdmin && others.isNotEmpty ? '/smartscan' : null,
  );
}
