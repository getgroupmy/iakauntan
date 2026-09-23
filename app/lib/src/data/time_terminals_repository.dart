import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/providers.dart';
import 'repository.dart';

/// A clock on a wall.
///
/// `0612`. It has no login — `clock_in` reads `auth.uid()` and a device
/// bolted to a door frame has no session — so it proves itself with a
/// secret the database holds only the bcrypt hash of.
class TimeTerminal {
  const TimeTerminal({
    required this.id,
    required this.name,
    this.deviceRef,
    this.isActive = true,
    this.lastSeenAt,
    this.lastPunchAt,
    this.enrolments = 0,
  });

  final String id;
  final String name;

  /// What the device says it is, if it says anything. Recorded rather
  /// than trusted: the secret is what authenticates.
  final String? deviceRef;

  final bool isActive;

  /// When it last spoke to us at all, which is the figure that says a
  /// clock has stopped reporting before anybody notices a missing day.
  final DateTime? lastSeenAt;

  /// The latest punch it has reported, by the punch's own time. Not the
  /// same as [lastSeenAt] — a device that reconnects after a weekend
  /// reports Friday's punches today.
  final DateTime? lastPunchAt;

  final int enrolments;

  static DateTime? _at(Object? v) =>
      v == null ? null : DateTime.tryParse('$v')?.toLocal();

  factory TimeTerminal.fromJson(Map<String, dynamic> j) => TimeTerminal(
    id: '${j['id'] ?? ''}',
    name: '${j['name'] ?? ''}',
    deviceRef: (j['device_ref'] as String?)?.trim().isEmpty ?? true
        ? null
        : '${j['device_ref']}'.trim(),
    isActive: j['is_active'] != false,
    lastSeenAt: _at(j['last_seen_at']),
    lastPunchAt: _at(j['last_punch_at']),
    enrolments:
        ((j['terminal_enrolments'] as List?)?.firstOrNull
                as Map<String, dynamic>?)?['count'] as int? ??
        0,
  );
}

/// Which employee a terminal's user number is.
class TerminalEnrolment {
  const TerminalEnrolment({
    required this.id,
    required this.employeeId,
    required this.enrolmentNo,
    this.employeeName,
    this.employeeNo,
  });

  final String id;
  final String employeeId;

  /// The number the device registered the fingerprint against. Text,
  /// because devices pad: `0042` and `42` are the same person.
  final String enrolmentNo;

  final String? employeeName;
  final String? employeeNo;

  factory TerminalEnrolment.fromJson(Map<String, dynamic> j) {
    final emp = (j['employees'] as Map?)?.cast<String, dynamic>();
    return TerminalEnrolment(
      id: '${j['id'] ?? ''}',
      employeeId: '${j['employee_id'] ?? ''}',
      enrolmentNo: '${j['enrolment_no'] ?? ''}',
      employeeName: emp?['full_name'] as String?,
      employeeNo: emp?['employee_no'] as String?,
    );
  }
}

/// A punch that matched nobody.
///
/// Kept rather than dropped: somebody pressed a finger to a machine and
/// the person it belongs to will be asking why their day is short.
class UnmatchedPunch {
  const UnmatchedPunch({
    required this.id,
    required this.enrolmentNo,
    required this.punchedAt,
    this.terminalName,
    this.problem,
  });

  final String id;
  final String enrolmentNo;
  final DateTime punchedAt;
  final String? terminalName;
  final String? problem;

  factory UnmatchedPunch.fromJson(Map<String, dynamic> j) => UnmatchedPunch(
    id: '${j['id'] ?? ''}',
    enrolmentNo: '${j['enrolment_no'] ?? ''}',
    punchedAt:
        DateTime.tryParse('${j['punched_at']}')?.toLocal() ?? DateTime(1970),
    terminalName:
        ((j['time_terminals'] as Map?)?.cast<String, dynamic>())?['name']
            as String?,
    problem: j['problem'] as String?,
  );
}

class TimeTerminalsRepo {
  const TimeTerminalsRepo(this.client, this.orgId);

  final SupabaseClient client;
  final String orgId;

