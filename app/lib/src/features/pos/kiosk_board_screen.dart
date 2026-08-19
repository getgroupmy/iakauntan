import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/widgets.dart';
// No `repository.dart` here, unlike its sibling screens. This one only
// reads a provider and calls nothing on Repo, so the extension it would
// bring into scope is unused — and `--fatal-infos` is right to say so.
import 'till_screen.dart' show PosRegisterPicker;

/// The collection board.
///
/// The only screen in this application whose reader is a customer, and
/// it shows the smallest amount of information of anything here: a
/// number, and which of two columns it is in. Somebody standing with a
/// tray is looking for their own number and nothing else, so there is
/// no chrome, no navigation and nothing to tap.
///
/// Order numbers rather than names, because a counter that calls out a
/// name is a counter that has collected one. `kiosk_order_board` shows
/// four hours and only orders the kitchen has not finished, so the
/// board clears itself without anybody tending it.
class KioskBoardScreen extends ConsumerStatefulWidget {
  const KioskBoardScreen({super.key});

  @override
  ConsumerState<KioskBoardScreen> createState() => _KioskBoardScreenState();
}

class _KioskBoardScreenState extends ConsumerState<KioskBoardScreen> {
  String? _registerId;
  String? _outletId;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Nobody is going to refresh this. It hangs on a wall.
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      final outlet = _outletId;
      if (outlet != null && mounted) {
        ref.invalidate(kioskOrderBoardProvider(outlet));
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _pickRegister(Map<String, dynamic> reg) {
    setState(() {
      _registerId = reg['id'] as String?;
      _outletId = (reg['pos_outlets'] as Map?)?['id'] as String?;
    });
  }

  @override
  Widget build(BuildContext context) {
    final registers = ref.watch(posRegistersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Now serving'),
        actions: [
          registers.maybeWhen(
            data: (rows) => PosRegisterPicker(
              registers: rows,
              selectedId: _registerId,
              onPicked: _pickRegister,
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: AsyncView<List<Map<String, dynamic>>>(
        value: registers,
        builder: (rows) {
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.tv_outlined,
              title: 'No tills yet',
              message:
                  'Order numbers are given out by a kiosk, and a kiosk is '
                  'a register with self-service switched on.',
            );
          }
          if (_registerId == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _pickRegister(rows.first);
            });
          }
          final outlet = _outletId;
          if (outlet == null) return const SizedBox.shrink();
          return _Board(outletId: outlet);
        },
      ),
    );
  }
}

class _Board extends ConsumerWidget {
  const _Board({required this.outletId});

  final String outletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(kioskOrderBoardProvider(outletId));
    return AsyncView<List<Map<String, dynamic>>>(
      value: board,
      builder: (orders) {
        final making = [
          for (final o in orders)
            if (o['state'] == 'making') o,
        ];
        final ready = [
          for (final o in orders)
            if (o['state'] == 'ready') o,
        ];
        if (orders.isEmpty) {
          return const EmptyState(
            icon: Icons.done_all,
            title: 'Nothing waiting',
            message: 'Every order has been collected.',
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Half(
                title: 'Preparing',
                orders: making,
                // Deliberately quiet. The half somebody is waiting on
                // should not compete with the half they can act on.
                emphasis: false,
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _Half(title: 'Ready', orders: ready, emphasis: true),
            ),
          ],
        );
      },
    );
  }
}

class _Half extends StatelessWidget {
  const _Half({
    required this.title,
    required this.orders,
    required this.emphasis,
  });

  final String title;
  final List<Map<String, dynamic>> orders;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        Expanded(
          child: orders.isEmpty
              ? const SizedBox.shrink()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      for (final o in orders)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: emphasis
                                ? scheme.primaryContainer
                                : scheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${o['order_no']}',
                            // The largest type in the application, on
                            // purpose: this is read from across a room
                            // by somebody carrying a tray.
                            style: Theme.of(context).textTheme.displaySmall
                                ?.copyWith(
                                  color: emphasis
                                      ? scheme.onPrimaryContainer
                                      : scheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
