/// What came attached to a message, in the words a list needs.
///
/// `0328` built the table, the read policy and the grant for these and
/// the ingest path never wrote a row: a supplier e-mailing a PDF
/// invoice got the covering note filed and the invoice discarded, with
/// nothing saying so. `0354` files them. Everything here is pure and
/// asserted in `mail_attachments_test.dart`.
library;

/// A size a person can read, or nothing when it is not known.
///
/// Null rather than "0 B": a size the ingest path did not record is not
/// a file of no size, and showing one would be a claim nobody made.
String? sizeLabel(Object? bytes) {
  final n = int.tryParse('${bytes ?? ''}');
  if (n == null || n <= 0) return null;
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).round()} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// What a file is, from the type the sender declared.
///
/// The declared type, not the extension: a `.pdf` that arrived as
/// `image/jpeg` is a photograph somebody renamed, and the sender's own
/// header is the better evidence of the two. Falls back to the
/// extension only when nothing was declared.
String kindLabel({String? contentType, required String filename}) {
  final declared = (contentType ?? '').trim().toLowerCase();
  if (declared.isNotEmpty) {
    if (declared == 'application/pdf') return 'PDF';
    if (declared.startsWith('image/')) return 'Image';
    if (declared.startsWith('text/csv') ||
        declared == 'application/vnd.ms-excel' ||
        declared.contains('spreadsheet')) {
      return 'Spreadsheet';
    }
    if (declared.startsWith('text/')) return 'Text';
  }
  final dot = filename.lastIndexOf('.');
  if (dot > 0 && dot < filename.length - 1) {
    return filename.substring(dot + 1).toUpperCase();
  }
  return 'File';
}

/// The line under an attachment's name: what it is, and how big.
///
/// Joined rather than concatenated so a missing size leaves no stray
/// separator — "PDF · " is the shape this avoids.
String attachmentLine(Map<String, dynamic> row) {
  final parts = <String>[
    kindLabel(
      contentType: row['content_type'] as String?,
      filename: '${row['filename'] ?? ''}',
    ),
    ?sizeLabel(row['size_bytes']),
  ];
  return parts.join(' · ');
}

/// What to say where the attachments would be.
///
/// Null when there is nothing to say — a message with no attachments
/// should show no attachment section at all, rather than a line
/// announcing an absence.
String? attachmentsHeading(int count) {
  if (count <= 0) return null;
  return count == 1 ? '1 attachment' : '$count attachments';
}
