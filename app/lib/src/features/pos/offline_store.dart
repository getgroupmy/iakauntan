/// Selling with no signal, from the device's side.
///
/// 0219 built the landing half of this — `ingest_offline_sales` takes a
/// batch, lands each payload in its own subtransaction, and is safe to
/// call twice because a sale already there is reported rather than
/// repeated. Nothing in the client ever produced such a batch, which
/// made "works offline" true of the database and false of the product.
///
/// ## What has to be local, and what must not be
///
/// A till with no signal cannot open a sale, price a line or take a
/// payment through the server, because all three are server functions.
/// So while it is offline the basket is built here, in memory, and
/// written to disk the moment it is paid for. Nothing else moves: no
/// invoice, no stock, no receipt, no number.
///
/// The one number the device is forced to work out for itself is the
/// change. A cashier has to hand coins over now, and `app.pos_cash_due`
/// lives in Postgres. [cashDue] below is a deliberate mirror of it —
/// not a second implementation of the rule but a local reading of it,
/// and the server's answer is the one that reaches the ledger when the
/// batch lands. They are written to agree; the test asserts the same
/// worked examples `supabase/tests/pos.sql` asserts.
///
/// ## Why the queue forgets a rejected sale
///
/// `ingest_offline_sales` returns one row per payload: `landed`,
/// `already`, or `rejected`. All three come off the local queue.
/// Keeping a rejected one would retry it on every flush for ever, and
/// it is not lost — `app.pos_record_reject` has already written it to
/// `pos_offline_rejects`, where `pos_offline_problems` shows it to
/// somebody who can do something about it. The device is the wrong
/// place for a payload nobody is looking at.
///
/// ## The client id is the whole idempotence story
///
/// Every queued sale carries a uuid generated here, before any attempt
/// to send. It is what lets a van that lost signal mid-request retry
/// without charging anybody twice: the second call finds the sale and
/// reports `already`. A payload without one is refused by
/// `app.land_offline_sale`, which is why nothing here can build one.
library;

