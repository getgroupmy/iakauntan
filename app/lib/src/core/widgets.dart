import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'providers.dart';
import 'theme.dart';

/// Renders an AsyncValue with consistent loading and error treatment, so
/// no screen has to reinvent it.
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.loading,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  /// How long a screen waits for the company to arrive before giving up
  /// on it.
  ///
  /// Long enough to cover a cold load on a bad connection, short enough
  /// that somebody staring at a spinner is not left there. Only
  /// [OrgNotReady] gets this: a refusal or a broken connection is
  /// something the person can act on, and holding it back for ten
  /// seconds would be hiding the answer.
  static const settlingTime = Duration(seconds: 10);

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  /// Whether the settling time has run out. False while waiting, and
  /// false again once something other than "not ready" turns up.
  bool _settled = false;

  /// Counted in timers rather than against the clock. `DateTime.now()`
  /// would read the wall clock, which a widget test does not advance and
  /// a laptop waking from sleep advances by rather a lot.
  Timer? _deadline;
  Timer? _nudge;

  bool get _waiting => _deadline != null && !_settled;

  /// Starts the wait, and keeps nudging while it lasts.
  ///
  /// The providers do recover on their own — a screen reading through
  /// `requireRepo` watches the repository and re-runs when one appears —
  /// so the nudge is insurance rather than the mechanism. The deadline
  /// is what turns a wait into an answer.
  void _beginWaiting() {
    if (_deadline != null) return;
    _deadline = Timer(AsyncView.settlingTime, () {
      _nudge?.cancel();
      _nudge = null;
      if (mounted) setState(() => _settled = true);
    });
    _nudge = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) widget.onRetry?.call();
    });
  }

  void _stopWaiting() {
    _deadline?.cancel();
    _deadline = null;
    _nudge?.cancel();
    _nudge = null;
    _settled = false;
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _nudge?.cancel();
    super.dispose();
  }

  Widget get _loading =>
      widget.loading ?? const Center(child: CircularProgressIndicator());

  @override
  Widget build(BuildContext context) {
    return widget.value.when(
      data: (data) {
        _stopWaiting();
        return widget.builder(data);
      },
      loading: () {
        _stopWaiting();
        return _loading;
      },
      error: (err, _) {
        if (err is! OrgNotReady) {
          _stopWaiting();
          return ErrorState(message: '$err', onRetry: widget.onRetry);
        }

        // Still settling. Shown as the load it is.
        _beginWaiting();
        if (_waiting) return _loading;

        return ErrorState(
          message: '$err Check your connection and try again.',
          onRetry: () {
            _stopWaiting();
            widget.onRetry?.call();
          },
        );
      },
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: context.colors.danger),
            const SizedBox(height: 12),
            Text(
              'Something went wrong',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: scheme.primary),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// Colour-coded status pill used for document, payment and e-Invoice states.
class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.compact = false});

  final String status;
  final bool compact;

  /// Resolved per build rather than held in a const map, so the same status
  /// reads correctly on a light and a dark ground.
  static Color colorFor(BuildContext context, String status) {
    final c = context.colors;
    const neutral = Color(0xFF64748B);
    const dim = Color(0xFF94A3B8);
    return switch (status) {
      'draft' => neutral,
      'pending' || 'queued' || 'partial' => c.warning,
      'submitted' || 'approved' => c.info,
      'posted' || 'valid' || 'completed' || 'fulfilled' => c.success,
      'overdue' || 'invalid' || 'failed' || 'rejected' => c.danger,
      'void' || 'cancelled' || 'not_applicable' => dim,
      _ => neutral,
    };
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFor(context, status);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 2 : 4,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        Fmt.label(status),
        style: TextStyle(
          color: color,
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A single series drawn small enough to sit inside a metric tile: the
/// shape of the last twelve months, with the latest point called out.
/// No axes — this answers "which way is it going", not "by how much".
class Sparkline extends StatelessWidget {
  const Sparkline(this.values, {super.key, required this.color, this.height = 30});

  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return SizedBox(height: height);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _SparklinePainter(values, color)),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color);

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final lo = values.reduce((a, b) => a < b ? a : b);
    final hi = values.reduce((a, b) => a > b ? a : b);
    // A flat series would divide by zero; draw it down the middle instead.
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final dx = size.width / (values.length - 1);

    Offset at(int i) => Offset(
          i * dx,
          size.height - ((values[i] - lo) / span) * (size.height - 3) - 1.5,
        );

    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < values.length; i++) {
      final p = at(i), q = at(i - 1);
      final cx = (q.dx + p.dx) / 2;
      line.cubicTo(cx, q.dy, cx, p.dy, p.dx, p.dy);
    }

    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.20), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
    canvas.drawCircle(at(values.length - 1), 2.4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color || !listEquals(old.values, values);
}

