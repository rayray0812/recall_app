import 'package:flutter/services.dart';
import 'package:recall_app/services/on_device_ai_service.dart';

/// Which on-device inference backend an engine uses.
enum LocalLlmBackend { androidLiteRtLm, appleFoundationModels, none }

/// Abstraction over an on-device LLM backend.
///
/// Lets the rest of the app run local inference without knowing whether it is
/// served by Android LiteRT-LM (a downloaded Gemma/Qwen model) or Apple's
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

/// Android engine backed by LiteRT-LM via [OnDeviceAiService].
///
/// Wraps the existing MethodChannel bridge so the higher layers depend on the
/// [LocalLlmEngine] interface rather than the static service directly.
class AndroidLiteRtLmEngine implements LocalLlmEngine {
  AndroidLiteRtLmEngine({required this.modelPath});

  /// Absolute path to the downloaded `.litertlm` / `.task` model file.
  final String modelPath;

  @override
  LocalLlmBackend get backend => LocalLlmBackend.androidLiteRtLm;

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

/// iOS engine backed by Apple's Foundation Models framework (iOS 26+).
///
/// Uses the OS-provided ~3B on-device model — no model download required. The
/// Dart side talks to a MethodChannel; the native Swift implementation
/// (`appleFoundationModelsAvailable` / `appleGenerate`) is added in the iOS
/// Runner. Until that native side ships, [isAvailable] returns false via
/// [MissingPluginException] and the engine is never selected.
class AppleFoundationModelsEngine implements LocalLlmEngine {
  const AppleFoundationModelsEngine();

  static const MethodChannel _channel = MethodChannel(
    'recall_app/on_device_ai',
  );

  @override
  LocalLlmBackend get backend => LocalLlmBackend.appleFoundationModels;

  @override
  Future<bool> isAvailable() async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'appleFoundationModelsAvailable',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> generate({
    required String prompt,
    int maxTokens = 256,
    double temperature = 0.0,
    int topK = 1,
  }) async {
    try {
      final out = await _channel.invokeMethod<String>('appleGenerate', {
        'prompt': prompt,
        'maxTokens': maxTokens,
        'temperature': temperature,
      });
      return out ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> dispose() async {}
}

/// Always-unavailable engine for platforms without an on-device backend
/// (web, older iOS without Apple Intelligence).
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