import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// A version 4 uuid, generated on the device before anything is sent.
///
/// This is the whole idempotence story: it is what lets a van that lost
/// signal mid-request retry without charging anybody twice, because the
/// second call finds the sale and reports `already` instead of ringing
/// it up again.
///
/// `Random.secure()` rather than the default: two phones seeded from
/// the same clock tick would otherwise generate the same id, and the
/// unique index on `(org_id, client_uuid)` would make one shop's sale
/// silently swallow another's.
String newClientUuid([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 1
  String hex(int from, int to) => [
    for (var i = from; i < to; i++) b[i].toRadixString(16).padLeft(2, '0'),
  ].join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// One line on an offline bill.
class OfflineLine {
  const OfflineLine({
    required this.itemId,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    this.discount = 0,
    this.note,
    this.modifiers = const [],
  });

  final String itemId;

  /// Kept for the screen only. The server prices and describes the line
  /// from the item when the batch lands — a description carried across
  /// a day of no signal is a label, not a fact.
  final String description;
  final num quantity;
  final num unitPrice;
  final num discount;
  final String? note;

  /// Modifier ids, in the order they were chosen.
  final List<String> modifiers;

  num get total => quantity * unitPrice - discount;

  Map<String, dynamic> toJson() => {
    'item_id': itemId,
    'description': description,
    'quantity': quantity,
    'unit_price': unitPrice,
    if (discount != 0) 'discount': discount,
    if (note != null) 'note': note,
    if (modifiers.isNotEmpty)
      'modifiers': [for (final m in modifiers) {'modifier_id': m}],
  };

  static OfflineLine fromJson(Map<String, dynamic> j) => OfflineLine(
    itemId: '${j['item_id']}',
    description: '${j['description'] ?? ''}',
    quantity: (j['quantity'] as num?) ?? 1,
    unitPrice: (j['unit_price'] as num?) ?? 0,
    discount: (j['discount'] as num?) ?? 0,
    note: j['note'] as String?,
    modifiers: [
      for (final m in (j['modifiers'] as List? ?? const []))
        '${(m as Map)['modifier_id']}',
    ],
  );
}

/// What was handed over.
class OfflineTender {
  const OfflineTender({
    required this.typeId,
    required this.amount,
    this.reference,
  });

  final String typeId;
  final num amount;
  final String? reference;

  Map<String, dynamic> toJson() => {
    'type': typeId,
    'amount': amount,
    if (reference != null) 'reference': reference,
  };

  static OfflineTender fromJson(Map<String, dynamic> j) => OfflineTender(
    typeId: '${j['type']}',
    amount: (j['amount'] as num?) ?? 0,
    reference: j['reference'] as String?,
  );
}

/// A sale rung up with no signal, waiting to be landed.
class OfflineSale {
  const OfflineSale({
    required this.clientUuid,
    required this.registerId,
    required this.outletId,
    required this.soldAt,
    required this.lines,
    required this.tenders,
    this.contactId,
    this.tableId,
    this.covers,
    this.note,
  });

  final String clientUuid;
  final String registerId;
  final String outletId;

  /// When it actually happened, not when it landed. The server keeps
  /// this in `pos_sales.offline_sold_at`, so a day's takings can be
  /// read back in the order they were taken rather than the order the
  /// signal came back.
  final DateTime soldAt;

  final List<OfflineLine> lines;
  final List<OfflineTender> tenders;
  final String? contactId;
  final String? tableId;
  final int? covers;
  final String? note;

  num get total => lines.fold<num>(0, (n, l) => n + l.total);

  /// Exactly the shape `app.land_offline_sale` reads. `outletId` and
  /// the line descriptions are ours and are not sent: the register
  /// decides the outlet server-side, and the item decides its own
  /// description.
  Map<String, dynamic> toPayload() => {
    'client_uuid': clientUuid,
    'sold_at': soldAt.toUtc().toIso8601String(),
    if (contactId != null) 'contact_id': contactId,
    if (tableId != null) 'table_id': tableId,
    if (covers != null) 'covers': covers,
    if (note != null) 'note': note,
    'lines': [
      for (final l in lines)
        {
          'item_id': l.itemId,
          'quantity': l.quantity,
          'unit_price': l.unitPrice,
          if (l.discount != 0) 'discount': l.discount,
          if (l.note != null) 'note': l.note,
          if (l.modifiers.isNotEmpty)
            'modifiers': [for (final m in l.modifiers) {'modifier_id': m}],
        },
    ],
    'tenders': [for (final t in tenders) t.toJson()],
  };

  Map<String, dynamic> toJson() => {
    'client_uuid': clientUuid,
    'register_id': registerId,
    'outlet_id': outletId,
    'sold_at': soldAt.toUtc().toIso8601String(),
    if (contactId != null) 'contact_id': contactId,
    if (tableId != null) 'table_id': tableId,
    if (covers != null) 'covers': covers,
    if (note != null) 'note': note,
    'lines': [for (final l in lines) l.toJson()],
    'tenders': [for (final t in tenders) t.toJson()],
  };

  static OfflineSale fromJson(Map<String, dynamic> j) => OfflineSale(
    clientUuid: '${j['client_uuid']}',
    registerId: '${j['register_id']}',
    outletId: '${j['outlet_id']}',
    soldAt: DateTime.tryParse('${j['sold_at']}')?.toLocal() ?? DateTime.now(),
    contactId: j['contact_id'] as String?,
    tableId: j['table_id'] as String?,
    covers: (j['covers'] as num?)?.toInt(),
    note: j['note'] as String?,
    lines: [
      for (final l in (j['lines'] as List? ?? const []))
        OfflineLine.fromJson(Map<String, dynamic>.from(l as Map)),
    ],
    tenders: [
      for (final t in (j['tenders'] as List? ?? const []))
        OfflineTender.fromJson(Map<String, dynamic>.from(t as Map)),
    ],
  );
}

/// The coins to collect, worked out locally because somebody is waiting
/// with their hand out.
///
/// A mirror of `app.pos_cash_due` — five sen, by multiplying by 20,
/// rounding and dividing back, which is the same mechanism the database
/// uses. It exists because a till with no signal still has to give
/// change, and it is not the authority: when the batch lands,
/// `complete_pos_sale` computes this again and *that* answer is what
/// posts. They are written to agree, and
/// `app/test/offline_store_test.dart` asserts the same worked examples
/// `supabase/tests/pos.sql` does.
num cashDue(num total, {num nonCash = 0, bool round = true}) {
  final left = total - nonCash;
  if (left <= 0) return 0;
  if (!round) return (left * 100).round() / 100;
  return (left * 20).round() / 20;
}

/// What rounding did. Positive means the customer paid more than the
/// basket, negative less.
num roundingAdjustment(num total, {num nonCash = 0, bool round = true}) {
  final left = total - nonCash;
  final due = cashDue(total, nonCash: nonCash, round: round);
  return ((due - (left <= 0 ? 0 : left)) * 100).round() / 100;
}

/// Where the queue and the cached menu live between launches.
///
/// `shared_preferences` rather than a file: it is `localStorage` on the
/// web, which is where a market stall's phone browser actually runs
/// this, and a file written with `path_provider` would not exist there
/// at all.
class PosOfflineStore {
  PosOfflineStore(this._prefs);

  final SharedPreferences _prefs;

  static const queueKey = 'pos.offline.queue';
  static String menuKey(String outletId) => 'pos.offline.menu.$outletId';

  static Future<PosOfflineStore> open() async =>
      PosOfflineStore(await SharedPreferences.getInstance());

  List<OfflineSale> queue() {
    final raw = _prefs.getString(queueKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          OfflineSale.fromJson(Map<String, dynamic>.from(e as Map)),
      ];
    } on FormatException {
      // A queue that cannot be read is worse than an empty one only if
      // it also stops the till working. It does not: the payloads are
      // gone either way, and refusing to sell because of them would
      // turn a lost record into a lost day.
      return const [];
    }
  }

  Future<void> _write(List<OfflineSale> sales) => _prefs.setString(
    queueKey,
    jsonEncode([for (final s in sales) s.toJson()]),
  );

  /// Appends, keeping the order they were taken in. Idempotent on
  /// `clientUuid`, so a save retried after a crash does not double the
  /// day's takings before they have even been sent.
  Future<List<OfflineSale>> enqueue(OfflineSale sale) async {
    final now = [...queue()];
    if (now.any((s) => s.clientUuid == sale.clientUuid)) return now;
    now.add(sale);
    await _write(now);
    return now;
  }

  Future<List<OfflineSale>> forget(Set<String> clientUuids) async {
    final left = [
      for (final s in queue())
        if (!clientUuids.contains(s.clientUuid)) s,
    ];
    await _write(left);
    return left;
  }

  /// The menu, so a till that loses signal can still show what it
  /// sells. Written every time the real one is read, which is the only
  /// moment the device is certain it is current.
  Future<void> cacheMenu(
    String outletId,
    List<Map<String, dynamic>> rows,
  ) => _prefs.setString(menuKey(outletId), jsonEncode(rows));

  List<Map<String, dynamic>> cachedMenu(String outletId) {
    final raw = _prefs.getString(menuKey(outletId));
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          Map<String, dynamic>.from(e as Map),
      ];
    } on FormatException {
      return const [];
    }
  }
}
