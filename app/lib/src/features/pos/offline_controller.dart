import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../data/repository.dart';
import 'offline_store.dart';

/// The till's own answer to "is there signal?", and the queue behind it.
///
/// ## Why the flag is explicit as well as automatic
///
/// A connectivity check tells you the phone has a bar, not that the
/// database is reachable — and a van driving through a town gets a bar
/// every few minutes without ever completing a request. So the till
/// goes offline for two reasons: because a call failed the way a lost
/// connection fails, or because somebody said so. The second matters
/// most: a stallholder who knows the market has no signal should be
/// able to say so once at the start rather than discovering it one
/// failed sale at a time.
///
/// Coming back is deliberate too. Nothing flips the till online on its
/// own, because a flush that starts mid-sale on a flaky connection is
/// how a queue gets sent twice — safely, since the server is
/// idempotent, but slowly, and at the worst possible moment.
class PosOfflineState {
  const PosOfflineState({
    this.offline = false,
    this.queue = const [],
    this.sending = false,
    this.lastResult,
  });

  /// True when the till is building baskets locally.
  final bool offline;

  /// Sales taken with no signal, oldest first.
  final List<OfflineSale> queue;

  final bool sending;

  /// What the last flush came back with, per payload: `landed`,
  /// `already` or `rejected`. Kept so the screen can say "3 landed, 1
  /// rejected" rather than a bare "sent" — a batch where one payload
  /// was refused is not a batch that worked.
  final List<Map<String, dynamic>>? lastResult;

  int get waiting => queue.length;
  num get held => queue.fold<num>(0, (n, s) => n + s.total);

  PosOfflineState copyWith({
    bool? offline,
    List<OfflineSale>? queue,
    bool? sending,
    List<Map<String, dynamic>>? lastResult,
  }) => PosOfflineState(
    offline: offline ?? this.offline,
    queue: queue ?? this.queue,
    sending: sending ?? this.sending,
    lastResult: lastResult ?? this.lastResult,
  );
}

class PosOfflineController extends StateNotifier<PosOfflineState> {
  PosOfflineController(this._ref) : super(const PosOfflineState()) {
    _load();
  }

  final Ref _ref;
  PosOfflineStore? _store;

  Future<PosOfflineStore> _open() async =>
      _store ??= await PosOfflineStore.open();

  Future<void> _load() async {
    final store = await _open();
    if (!mounted) return;
    state = state.copyWith(queue: store.queue());
  }

  void setOffline(bool value) => state = state.copyWith(offline: value);

  /// Called when a server call failed the way a lost connection fails.
  /// Separate from [setOffline] so the reason is visible at the call
  /// site: this one is the till noticing, the other is somebody saying.
  void noticedNoSignal() {
    if (!state.offline) state = state.copyWith(offline: true);
  }

  Future<void> enqueue(OfflineSale sale) async {
    final store = await _open();
    final queue = await store.enqueue(sale);
    if (!mounted) return;
    state = state.copyWith(queue: queue);
  }

  Future<void> cacheMenu(String outletId, List<Map<String, dynamic>> rows) async {
    final store = await _open();
    await store.cacheMenu(outletId, rows);
  }

  Future<List<Map<String, dynamic>>> cachedMenu(String outletId) async {
    final store = await _open();
    return store.cachedMenu(outletId);
  }

  /// Sends everything waiting, one batch per register.
  ///
  /// Per register because `ingest_offline_sales` takes one, and a
  /// device that has been moved between tills mid-day would otherwise
  /// land the morning's sales in the afternoon's drawer.
  ///
  /// Every outcome comes off the queue, including `rejected`. Keeping a
  /// rejected payload would retry it for ever; it is not lost, because
  /// the server has already written it to `pos_offline_rejects` where
  /// `pos_offline_problems` shows it to somebody who can act on it.
  Future<List<Map<String, dynamic>>?> flush() async {
    final repo = _ref.read(repoProvider);
    if (repo == null || state.queue.isEmpty || state.sending) return null;
    state = state.copyWith(sending: true);

    final byRegister = <String, List<OfflineSale>>{};
    for (final s in state.queue) {
      byRegister.putIfAbsent(s.registerId, () => []).add(s);
    }

    final results = <Map<String, dynamic>>[];
    final done = <String>{};
    try {
      for (final entry in byRegister.entries) {
        final rows = await repo.ingestOfflineSales(
          entry.key,
          [for (final s in entry.value) s.toPayload()],
        );
        results.addAll(rows);
        // Trusting the server's list rather than assuming the batch
        // went as a whole: one payload can be rejected on its own, and
        // a device that forgot the lot on a partial failure would lose
        // the sales it should have kept sending.
        for (final r in rows) {
          final id = r['client_uuid'] as String?;
          if (id != null) done.add(id);
        }
      }
    } finally {
      if (mounted) {
        final store = await _open();
        final left = done.isEmpty ? state.queue : await store.forget(done);
        state = state.copyWith(
          sending: false,
          queue: left,
          lastResult: results,
        );
      }
    }
    return results;
  }
}

final posOfflineProvider =
    StateNotifierProvider<PosOfflineController, PosOfflineState>(
      PosOfflineController.new,
    );

/// What the server refused, for somebody who can do something about it.
final posOfflineProblemsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>(
      (ref) => requireRepo(ref).posOfflineProblems(),
    );
