import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers.dart';
import '../../core/quick_add_dialog.dart';
import '../../core/searchable_picker.dart';
import '../../core/widgets.dart';
import '../../data/models.dart';
import '../../data/repository.dart';
import '../custom_fields/custom_fields_section.dart';

/// Raising one.
///
/// Deliberately short. Everything the desk needs to route and to promise
/// a deadline follows from the category, so asking for a category and a
/// sentence is enough — priority and type are offered as overrides
/// rather than as questions, because the person raising a ticket is
/// usually the one least able to answer them.
class TicketEditor extends ConsumerStatefulWidget {
  const TicketEditor({super.key});

  @override
  ConsumerState<TicketEditor> createState() => _TicketEditorState();
}

class _TicketEditorState extends ConsumerState<TicketEditor> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _description = TextEditingController();
  String? _category;
  String? _priority;
  bool _busy = false;
  Map<String, dynamic> _customFields = const {};

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    setState(() => _busy = true);
    try {
      final id = await ref.read(repoProvider)!.createTicket(
        subject: _subject.text.trim(),
        description: _description.text.trim(),
        categoryCode: _category,
        priority: _priority,
        customFields: _customFields,
      );
      ref.invalidate(ticketsProvider);
      router.go('/tickets/$id');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is PostgrestException ? e.message : '$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(ticketCategoriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('New ticket')),
      body: PageBody(
        child: Form(
          key: _form,
          child: ListView(
            children: [
              TextFormField(
                controller: _subject,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'What is wrong?',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'A ticket needs a subject'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Anything else that would help',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              categories.maybeWhen(
                data: (list) => SearchablePicker<String>(
                  options: [
                    for (final c in list)
                      PickerOption<String>(
                        value: c['code'] as String,
                        label: (c['name'] ?? '') as String,
                        keywords: ['${c['code']}'],
                      ),
                  ],
                  value: _category,
                  label: 'Category',
                  helperText:
                      'Decides the team, the priority and the deadline',
                  createLabel: 'Add category',
                  onCreate: (typed) => quickAdd(
                    context,
                    title: 'New ticket category',
                    // What the helper text above promises is exactly
                    // what a category made here does NOT yet have, so
                    // it is said rather than discovered.
                    blurb: 'Not on the list yet. Its team, priority and '
                        'deadline are set on the Categories screen; '
                        'until then it uses the defaults.',
                    nameHint: 'Hardware fault',
                    codeLabel: 'Code',
                    seed: typed,
                    save: ({required name, code}) async {
                      await ref.read(repoProvider)!.createQuickRow(
                            QuickAddList.ticketCategory,
                            name: name,
                            code: code,
                          );
                      ref.invalidate(ticketCategoriesProvider);
                      // This picker is keyed on the CODE, not the id.
                      return code!;
                    },
                  ),
                  onChanged: (v) => setState(() => _category = v),
                ),
                orElse: () => const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _priority,
                decoration: const InputDecoration(
                  labelText: 'Priority',
                  border: OutlineInputBorder(),
                  helperText: 'Leave blank to take the category\'s own',
                ),
                items: const [
                  DropdownMenuItem(value: 'p1', child: Text('P1 — critical')),
                  DropdownMenuItem(value: 'p2', child: Text('P2 — high')),
                  DropdownMenuItem(value: 'p3', child: Text('P3 — normal')),
                  DropdownMenuItem(value: 'p4', child: Text('P4 — low')),
                ],
                onChanged: (v) => setState(() => _priority = v),
              ),
              // What this desk asks of every ticket that the category
              // and priority above do not cover — an asset tag, a site,
              // a contract number. Draws nothing until one is defined,
              // which is what keeps the short form short.
              CustomFieldsSection(
                entity: 'ticket',
                values: _customFields,
                enabled: !_busy,
                onChanged: (v) => setState(() => _customFields = v),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('Raise ticket'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
