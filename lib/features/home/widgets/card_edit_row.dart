import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/widgets/adaptive_glass_card.dart';
import 'package:recall_app/features/home/widgets/ai_example_button.dart';
import 'package:recall_app/features/home/widgets/tag_chips.dart';

class CardEditRow extends StatelessWidget {
  final int index;
  final TextEditingController termController;
  final TextEditingController definitionController;
  final TextEditingController? exampleSentenceController;
  final String imageUrl;
  final List<String> tags;
  final VoidCallback onDelete;
  final VoidCallback? onAutoImage;
  final VoidCallback? onEditImage;
  final VoidCallback? onClearImage;
  final void Function(String tag)? onAddTag;
  final void Function(String tag)? onRemoveTag;
  final bool isSelected;
  final ValueChanged<bool?>? onSelectionChanged;

  const CardEditRow({
    super.key,
    required this.index,
    required this.termController,
    required this.definitionController,
    this.exampleSentenceController,
    this.imageUrl = '',
    this.tags = const [],
    required this.onDelete,
    this.onAutoImage,
    this.onEditImage,
    this.onClearImage,
    this.onAddTag,
    this.onRemoveTag,
    this.isSelected = false,
    this.onSelectionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AdaptiveGlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      fillColor: Theme.of(context).cardColor,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: number + actions
          Row(
            children: [
              if (onSelectionChanged != null)
                Checkbox(
                  value: isSelected,
                  onChanged: onSelectionChanged,
                  visualDensity: VisualDensity.compact,
                ),
              Text(
                '#${index + 1}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const Spacer(),
              if (onAutoImage != null)
                IconButton(
                  onPressed: onAutoImage,
                  icon: Icon(
                    Icons.image_search,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  tooltip: l10n.autoFetchImage,
                  visualDensity: VisualDensity.compact,
                ),
              if (onEditImage != null)
                IconButton(
                  onPressed: onEditImage,
                  icon: Icon(
                    Icons.photo_library_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  tooltip: '編輯圖片',
                  visualDensity: VisualDensity.compact,
                ),
              if (imageUrl.isNotEmpty && onClearImage != null)
                IconButton(
                  onPressed: onClearImage,
                  icon: Icon(
                    Icons.hide_image_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  tooltip: '移除圖片',
                  visualDensity: VisualDensity.compact,
                ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                onPressed: onDelete,
                tooltip: l10n.deleteCard,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),

          // Image thumbnail
          if (imageUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 12),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      height: 100,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Row(
                      children: [
                        if (onEditImage != null)
                          _ImageActionButton(
                            icon: Icons.edit_rounded,
                            tooltip: '編輯圖片',
                            onTap: onEditImage!,
                          ),
                        if (imageUrl.isNotEmpty && onClearImage != null) ...[
                          const SizedBox(width: 6),
                          _ImageActionButton(
                            icon: Icons.delete_outline_rounded,
                            tooltip: '移除圖片',
                            onTap: onClearImage!,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // Term field
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: termController,
              decoration: InputDecoration(
                labelText: l10n.termLabel,
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
            ),
          ),
          const SizedBox(height: 14),

          // Definition field
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextField(
              controller: definitionController,
              decoration: InputDecoration(
                labelText: l10n.definitionInput,
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.next,
              maxLines: null,
            ),
          ),
          if (exampleSentenceController != null) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                controller: exampleSentenceController,
                decoration: InputDecoration(
                  labelText: l10n.exampleSentenceLabel,
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.next,
                maxLines: null,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: AiExampleButton(
                termController: termController,
                definitionController: definitionController,
                exampleSentenceController: exampleSentenceController!,
              ),
            ),
          ],

          // Part-of-speech quick tags
          if (onAddTag != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final pos in const [
                    'n.',
                    'v.',
                    'adj.',
                    'adv.',
                    'prep.',
                    'conj.',
                    'phr.',
                  ])
                    _PosChip(
                      label: pos,
                      isActive: tags.contains(pos),
                      onTap: () {
                        if (tags.contains(pos)) {
                          onRemoveTag?.call(pos);
                        } else {
                          onAddTag?.call(pos);
                        }
                      },
                    ),
                ],
              ),
            ),
          ],

          // Tags
          if (onAddTag != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TagChips(
                tags: tags
                    .where(
                      (t) => !const {
                        'n.',
                        'v.',
                        'adj.',
                        'adv.',
                        'prep.',
                        'conj.',
                        'phr.',
                      }.contains(t),
                    )
                    .toList(),
                editable: true,
                onAdd: onAddTag,
                onRemove: onRemoveTag,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ImageActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

class _PosChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _PosChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isActive
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: isActive
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
