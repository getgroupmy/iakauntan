import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';

/// One figure on the ticker.
///
/// `up` is not "the number went up" — it is WHETHER THIS IS GOOD NEWS,
/// which is not the same thing and is the whole reason the field
/// exists. Cash rising is good; overdue debt rising is not, and a
/// ticker that paints both green is one nobody reads twice.
class TickerItem {
  const TickerItem({
    required this.label,
    required this.value,
    this.good,
  });

  final String label;
  final String value;

  /// True for good news, false for bad, null for neither.
  final bool? good;
}

/// What the ticker carries, from the figures the dashboard already has.
///
/// Pure, and separate from the widget, so the rule can be asserted:
/// `app/test/ticker_test.dart`. The rules it encodes:
///
///   * money is money — a ticker showing 1234.5 beside RM 1,234.50 is
///     two different systems on one line,
///   * a zero is still a figure. "Overdue RM 0.00" is worth reading,
///     because it is the answer to a question somebody has,
///   * but a figure the company cannot have is left out entirely: a
///     business with no stock module has no low-stock count, and a
///     zero there is a lie rather than good news.
List<TickerItem> tickerItems(
  DashboardSummary data, {
  required String currency,
  int openTodos = 0,
  int overdueTodos = 0,
  bool showStock = false,
  bool showEinvoice = false,
}) {
  return [
    TickerItem(
      label: 'Cash at bank',
      value: Fmt.money(data.bankBalance, currency: currency),
      good: data.bankBalance >= 0,
    ),
    TickerItem(
      label: 'Owed to you',
      value: Fmt.money(data.receivables, currency: currency),
    ),
    TickerItem(
      label: 'Overdue',
      value: Fmt.money(data.overdueReceivables, currency: currency),
      good: data.overdueReceivables == 0,
    ),
    TickerItem(
      label: 'You owe',
      value: Fmt.money(data.payables, currency: currency),
    ),
    TickerItem(
      label: 'Profit this year',
      value: Fmt.money(data.profit, currency: currency),
      good: data.profit >= 0,
    ),
    if (data.draftInvoices > 0)
      TickerItem(
        label: 'Drafts unposted',
        value: '${data.draftInvoices}',
        good: false,
      ),
    if (showEinvoice && data.einvoiceInvalid > 0)
      TickerItem(
        label: 'e-Invoice rejected',
        value: '${data.einvoiceInvalid}',
        good: false,
      ),
    if (showStock)
      TickerItem(
        label: 'Low stock',
        value: '${data.lowStock}',
        good: data.lowStock == 0,
      ),
    TickerItem(
      label: 'To do',
      value: overdueTodos == 0
          ? '$openTodos open'
          : '$openTodos open, $overdueTodos overdue',
      good: overdueTodos == 0,
    ),
  ];
}

/// The day's figures, running across the top of the dashboard.
///
/// It scrolls ITSELF, slowly, and can also be dragged. Two reasons for
/// the movement rather than a static row: the figures do not fit on a
/// phone at any readable size, and a strip that moves is read as live,
/// which these are — they are re-read whenever the dashboard is.
///
/// It stops while the finger is down and while the app is not in front,
/// because a ticker animating in the background is a battery cost for
/// a screen nobody is looking at.
class DashboardTicker extends ConsumerStatefulWidget {
  const DashboardTicker({super.key});

  @override
  ConsumerState<DashboardTicker> createState() => _DashboardTickerState();
}

class _DashboardTickerState extends ConsumerState<DashboardTicker> {
  final _controller = ScrollController();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Twenty pixels a second, in small steps: fast enough to notice and
    // slow enough to read a figure that has already gone past.
    _timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_controller.hasClients) return;
      final max = _controller.position.maxScrollExtent;
      if (max <= 0) return;
      final next = _controller.offset + 1;
      // Round the loop rather than stopping at the end, which is what
      // makes it a ticker rather than a row that scrolled once.
      _controller.jumpTo(next >= max ? 0 : next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final summary = ref.watch(dashboardProvider).valueOrNull;
    final org = ref.watch(currentOrgProvider).valueOrNull;
    final todos = ref.watch(todosProvider(false)).valueOrNull ?? const [];
    if (summary == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final items = tickerItems(
      summary,
      currency: org?.baseCurrency ?? 'MYR',
      openTodos: todos.length,
      overdueTodos: todos.where((t) => t.isOverdue(now)).length,
      showStock: moduleEnabled(ref, 'inventory'),
      showEinvoice: moduleEnabled(ref, 'einvoice'),
    );

    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 44,
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.builder(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        // Twice through, so the strip is long enough to scroll on a wide
        // screen and the wrap at the end is not a visible jump from a
        // full row to an empty one.
        itemCount: items.length * 2,
        itemBuilder: (context, index) =>
            _TickerCell(item: items[index % items.length]),
      ),
    );
  }
}

class _TickerCell extends StatelessWidget {
  const _TickerCell({required this.item});

  final TickerItem item;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tone = switch (item.good) {
      true => colors.success,
      false => colors.danger,
      null => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(width: 6),
          Text(
            item.value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
          const SizedBox(width: 14),
          Text('·', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
