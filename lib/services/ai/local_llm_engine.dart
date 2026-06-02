import 'package:recall_app/services/on_device_ai_service.dart';

/// Which on-device inference backend an engine uses.
enum LocalLlmBackend { androidMediaPipe, appleFoundationModels, none }

/// Abstraction over an on-device LLM backend.
///
/// Lets the rest of the app run local inference without knowing whether it is
/// served by Android MediaPipe (a downloaded Gemma/Qwen model) or Apple's
/// Foundation Models framework (an OS-provided model on iOS 26+). [AiRouter]
/// decides which concrete engine to use for a given task.
abstract class LocalLlmEngine {
  LocalLlmBackend get backend;

  /// Whether this engine can run inference right now (model present, OS
  /// support available, etc.). Never throws — returns false on any problem.
  Future<bool> isAvailable();

  /// Run a single-shot generation. Returns raw model text (callers clean it).
  Future<String> generate({
    required String prompt,
    int maxTokens = 256,
    double temperature = 0.0,
    int topK = 1,
  });

  /// Release any cached model/resources to free memory.
  Future<void> dispose();
}

/// Android engine backed by MediaPipe `LlmInference` via [OnDeviceAiService].
///
/// Wraps the existing MethodChannel bridge so the higher layers depend on the
/// [LocalLlmEngine] interface rather than the static service directly.
class AndroidMediaPipeEngine implements LocalLlmEngine {
  AndroidMediaPipeEngine({required this.modelPath});

  /// Absolute path to the downloaded `.litertlm` / `.task` model file.
  final String modelPath;

  @override
  LocalLlmBackend get backend => LocalLlmBackend.androidMediaPipe;

  @override
  Future<bool> isAvailable() async {
    if (modelPath.trim().isEmpty) return false;
    final status = await OnDeviceAiService.checkModel(modelPath);
    return status.ready;
  }

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 256,
    double temperature = 0.0,
    int topK = 1,
  }) {
    return OnDeviceAiService.runInference(
      modelPath: modelPath,
      prompt: prompt,
      maxTokens: maxTokens,
      temperature: temperature,
      topK: topK,
    );
  }

  @override
  Future<void> dispose() => OnDeviceAiService.unloadModel();
}

/// Always-unavailable engine for platforms without an on-device backend
/// (web, older iOS) and as the iOS placeholder until the Apple Foundation
/// Models engine lands in Phase C2.
class NullLocalLlmEngine implements LocalLlmEngine {
  const NullLocalLlmEngine();

  @override
  LocalLlmBackend get backend => LocalLlmBackend.none;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 256,
    double temperature = 0.0,
    int topK = 1,
  }) async => '';

  @override
  Future<void> dispose() async {}
}
