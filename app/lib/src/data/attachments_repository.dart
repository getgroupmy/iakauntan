import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/format.dart';
import 'repository.dart';

/// A file filed against a record.
class Attachment {
  Attachment({
    required this.id,
    required this.fileName,
    required this.storagePath,
    required this.createdAt,
    this.mimeType,
    this.fileSize,
    this.isEvidence = false,
  });

  final String id;
  final String fileName;
  final String storagePath;
  final DateTime createdAt;
  final String? mimeType;
  final int? fileSize;

  /// Whether a posting or a reading was built from this file, so it
  /// stays with the record. `0708`. Defaults false: a caller that did
  /// not ask must not draw a lock it knows nothing about — the trigger
  /// refuses either way.
  final bool isEvidence;

  String get sizeLabel {
    final b = fileSize ?? 0;
    if (b == 0) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        id: j['id'] as String,
        fileName: j['file_name']?.toString() ?? '',
        storagePath: j['storage_path']?.toString() ?? '',
        createdAt: Fmt.parseDate(j['created_at']) ?? DateTime.now(),
        mimeType: j['mime_type']?.toString(),
        fileSize: j['file_size'] == null ? null : Fmt.toInt(j['file_size']),
        isEvidence: j['is_evidence'] == true,
      );
}

/// The SHA-256 of a file's bytes, lowercase hex.
///
/// ## Why the bytes and not the name
///
/// `stampedFileName` puts the moment of upload into every name, so two
/// uploads of one file NEVER share a name -- which is the right answer
/// for telling two downloads apart and useless for telling two uploads
/// together. `file_size` on its own is a coincidence waiting to happen.
///
/// The only question worth asking is whether the CONTENT is the same,
/// and this answers exactly that: identical or not, with nothing in
/// between and no false positive to explain to somebody whose two
/// statements happen to be the same length.
///
/// ## What it is for
///
/// Not for refusing an upload. Somebody re-uploads a file when the
/// first scan went badly and they want another go, which is a thing
/// they are entitled to do on their own document. It is for LOOKING UP,
/// so the app can say "this is already here, from the 3rd, filed
/// against that bill" and let the person decide -- and, where they do
/// not want a second go, hand back the reading that was already paid
/// for rather than buying it twice.
///
/// Lowercase hex because `0711`'s check constraint demands it: a column
/// that quietly accepts an uppercase digest is a column where two
/// spellings of one file do not match each other.
///
/// ## Recorded now, matched later
///
/// Nothing reads this yet. It is written on every upload from `0711`
/// onward so that when the lookup and its screen land there is a
/// history to match against — a hash cannot be computed backwards
/// without downloading every stored object, so the only way to have
/// one for today's uploads is to take it today.
///
/// The lookup was written and then TAKEN OUT of this commit on
/// purpose. `check_unreachable.py` refused it — "a wrapper for a call
/// nobody can make is a promise the product does not keep" — and it
/// was right: reusing an existing attachment is not the one-liner it
/// looks like, because a row carries `entity_table`, `entity_id` and
/// `0708`'s evidence lock, and handing a new document an attachment
/// filed against a different record needs more thought than a commit
/// about hashing should contain.
String contentHash(Uint8List bytes) => sha256.convert(bytes).toString();

/// The name a file is stored under, with the moment it arrived in it.
///
/// Asked for as "when the file is uploaded it should also add date and
/// time in the filename". Two files called `invoice.pdf` filed against
/// different bills, downloaded into the same folder, used to be
/// `invoice.pdf` and `invoice (1).pdf` — and which was which was a
/// question nobody could answer from the name.
///
/// `20260924-1710` rather than `24-09-2026 5:10pm`: it sorts, it has no
/// spaces or colons to survive a filesystem, and it is unambiguous in a
/// country that writes dates the other way round from the machine.
///
/// The extension stays last, because that is what every operating
/// system opens the file by. A name with no extension is stamped at the
/// end and left alone.
String stampedFileName(String original, DateTime when) {
  String two(int v) => v.toString().padLeft(2, '0');
  final stamp = '${when.year}${two(when.month)}${two(when.day)}'
      '-${two(when.hour)}${two(when.minute)}';

  final name = original.trim().isEmpty ? 'file' : original.trim();
  final dot = name.lastIndexOf('.');
  // A dot at the very start is a hidden file, not an extension, and one
  // at the very end is a typo — neither splits into a name and a suffix.
  if (dot <= 0 || dot == name.length - 1) return '${name}_$stamp';
  return '${name.substring(0, dot)}_$stamp${name.substring(dot)}';
}

