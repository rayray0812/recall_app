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

  /// Download URL.
  ///
  /// NOTE: confirm these against the official LiteRT / Hugging Face release
  /// before shipping — they move between model revisions.
  final String url;
  final ModelFormat format;
  final LocalLlmBackend backend;
  final bool multimodal;
  final bool strongChinese;
  final String? sha256;
  final String note;

  String get fileName => '$id.${format.name}';
}

/// Static catalog of recommended on-device models + selection logic.
class ModelCatalog {
  const ModelCatalog._();

  /// Gemma 3n E2B — Android default. ~2B effective, multimodal, MediaPipe.
  static const gemma3nE2b = AiModelSpec(
    id: 'gemma-3n-e2b-it',
    displayName: 'Gemma 3n E2B',
    tier: ModelTier.tiny,
    sizeMb: 1400,
    url: 'https://huggingface.co/litert-community/Gemma-3n-E2B-it-litert-lm',
    format: ModelFormat.litertlm,
    backend: LocalLlmBackend.androidMediaPipe,
    multimodal: true,
    note: '低-中階 Android 預設；多模態（文字/圖/音）',
  );

  /// Gemma 3n E4B — high-end Android. ~4B effective, multimodal.
  static const gemma3nE4b = AiModelSpec(
    id: 'gemma-3n-e4b-it',
    displayName: 'Gemma 3n E4B',
    tier: ModelTier.standard,
    sizeMb: 3100,
    url: 'https://huggingface.co/litert-community/Gemma-3n-E4B-it-litert-lm',
    format: ModelFormat.litertlm,
    backend: LocalLlmBackend.androidMediaPipe,
    multimodal: true,
    note: '高階 Android（RAM≥6GB）；多模態，品質更好',
  );

  /// Qwen3 4B — "Chinese boost" option. Best Traditional-Chinese quality.
  static const qwen3_4b = AiModelSpec(
    id: 'qwen3-4b-it',
    displayName: 'Qwen3 4B（中文增強）',
    tier: ModelTier.standard,
    sizeMb: 2600,
    url: 'https://huggingface.co/litert-community/Qwen3-4B-litert-lm',
    format: ModelFormat.litertlm,
    backend: LocalLlmBackend.androidMediaPipe,
    strongChinese: true,
    note: '繁體中文釋義/例句品質最佳；需 LiteRT 轉檔確認',
  );

  static const all = <AiModelSpec>[gemma3nE2b, gemma3nE4b, qwen3_4b];

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
  /// Android picks by RAM tier; the Chinese-boost model is offered separately
  /// as an opt-in, not the default.
  static AiModelSpec? recommended(AiCapability capability) {
    if (capability.platform != AiPlatform.android) return null;
    return switch (capability.recommendedTier) {
      ModelTier.standard => gemma3nE4b,
      ModelTier.tiny => gemma3nE2b,
      ModelTier.none => null,
    };
  }
}
