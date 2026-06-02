import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';

/// Settings card that downloads the recommended on-device model for this
/// device, replacing the old "manually import a .litertlm file" flow.
///
/// Picks the model via [ModelCatalog.recommended] (device-capability aware),
/// streams it to disk with a progress bar, and points
/// [gemmaLocalModelPathProvider] at the installed file so the existing local-AI
/// providers and [localLlmEngineProvider] pick it up.
class ModelManagerCard extends ConsumerStatefulWidget {
  const ModelManagerCard({super.key});

  @override
  ConsumerState<ModelManagerCard> createState() => _ModelManagerCardState();
}

class _ModelManagerCardState extends ConsumerState<ModelManagerCard> {
  bool _downloading = false;
  double? _progress;
  String? _error;

  Future<void> _download(AiModelSpec spec) async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });
    final manager = ref.read(modelManagerProvider);
    try {
      final path = await manager.download(
        spec,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p.fraction);
        },
      );
      await ref.read(gemmaLocalModelPathProvider.notifier).setPath(path);
      ref.invalidate(localLlmEngineProvider);
      ref.invalidate(localModelReadyProvider);
      if (mounted) setState(() => _downloading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _delete(AiModelSpec spec) async {
    final manager = ref.read(modelManagerProvider);
    await manager.delete(spec);
    await ref.read(gemmaLocalModelPathProvider.notifier).clear();
    ref.invalidate(localLlmEngineProvider);
    ref.invalidate(localModelReadyProvider);
    if (mounted) setState(() {});
  }

  String _sizeLabel(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

  @override
  Widget build(BuildContext context) {
    final capAsync = ref.watch(aiCapabilityProvider);
    final installedPath = ref.watch(gemmaLocalModelPathProvider);

    return capAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => _infoBox(context, 'AI capability check failed: $e'),
      data: (cap) {
        final spec = ModelCatalog.recommended(cap);
        if (spec == null) {
          return _infoBox(
            context,
            cap.platform == AiPlatform.ios
                ? 'iOS will use Apple’s built-in AI — no model download needed.'
                : 'This device has limited memory; cloud AI will be used instead.',
          );
        }
        return _modelBox(context, cap, spec, installedPath.trim().isNotEmpty);
      },
    );
  }

  Widget _modelBox(
    BuildContext context,
    AiCapability cap,
    AiModelSpec spec,
    bool installed,
  ) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.download_for_offline_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Recommended model',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${spec.displayName} · ${_sizeLabel(spec.sizeMb)}'
            '${spec.multimodal ? ' · multimodal' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (spec.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                spec.note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 10),
          if (_downloading) ...[
            LinearProgressIndicator(value: _progress, minHeight: 4),
            const SizedBox(height: 4),
            Text(
              _progress == null
                  ? 'Downloading…'
                  : 'Downloading… ${(_progress! * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.bodySmall,
            ),
          ] else if (installed)
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: Colors.green.shade700,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Installed',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green.shade700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _delete(spec),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Remove'),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => _download(spec),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: Text('Download (${_sizeLabel(spec.sizeMb)})'),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _infoBox(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
