import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';

/// Settings card that lists the available on-device models and lets the user
/// download, switch between, and remove them — replacing the old "manually
/// import a .litertlm file" flow.
///
/// The device-recommended model (via [ModelCatalog.recommended]) is badged
/// "推薦", but every catalog model is selectable so the user can pick e.g.
/// Qwen3 for Chinese over the larger default. Downloading or switching points
/// [gemmaLocalModelPathProvider] at the chosen file so the local-AI providers
/// and [localLlmEngineProvider] pick it up.
class ModelManagerCard extends ConsumerStatefulWidget {
  const ModelManagerCard({super.key});

  @override
  ConsumerState<ModelManagerCard> createState() => _ModelManagerCardState();
}

class _ModelManagerCardState extends ConsumerState<ModelManagerCard> {
  /// modelId currently downloading (null = none).
  String? _downloadingId;
  double? _progress;
  String? _error;

  /// modelId -> installed file path (null value = not installed).
  Map<String, String?> _installed = {};

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  Future<void> _refreshInstalled() async {
    final manager = ref.read(modelManagerProvider);
    final map = <String, String?>{};
    for (final spec in ModelCatalog.all) {
      map[spec.id] = await manager.installedPath(spec);
    }
    if (mounted) setState(() => _installed = map);
  }

  Future<void> _download(AiModelSpec spec) async {
    setState(() {
      _downloadingId = spec.id;
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
      _invalidateEngine();
      if (mounted) setState(() => _downloadingId = null);
      await _refreshInstalled();
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _error = _friendlyError(e);
        });
      }
    }
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Failed host lookup') ||
        s.contains('SocketException') ||
        s.contains('ClientException')) {
      return '網路連線失敗。請確認已連上網路（WiFi 有訊號、無需登入頁）後再重試 — '
          '下載會從中斷處續傳。';
    }
    return '下載失敗：$e';
  }

  /// Make an already-installed model the active one for inference.
  Future<void> _use(AiModelSpec spec) async {
    final path = _installed[spec.id];
    if (path == null) return;
    await ref.read(gemmaLocalModelPathProvider.notifier).setPath(path);
    _invalidateEngine();
    if (mounted) setState(() {});
  }

  Future<void> _remove(AiModelSpec spec) async {
    final manager = ref.read(modelManagerProvider);
    final path = _installed[spec.id];
    await manager.delete(spec);
    // If the removed model was the active one, clear the active path.
    if (path != null && ref.read(gemmaLocalModelPathProvider) == path) {
      await ref.read(gemmaLocalModelPathProvider.notifier).clear();
    }
    _invalidateEngine();
    await _refreshInstalled();
  }

  void _invalidateEngine() {
    ref.invalidate(localLlmEngineProvider);
    ref.invalidate(localModelReadyProvider);
  }

  String _sizeLabel(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';

  @override
  Widget build(BuildContext context) {
    final capAsync = ref.watch(aiCapabilityProvider);
    final activePath = ref.watch(gemmaLocalModelPathProvider);

    return capAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      ),
      error: (e, _) => _infoBox(context, 'AI capability check failed: $e'),
      data: (cap) {
        if (cap.platform == AiPlatform.ios) {
          return _infoBox(
            context,
            'iOS will use Apple’s built-in AI — no model download needed.',
          );
        }
        if (!cap.supportsLocalLlm) {
          return _infoBox(
            context,
            'This device has limited memory; cloud AI will be used instead.',
          );
        }
        final recommendedId = ModelCatalog.recommended(cap)?.id;
        final theme = Theme.of(context);
        final hasActiveCatalogModel = _installed.values.any(
          (path) => path != null && path == activePath,
        );
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.30),
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
                      '本地模型（選一個下載）',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final spec in ModelCatalog.all)
                _modelRow(
                  context,
                  spec,
                  isRecommended: spec.id == recommendedId,
                  activePath: activePath,
                ),
              if (activePath.trim().isNotEmpty && !hasActiveCatalogModel)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _staleModelBox(context),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
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
      },
    );
  }

  Widget _staleModelBox(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '目前選到舊版或無效的本地模型。請清除後下載新版模型。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                await ref.read(gemmaLocalModelPathProvider.notifier).clear();
                _invalidateEngine();
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.cleaning_services_rounded, size: 16),
              label: const Text('清除目前模型'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelRow(
    BuildContext context,
    AiModelSpec spec, {
    required bool isRecommended,
    required String activePath,
  }) {
    final theme = Theme.of(context);
    final installedPath = _installed[spec.id];
    final installed = installedPath != null;
    final isActive = installed && installedPath == activePath;
    final isDownloading = _downloadingId == spec.id;

    final tags = <String>[
      _sizeLabel(spec.sizeMb),
      if (spec.multimodal) '多模態',
      if (spec.strongChinese) '中文',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          spec.displayName,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (isRecommended) _badge(context, '推薦', primary: true),
                        if (isActive) _badge(context, '使用中', primary: false),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tags.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _action(
                spec,
                installed: installed,
                isActive: isActive,
                isDownloading: isDownloading,
              ),
            ],
          ),
          if (isDownloading) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _progress, minHeight: 4),
            const SizedBox(height: 2),
            Text(
              _progress == null
                  ? '下載中…'
                  : '下載中… ${(_progress! * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _action(
    AiModelSpec spec, {
    required bool installed,
    required bool isActive,
    required bool isDownloading,
  }) {
    if (isDownloading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      );
    }
    // Don't allow starting a second download while one is in flight.
    final busy = _downloadingId != null;
    if (!installed) {
      return FilledButton.tonal(
        onPressed: busy ? null : () => _download(spec),
        child: Text('下載 ${_sizeLabel(spec.sizeMb)}'),
      );
    }
    // Installed.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isActive)
          TextButton(
            onPressed: busy ? null : () => _use(spec),
            child: const Text('使用'),
          ),
        IconButton(
          tooltip: '移除',
          onPressed: busy ? null : () => _remove(spec),
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
        ),
      ],
    );
  }

  Widget _badge(BuildContext context, String text, {required bool primary}) {
    final theme = Theme.of(context);
    final color = primary ? theme.colorScheme.primary : Colors.green.shade700;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
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
