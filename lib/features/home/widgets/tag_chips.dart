import 'package:flutter/material.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';

/// Displays tags as chips with optional add/remove capability.
class TagChips extends StatelessWidget {
  final List<String> tags;
  final bool editable;
  final void Function(String tag)? onAdd;
  final void Function(String tag)? onRemove;

  const TagChips({
    super.key,
    required this.tags,
    this.editable = false,
    this.onAdd,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        ...tags.map((tag) => Chip(
              label: Text(tag, style: const TextStyle(fontSize: 12)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              deleteIcon: editable
                  ? const Icon(Icons.close, size: 14)
                  : null,
              onDeleted: editable && onRemove != null
                  ? () => onRemove!(tag)
                  : null,
            )),
        if (editable && onAdd != null)
          ActionChip(
            label: const Icon(Icons.add, size: 16),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            onPressed: () => _showAddTagDialog(context),
          ),
      ],
    );
  }

  void _showAddTagDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.addTag),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: l10n.tagNameHint,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            final tag = value.trim();
            if (tag.isNotEmpty) {
              onAdd!(tag);
              Navigator.pop(dialogContext);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final tag = controller.text.trim();
              if (tag.isNotEmpty) {
                onAdd!(tag);
                Navigator.pop(dialogContext);
              }
            },
            child: Text(l10n.add),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}
