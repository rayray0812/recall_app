import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:recall_app/core/icons/material_icon_mapper.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/core/widgets/adaptive_glass_card.dart';
import 'package:recall_app/core/widgets/app_back_button.dart';
import 'package:recall_app/models/folder.dart';
import 'package:recall_app/providers/folder_provider.dart';

class FolderManagementScreen extends ConsumerWidget {
  const FolderManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final folders = ref.watch(foldersProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(l10n.folders),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showFolderDialog(context, ref),
        backgroundColor: AppTheme.indigo,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add_rounded),
      ),
      body: folders.isEmpty
          ? Center(
              child: Text(
                l10n.noFoldersYet,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: folders.length,
              itemBuilder: (context, index) {
                final folder = folders[index];
                final color = Color(int.parse(folder.colorHex, radix: 16));
                return AdaptiveGlassCard(
                  margin: const EdgeInsets.only(bottom: 10),
                  fillColor: Theme.of(context).cardColor,
                  borderRadius: 14,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withValues(alpha: 0.15),
                      child: Icon(
                        MaterialIconMapper.fromCodePoint(folder.iconCodePoint),
                        color: color,
                      ),
                    ),
                    title: Text(folder.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () =>
                              _showFolderDialog(context, ref, folder: folder),
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline,
                              size: 20, color: AppTheme.red),
                          onPressed: () => _confirmDelete(context, ref, folder),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref, Folder folder) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.deleteFolder),
        content: Text(l10n.deleteFolderConfirm(folder.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              ref.read(foldersProvider.notifier).remove(folder.id);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  void _showFolderDialog(BuildContext context, WidgetRef ref,
      {Folder? folder}) {
    final l10n = AppLocalizations.of(context);
    final nameController = TextEditingController(text: folder?.name ?? '');
    final isEditing = folder != null;

    final colorOptions = [
      'FF6366F1', // Indigo
      'FF8B5CF6', // Purple
      'FF3B82F6', // Blue
      'FF06B6D4', // Cyan
      'FF10B981', // Green
      'FFF59E0B', // Amber
      'FFEF4444', // Red
      'FFEC4899', // Pink
    ];

    final iconOptions = [
      0xe6c4, // folder
      0xe335, // book
      0xe153, // science
      0xeb7b, // calculate
      0xe3c9, // language
      0xee94, // music note
      0xf06c, // sports
      0xea22, // history edu
    ];

    var selectedColor = folder?.colorHex ?? colorOptions[0];
    var selectedIcon = folder?.iconCodePoint ?? iconOptions[0];

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(isEditing ? l10n.editFolder : l10n.newFolder),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: l10n.folderName),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                Text(l10n.color,
                    style: Theme.of(ctx).textTheme.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: colorOptions.map((hex) {
                    final color = Color(int.parse(hex, radix: 16));
                    final isSelected = hex == selectedColor;
                    return GestureDetector(
                      onTap: () =>
                          setDialogState(() => selectedColor = hex),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(
                                  color: Theme.of(ctx).colorScheme.onSurface,
                                  width: 3)
                              : null,
                        ),
                        child: isSelected
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 18)
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                Text(l10n.icon,
                    style: Theme.of(ctx).textTheme.labelMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: iconOptions.map((codePoint) {
                    final isSelected = codePoint == selectedIcon;
                    final chipColor =
                        Color(int.parse(selectedColor, radix: 16));
                    return GestureDetector(
                      onTap: () =>
                          setDialogState(() => selectedIcon = codePoint),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? chipColor.withValues(alpha: 0.2)
                              : Theme.of(ctx)
                                  .colorScheme
                                  .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                          border: isSelected
                              ? Border.all(color: chipColor, width: 2)
                              : null,
                        ),
                        child: Icon(
                          MaterialIconMapper.fromCodePoint(codePoint),
                          size: 22,
                          color: isSelected
                              ? chipColor
                              : Theme.of(ctx).colorScheme.onSurface,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final newFolder = Folder(
                  id: folder?.id ?? const Uuid().v4(),
                  name: name,
                  colorHex: selectedColor,
                  iconCodePoint: selectedIcon,
                  createdAt: folder?.createdAt ?? DateTime.now().toUtc(),
                );
                if (isEditing) {
                  ref.read(foldersProvider.notifier).update(newFolder);
                } else {
                  ref.read(foldersProvider.notifier).add(newFolder);
                }
                Navigator.pop(dialogContext);
              },
              child: Text(isEditing ? l10n.save : l10n.create),
            ),
          ],
        ),
      ),
    ).whenComplete(nameController.dispose);
  }
}
