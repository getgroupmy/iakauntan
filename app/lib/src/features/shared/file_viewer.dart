import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error_text.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/attachments_repository.dart';
import '../../data/ocr_repository.dart';
import 'text_reader.dart';

/// A document, shown INSIDE the app.
///
/// ## The exposure this removes
///
/// Every one of the four places that used to open an attachment did the
/// same thing: mint a signed URL and hand it to
/// `LaunchMode.externalApplication`. That puts a working link to a
/// private document into another application — its address bar, its
/// history, its tab list, whatever a password manager or an extension
/// can read — for as long as the signature lasts, forwardable to
/// anybody. On a bank statement.
///
/// Asked for as: *"images or pdf files should not open using external
/// browser or app, all should be in app only ... to avoid exposure of
/// link and addresses"*.
///
/// So this takes the BYTES. `attachmentBytes` downloads through the
/// same authenticated client every other call uses, and no URL is
/// created at any point — there is nothing to leak rather than a leak
/// that expires.
///
/// ## What it can draw
///
/// An image, anywhere. A PDF in a browser, where `pdf.js` is vendored
/// and its pages are drawn to pictures. A PDF on a phone cannot be
/// drawn at all in this build, and that is SAID rather than quietly
/// falling back to the external opener the whole thing exists to
/// remove.
Future<void> showFileInApp(
  BuildContext context,
  WidgetRef ref, {
  /// Ignored when [fetch] is given.
  String storagePath = '',
  required String fileName,
  String? mimeType,

  /// Chat files live in their own bucket behind their own policy, so
  /// the caller says how to fetch rather than this guessing.
  Future<Uint8List> Function()? fetch,
}) async {
  // A caller that brought its own fetch does not need the org
  // repository at all -- the platform console has no org, and the mail
  // inbox reaches storage through the raw client. Requiring one here
  // would make this return silently on both.
  Future<Uint8List> Function()? load = fetch;
  if (load == null) {
    final repo = ref.read(repoProvider);
    if (repo == null) return;
    load = () => repo.attachmentBytes(storagePath);
  }
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _FileViewer(
        fileName: fileName,
        mimeType: mimeType,
        load: load!,
      ),
    ),
  );
}

/// Whether [fileName] or [mimeType] says this is a PDF.
///
/// The type first, because it is the thing the server recorded, and the
/// name only as a fallback — a browser that would not name a dropped
/// file leaves `mime_type` null, and `.pdf` is then all there is.
bool looksLikePdfFile(String fileName, String? mimeType) {
  final m = (mimeType ?? '').toLowerCase();
  if (m.contains('pdf')) return true;
  if (m.startsWith('image/')) return false;
  return fileName.toLowerCase().endsWith('.pdf');
}

/// Said where a PDF cannot be drawn at all.
///
/// Reachable on a desktop build: `pdfx` ships Android, iOS, macOS,
/// Windows and web, and `dart.library.io` is also true on Linux, where
/// there is no plugin behind the Dart API. Not reachable on a phone or
/// in a browser, which is where the people are.
const _noPdfHere =
    'A PDF cannot be drawn on this device. Open it in the app on a '
    'phone, or in a browser.';

class _FileViewer extends StatefulWidget {
  const _FileViewer({
    required this.fileName,
    required this.mimeType,
    required this.load,
  });

  final String fileName;
  final String? mimeType;
  final Future<Uint8List> Function() load;

  @override
  State<_FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<_FileViewer> {
  Uint8List? _bytes;
  List<Uint8List>? _pages;
  String? _problem;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final bytes = await widget.load();
      if (!mounted) return;
      if (!looksLikePdfFile(widget.fileName, widget.mimeType)) {
        setState(() => _bytes = bytes);
        return;
      }
      if (!canRenderPdfPages) {
        setState(() => _problem = _noPdfHere);
        return;
      }
      final List<Uint8List> pages;
      try {
        pages = await pdfPageImages(bytes);
      } catch (e) {
        // The file arrived; drawing it did not work. Said apart from
        // the download failure above, because `storageProblem` talks
        // about buckets and permissions and would send somebody to look
        // in entirely the wrong place.
        //
        // A PDF that will not open is ordinarily an encrypted one --
        // Malaysian banks send those -- so that is named first.
        if (!mounted) return;
        setState(() => _problem =
            'That PDF could not be opened. If it asks for a password '
            'when you open it elsewhere, this cannot read it yet.\n\n${errorText(e)}');
        return;
      }
      if (!mounted) return;
      setState(() => _pages = pages);
    } catch (e) {
      if (!mounted) return;
      setState(() => _problem = storageProblem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    final problem = _problem;
    if (problem != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Text(
            problem,
            key: const ValueKey('file-viewer-problem'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final bytes = _bytes;
    if (bytes != null) {
      // Pinch and drag, because a receipt photographed at arm's length
      // is unreadable at the size a phone will show it.
      return InteractiveViewer(
        key: const ValueKey('file-viewer-image'),
        maxScale: 6,
        child: Center(child: Image.memory(bytes)),
      );
    }

    final pages = _pages;
    if (pages != null) {
      if (pages.isEmpty) {
        return const Center(
          child: Text(
            'That PDF has no pages in it.',
            key: ValueKey('file-viewer-empty'),
          ),
        );
      }
      return ListView.separated(
        key: const ValueKey('file-viewer-pdf'),
        padding: const EdgeInsets.all(Space.md),
        itemCount: pages.length,
        separatorBuilder: (_, __) => const SizedBox(height: Space.md),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 6,
          child: Image.memory(pages[i]),
        ),
      );
    }

    return const Center(
      child: CircularProgressIndicator(key: ValueKey('file-viewer-loading')),
    );
  }
}