/// Files filed against a record.
///
/// The path is `<org>/<table>/<record>/<file>` and that is not a
/// convention the client is free to vary: the storage policies read the
/// organization, the table and the record straight out of the object
/// name to decide who may see it, and a database trigger refuses any row
/// whose path does not match its own columns.
extension RepoAttachments on Repo {
  static const bucket = 'attachments';

  /// The files on a record, each saying whether it can still be removed.
  ///
  /// Through `attachments_of` rather than the table, because
  /// `is_evidence` is a question about a posting and a reading — see
  /// `0708`. One round trip for the list rather than one per file.
  Future<List<Attachment>> attachments(String table, String recordId) async =>
      Repo.rows(await client.rpc('attachments_of', params: {
        'p_org_id': orgId,
        'p_table': table,
        'p_record_id': recordId,
      })).map(Attachment.fromJson).toList();

  /// Returns the id of the row created, which is what a scan is asked
  /// for.
  /// [keepForLater] marks the row `kept_at`: somebody uploaded this to
  /// KEEP it, not to have it read. `0714`. It is what puts the file in
  /// the AI SmartScan list without an `ocr_scans` row to carry it --
  /// and without that mark the file is in the bucket and visible
  /// nowhere in the product, which is not "saved for later" at all.
  ///
  /// False on every other upload, so an attachment filed against a bill
  /// is exactly what it was.
  Future<String> uploadAttachment({
    required String table,
    required String recordId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
    bool keepForLater = false,
  }) async {
    // A filename goes into an object key and into a URL. Anything that
    // is not plainly a name is replaced rather than escaped, and the
    // uuid in front keeps two files of the same name apart.
    // Stamped before anything else, so the name in the record and the
    // name in the object key are the same name. `0708`.
    final stamped = stampedFileName(fileName, DateTime.now());
    final safe = stamped
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final key = '${DateTime.now().millisecondsSinceEpoch}-'
        '${safe.isEmpty ? 'file' : safe}';
    final path = '$orgId/$table/$recordId/$key';

    await client.storage.from(bucket).uploadBinary(path, bytes);
    final row = await client
        .from('attachments')
        .insert(attachmentRow(
          orgId: orgId,
          table: table,
          recordId: recordId,
          fileName: stamped,
          path: path,
          bytes: bytes,
          mimeType: mimeType,
          keepForLater: keepForLater,
        ))
        .select('id')
        .single();
    return row['id'].toString();
  }