  Future<List<TimeTerminal>> all() async => Repo.rows(
    await client
        .from('time_terminals')
        // The constraint is named, and has to be: `0612` gave every one
        // of these tables a composite `(org_id, …)` key alongside its
        // single-column one, so there are two ways to join each pair
        // and PostgREST refuses the request rather than guessing.
        // `check_embeds.py` caught it.
        .select(
          'id, name, device_ref, is_active, last_seen_at, last_punch_at, '
          'terminal_enrolments!terminal_enrolments_terminal_id_fkey(count)',
        )
        .eq('org_id', orgId)
        // Said out loud, because supabase-js defaults ascending to true
        // and postgrest-dart defaults it to false.
        .order('name', ascending: true),
  ).map(TimeTerminal.fromJson).toList();

  Future<List<TerminalEnrolment>> enrolments(String terminalId) async =>
      Repo.rows(
        await client
            .from('terminal_enrolments')
            .select(
              'id, employee_id, enrolment_no, '
              'employees!terminal_enrolments_employee_id_fkey'
              '(full_name, employee_no)',
            )
            .eq('terminal_id', terminalId)
            .order('enrolment_no', ascending: true),
      ).map(TerminalEnrolment.fromJson).toList();

  /// Punches from the last month that matched nobody.
  ///
  /// A month rather than everything: a number nobody has enrolled by
  /// now is one somebody decided not to, and a list that only grows is
  /// one nobody reads.
  Future<List<UnmatchedPunch>> unmatched() async => Repo.rows(
    await client
        .from('terminal_punches')
        .select(
          'id, enrolment_no, punched_at, problem, '
          'time_terminals!terminal_punches_terminal_id_fkey(name)',
        )
        .eq('org_id', orgId)
        .isFilter('employee_id', null)
        .gte(
          'punched_at',
          DateTime.now()
              .subtract(const Duration(days: 31))
              .toUtc()
              .toIso8601String(),
        )
        .order('punched_at', ascending: false)
        .limit(200),
  ).map(UnmatchedPunch.fromJson).toList();

  /// Adds a terminal and returns its secret. Shown once and never
  /// again: the database stores a bcrypt hash, so there is nothing to
  /// read back.
  Future<({String id, String secret})> register({
    required String name,
    String? deviceRef,
  }) async {
    final data = await client.rpc(
      'register_time_terminal',
      params: {
        'p_org_id': orgId,
        'p_name': name,
        if (deviceRef != null && deviceRef.trim().isNotEmpty)
          'p_device_ref': deviceRef.trim(),
      },
    );
    final row = Repo.rows(data).first;
    return (id: '${row['terminal_id']}', secret: '${row['secret']}');
  }

  /// Replaces a terminal's secret. The old one stops working
  /// immediately, so a device with the old one goes quiet until it is
  /// reconfigured — which is the point, and is why this says so.
  Future<String> reissue(String terminalId) async {
    final data = await client.rpc(
      'reissue_terminal_secret',
      params: {'p_terminal_id': terminalId},
    );
    return '$data';
  }

  Future<void> setActive(String terminalId, bool active) => client
      .from('time_terminals')
      .update({'is_active': active})
      .eq('id', terminalId);

  Future<void> enrol({
    required String terminalId,
    required String employeeId,
    required String enrolmentNo,
  }) => client.from('terminal_enrolments').insert({
    'org_id': orgId,
    'terminal_id': terminalId,
    'employee_id': employeeId,
    'enrolment_no': enrolmentNo.trim(),
  });

  Future<void> unenrol(String id) =>
      client.from('terminal_enrolments').delete().eq('id', id);
}

final timeTerminalsRepoProvider = Provider<TimeTerminalsRepo?>((ref) {
  final org = ref.watch(orgIdProvider);
  if (org == null) return null;
  return TimeTerminalsRepo(ref.watch(supabaseProvider), org);
});

final timeTerminalsProvider = FutureProvider<List<TimeTerminal>>((ref) async {
  final repo = ref.watch(timeTerminalsRepoProvider);
  if (repo == null) return const [];
  return repo.all();
});

final terminalEnrolmentsProvider =
    FutureProvider.family<List<TerminalEnrolment>, String>((
      ref,
      terminalId,
    ) async {
      final repo = ref.watch(timeTerminalsRepoProvider);
      if (repo == null) return const [];
      return repo.enrolments(terminalId);
    });

final unmatchedPunchesProvider = FutureProvider<List<UnmatchedPunch>>((
  ref,
) async {
  final repo = ref.watch(timeTerminalsRepoProvider);
  if (repo == null) return const [];
  return repo.unmatched();
});
