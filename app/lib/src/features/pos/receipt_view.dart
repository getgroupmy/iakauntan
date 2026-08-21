import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The paper, on a screen.
///
/// Monospaced and never wrapped: the receipt was already wrapped by the
/// server to the width of the roll this outlet buys, and letting Flutter
/// wrap it again would show a layout no printer will produce. A line
/// too wide for a phone scrolls sideways instead, which is honest about
/// what will come out of the printer.
class ReceiptPaper extends StatelessWidget {
  const ReceiptPaper(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        text.isEmpty ? '—' : text,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: ['Courier'],
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}

/// Shows the paper for one bill, with the two things somebody standing
/// at a counter actually does with it: read it back, or copy it into
/// whatever is driving the printer.
Future<void> showReceiptSheet(
  BuildContext context, {
  required String text,
  String title = 'Receipt',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (ctx) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 12),
          Flexible(
            child: SingleChildScrollView(child: ReceiptPaper(text)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);