  /// Upload a file to KEEP, not to read. `0714`.
  ///
  /// A method rather than `uploadAttachment(keepForLater: true)` at the
  /// call site, and that is the whole of why it exists: `kept_at` is
  /// the single column that puts the file in the AI SmartScan list, so
  /// a `true` that became a `false` would leave the bytes in the bucket
  /// and the document visible nowhere in the product. A boolean at a
  /// call site is a boolean somebody can quietly get wrong; there is no
  /// boolean here to get wrong.
  Future<String> keepAttachment({
    required String table,
    required String recordId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) =>
      uploadAttachment(
        table: table,
        recordId: recordId,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        keepForLater: true,
      );

  /// A file with these exact bytes this organization has filed before,
  /// or null.
  ///
  /// `0711`. Asked BEFORE an upload, so somebody who sends the same
  /// statement twice is told rather than charged for a second reading
  /// of it.
  ///
  /// ## Null means "nothing found", and that is two different things
  ///
  /// No such file, and no file whose hash was ever taken. Every row
  /// uploaded before `0711` has `content_sha256` null and cannot be
  /// given one without downloading the object back, so an absence here
  /// is never PROOF that a file is new. Callers must treat it as
  /// "nothing to say" and carry on, never as "definitely not a
  /// duplicate".
  ///
  /// ## Scoped to the organization, twice over
  ///
  /// By RLS and by the index. Two companies uploading the same public
  /// form are not duplicates of each other, and one org must never be
  /// told a file "already exists" on the strength of a row it is not
  /// allowed to see.
  ///
  /// The NEWEST match, because the useful sentence is about the last
  /// time this happened rather than the first.
  Future<Attachment?> identicalFile(Uint8List bytes) async {
    final rows = await client
        .from('attachments')
        .select()
        .eq('org_id', orgId)
        .eq('content_sha256', contentHash(bytes))
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    return Attachment.fromJson(Map<String, dynamic>.from(rows.first));
  }

  /// Where one attachment's object lives, by row id.
  ///
  /// For the callers that have the row and not the path — the capture
  /// flow holds an `attachmentId` and nothing else, and being asked
  /// "what is this?" with no way to look at the page is a question
  /// somebody can only answer from memory. `0709`.
  ///
  /// Null where the row has gone, which is the ordinary end of a file
  /// somebody removed.
  Future<String?> attachmentPath(String id) async {
    final row = await client
        .from('attachments')
        .select('storage_path')
        .eq('id', id)
        .maybeSingle();
    return row?['storage_path']?.toString();
  }

  /// A short-lived link. The bucket is private, so there is no public URL
  /// to hand out and nothing to leak if one is copied into an email an
  /// hour later.
  Future<String> attachmentUrl(String storagePath,
          {Duration validFor = const Duration(minutes: 10)}) =>
      client.storage
          .from(bucket)
          .createSignedUrl(storagePath, validFor.inSeconds);

  /// The file itself, for the on-device reader — which takes bytes
  /// rather than a link, because it never goes near the network.
  Future<Uint8List> attachmentBytes(String storagePath) =>
      client.storage.from(bucket).download(storagePath);

  /// Removes one file by id.
  ///
  /// Used to be called automatically when somebody backed out of the
  /// capture flow. It is not any more: a person who photographs a
  /// document and then closes a sheet has not said "destroy this", and
  /// the reading was already paid for. `0708` refuses this outright
  /// once a posting or a reading was built from the file, so what
  /// reaches here is a capture nothing was made from.
  Future<void> deleteAttachmentById(String id) async {
    final row = await client
        .from('attachments')
        .select('storage_path')
        .eq('id', id)
        .maybeSingle();
    if (row == null) return;
    await client.storage.from(bucket).remove([row['storage_path'].toString()]);
    await client.from('attachments').delete().eq('id', id);
  }

  Future<void> deleteAttachment(Attachment attachment) async {
    await client.storage.from(bucket).remove([attachment.storagePath]);
    await client.from('attachments').delete().eq('id', attachment.id);
  }
}

/// The row an upload writes, built apart from the client that writes it.
///
/// `RepoAttachments` is an EXTENSION, and a Dart extension method binds
/// to the static type of its receiver — a fake `Repo` would never be
/// called and the real body would run against a live Supabase client.
/// So the payload is built here, where it can be asserted, rather than
/// inline where it cannot. See docs/widget-tests.md.
///
/// `kept_at` is the column that decides whether a file is findable at
/// all: `scan_inbox` unions on it, so an upload that omits it puts the
/// bytes in the bucket and the document nowhere a person can see.
Map<String, dynamic> attachmentRow({
  required String orgId,
  required String table,
  required String recordId,
  required String fileName,
  required String path,
  required Uint8List bytes,
  String? mimeType,
  bool keepForLater = false,
  DateTime? now,
}) =>
    {
      'org_id': orgId,
      'entity_table': table,
      'entity_id': recordId,
      'file_name': fileName,
      'storage_path': path,
      'mime_type': mimeType,
      'file_size': bytes.length,
      // `0711`. Written on the way in, because it cannot be recovered
      // afterwards without downloading the object back.
      'content_sha256': contentHash(bytes),
      // Absent rather than null unless asked for, so the column stays
      // empty on every attachment that arrived any other way. `0714`.
      if (keepForLater)
        'kept_at': (now ?? DateTime.now()).toUtc().toIso8601String(),
    };
