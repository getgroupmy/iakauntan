import 'dart:typed_data';

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
  });

  final String id;
  final String fileName;
  final String storagePath;
  final DateTime createdAt;
  final String? mimeType;
  final int? fileSize;

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
      );
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

  Future<List<Attachment>> attachments(String table, String recordId) async =>
      Repo.rows(await client
              .from('attachments')
              .select()
              .eq('entity_table', table)
              .eq('entity_id', recordId)
              .order('created_at', ascending: false))
          .map(Attachment.fromJson)
          .toList();

  /// Returns the id of the row created, which is what a scan is asked
  /// for.
  Future<String> uploadAttachment({
    required String table,
    required String recordId,
    required String fileName,
    required Uint8List bytes,
    String? mimeType,
  }) async {
    // A filename goes into an object key and into a URL. Anything that
    // is not plainly a name is replaced rather than escaped, and the
    // uuid in front keeps two files of the same name apart.
    final safe = fileName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final key = '${DateTime.now().millisecondsSinceEpoch}-'
        '${safe.isEmpty ? 'file' : safe}';
    final path = '$orgId/$table/$recordId/$key';

    await client.storage.from(bucket).uploadBinary(path, bytes);
    final row = await client
        .from('attachments')
        .insert({
          'org_id': orgId,
          'entity_table': table,
          'entity_id': recordId,
          'file_name': fileName,
          'storage_path': path,
          'mime_type': mimeType,
          'file_size': bytes.length,
        })
        .select('id')
        .single();
    return row['id'].toString();
  }

  /// A short-lived link. The bucket is private, so there is no public URL
  /// to hand out and nothing to leak if one is copied into an email an
  /// hour later.
  Future<String> attachmentUrl(String storagePath,
          {Duration validFor = const Duration(minutes: 10)}) =>
      client.storage
          .from(bucket)
          .createSignedUrl(storagePath, validFor.inSeconds);

  /// For a file whose row was never displayed — a receipt captured for a
  /// record that was then abandoned.
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
