import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/local_llm_engine.dart';

/// On-device model file format.
enum ModelFormat { litertlm, task, gguf }

/// A downloadable on-device model.
class AiModelSpec {
  const AiModelSpec({
    required this.id,
    required this.displayName,
    required this.tier,
    required this.sizeMb,
    required this.url,
    required this.format,
    required this.backend,
    this.multimodal = false,
    this.strongChinese = false,
    this.sha256,
    this.note = '',
  });

  /// Stable id, also used as the on-disk filename stem.
  final String id;
  final String displayName;
  final ModelTier tier;
  final int sizeMb;

  /// Direct download URL.
  ///
  /// These point at Hugging Face `litert-community` repos that are Apache-2.0
  /// and NOT gated, so an anonymous HTTP GET works (no HF token needed).
  /// Verified on 2026-06; re-check the exact filename if a repo is re-released.
  final String url;
  final ModelFormat format;
  final LocalLlmBackend backend;
  final bool multimodal;
  final bool strongChinese;

  /// Optional SHA-256 for integrity verification (not yet enforced — needs a
  /// crypto dependency; see ModelManagerService).
  final String? sha256;
  final String note;

  String get fileName => '$id.${format.name}';
}

/// Static catalog of recommended on-device models + selection logic.
///
/// Runs on LiteRT-LM (the successor to the deprecated MediaPipe LLM Inference
/// API). Both entries below are Apache-2.0 + ungated → directly downloadable.
/// iOS uses Apple Foundation Models instead (no download).
class ModelCatalog {
  const ModelCatalog._();

  /// Gemma 4 E2B — default for capable Android devices. ~2B effective,
  /// multimodal, LiteRT-LM native. Apache-2.0, ungated.
  /// Repo: litert-community/gemma-4-E2B-it-litert-lm
  static const gemma4E2b = AiModelSpec(
    id: 'gemma-4-E2B-it',
    displayName: 'Gemma 4 E2B',
    tier: ModelTier.standard,
    sizeMb: 2590,
    url:
        'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    format: ModelFormat.litertlm,
    backend: LocalLlmBackend.androidLiteRtLm,
    multimodal: true,
    note: '中高階 Android 預設；多模態；Apache-2.0 免授權直接下載',
  );

  /// Qwen3 0.6B — lightweight / low-RAM option. Tiny + fast, decent Chinese.
  /// Apache-2.0, ungated. Repo: litert-community/Qwen3-0.6B
  static const qwen3_06b = AiModelSpec(
    id: 'Qwen3-0.6B',
    displayName: 'Qwen3 0.6B（輕量·中文）',
    tier: ModelTier.tiny,
    sizeMb: 614,
    url:
        'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
    format: ModelFormat.litertlm,
    backend: LocalLlmBackend.androidLiteRtLm,
    strongChinese: true,
    note: '低 RAM / 快速；繁中佳；Apache-2.0 免授權直接下載',
  );

  static const all = <AiModelSpec>[gemma4E2b, qwen3_06b];

  static AiModelSpec? byId(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  static List<AiModelSpec> forTier(ModelTier tier) =>
      all.where((m) => m.tier == tier).toList(growable: false);

  /// The default model to recommend for a device.
  ///
  /// iOS uses Apple Foundation Models (no download), so returns null there.
  /// Android picks by RAM tier: capable devices get Gemma 4 E2B (better
  /// quality + multimodal), low-RAM devices get the tiny Qwen3 0.6B.
  static AiModelSpec? recommended(AiCapability capability) {
    if (capability.platform != AiPlatform.android) return null;
    return switch (capability.recommendedTier) {
      ModelTier.standard => gemma4E2b,
      ModelTier.tiny => qwen3_06b,
      ModelTier.none => null,
    };
  }
}