/// Dashboard metric tile.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.icon,
    this.accent,
    this.onTap,
    this.trend,
    this.delta,
    this.deltaIsGood = true,
  });

  final String label;
  final String value;
  final String? caption;
  final IconData? icon;
  final Color? accent;
  final VoidCallback? onTap;

  /// Recent history for the sparkline, oldest first.
  final List<double>? trend;

  /// Change against the previous period, as a fraction (0.12 = up 12%).
  final double? delta;

  /// Whether a rise is a good thing. Revenue up is green; expenses up is not.
  final bool deltaIsGood;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = accent ?? scheme.primary;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, size: 16, color: color),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                      ),
                ),
              ),
              if (caption != null || delta != null) ...[
                const SizedBox(height: Space.xs),
                Row(
                  children: [
                    if (delta != null) ...[
                      _DeltaBadge(delta: delta!, isGood: deltaIsGood),
                      const SizedBox(width: Space.sm),
                    ],
                    if (caption != null)
                      Expanded(
                        child: Text(
                          caption!,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ],
              if (trend != null && trend!.length > 1) ...[
                const SizedBox(height: Space.md),
                Sparkline(trend!, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Direction of travel against the previous period. Colour says whether
/// that direction is welcome, which is not the same as which way it points.
class _DeltaBadge extends StatelessWidget {
  const _DeltaBadge({required this.delta, required this.isGood});

  final double delta;
  final bool isGood;

  @override
  Widget build(BuildContext context) {
    final up = delta >= 0;
    final welcome = up == isGood;
    final color =
        welcome ? context.colors.success : context.colors.warning;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(up ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12, color: color),
        const SizedBox(width: 2),
        Text(
          '${(delta.abs() * 100).toStringAsFixed(0)}%',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Right-aligned monetary value with optional emphasis for negatives.
class Money extends StatelessWidget {
  const Money(
    this.amount, {
    super.key,
    this.currency = 'MYR',
    this.bold = false,
    this.colorNegative = false,
    this.style,
  });

  final num? amount;
  final String currency;
  final bool bold;
  final bool colorNegative;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final value = amount ?? 0;
    return Text(
      Fmt.money(value, currency: currency),
      textAlign: TextAlign.right,
      style: (style ?? Theme.of(context).textTheme.bodyMedium)?.copyWith(
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: colorNegative && value < 0 ? context.colors.danger : null,
      ),
    );
  }
}

/// A row of filters that scrolls sideways rather than being cut off.
///
/// SegmentedButton sizes itself to its segments: it neither shrinks nor
/// wraps, so on a phone the options past the edge are simply gone. The
/// e-Invoice screen lost "Needs fixing" that way, with "Submitted"
/// wrapping mid-word beside it.
///
/// Scrolling rather than shortening the labels, because those words are
/// what the rest of the app calls those states — an abbreviation that
/// only exists on small screens is a second vocabulary to learn. The
/// left edge is where the eye starts, so the first option stays put and
/// the overflow is reached by dragging.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      // Dragging a segmented control by touch is how a phone reaches the
      // far end of it, and a trackpad or wheel has to work too.
      physics: const ClampingScrollPhysics(),
      child: child,
    );
  }
}

/// Page scaffold that keeps content readable on ultra-wide displays.
class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.child,
    this.maxWidth = 1280,
    this.padding = const EdgeInsets.all(Space.lg),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Shows a snackbar for a Future, surfacing errors rather than swallowing
/// them. Returns true when the action completed.
Future<bool> runWithFeedback(
  BuildContext context, {
  required Future<void> Function() action,
  required String successMessage,
  String? pendingMessage,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (pendingMessage != null) {
    messenger.showSnackBar(SnackBar(
      content: Row(children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
        const SizedBox(width: 12),
        Text(pendingMessage),
      ]),
      duration: const Duration(seconds: 30),
    ));
  }

  // Read the colours before awaiting: the widget that supplied this
  // context may be gone by the time the action returns, and the
  // messenger captured above outlives it.
  final success = context.colors.success;
  final danger = context.colors.danger;

  try {
    await action();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(successMessage),
        backgroundColor: success,
      ));
    return true;
  } catch (err) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('$err'),
        backgroundColor: danger,
        duration: const Duration(seconds: 6),
      ));
    return false;
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: context.colors.danger)
              : null,
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
