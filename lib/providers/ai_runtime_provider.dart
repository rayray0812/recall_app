import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai/local_llm_engine.dart';
import 'package:recall_app/services/ai/model_manager_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// Runtime wiring that connects the Phase C1 AI infrastructure
/// ([AiCapabilityService], [ModelManagerService], [AiRouter]) to the app.
///
/// Nothing here makes a routing *decision* on its own — the pure logic lives in
/// [AiRouter.route]; these providers just gather the live inputs (device
/// capability, installed model, connectivity, privacy mode, cloud keys).

/// Detected on-device AI capability (platform / RAM / Apple FM availability).
final aiCapabilityProvider = FutureProvider<AiCapability>((ref) async {
  return const AiCapabilityService().detect();
});

/// Shared model download/storage manager.
final modelManagerProvider = Provider<ModelManagerService>((ref) {
  final manager = ModelManagerService();
  return manager;
});

/// Whether the user enabled privacy mode (force on-device, never use cloud).
class AiPrivacyModeNotifier extends StateNotifier<bool> {
  AiPrivacyModeNotifier() : super(false) {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(AppConstants.hiveSettingsBox);
      state =
          box.get(AppConstants.settingAiPrivacyModeKey, defaultValue: false)
              as bool;
    } catch (e) {
      debugPrint('AI privacy mode load failed: $e');
      state = false;
    }
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    try {
      await Hive.box(
        AppConstants.hiveSettingsBox,
      ).put(AppConstants.settingAiPrivacyModeKey, enabled);
    } catch (e) {
      debugPrint('AI privacy mode save failed: $e');
    }
  }
}

final aiPrivacyModeProvider =
    StateNotifierProvider<AiPrivacyModeNotifier, bool>(
      (ref) => AiPrivacyModeNotifier(),
    );

/// The on-device engine for the current device, or [NullLocalLlmEngine] when
/// none is available.
///
/// Android: uses a downloaded catalog model if installed, otherwise the legacy
/// manually-imported model path (backward compatible). iOS gets the Apple
/// Foundation Models engine in Phase C2; until then it is Null.
final localLlmEngineProvider = FutureProvider<LocalLlmEngine>((ref) async {
  final capability = await ref.watch(aiCapabilityProvider.future);

  // iOS: use Apple's OS-provided Foundation Models (no download) when available.
  if (capability.platform == AiPlatform.ios &&
      capability.appleFoundationModels) {
    return const AppleFoundationModelsEngine();
  }

  if (capability.platform == AiPlatform.android) {
    final manager = ref.watch(modelManagerProvider);

    // 1. Honor the user's explicit choice first (set by ModelManagerCard's
    //    download / "使用" actions). This is what makes switching models work —
    //    selecting Qwen3 must actually run Qwen3 even if Gemma 4 is installed.
    var path = ref.watch(gemmaLocalModelPathProvider).trim();

    // 2. Otherwise default to the device-recommended model if it's installed.
    if (path.isEmpty) {
      final recommended = ModelCatalog.recommended(capability);
      if (recommended != null) {
        path = (await manager.installedPath(recommended) ?? '').trim();
      }
    }
    if (path.isNotEmpty) {
      return AndroidLiteRtLmEngine(modelPath: path);
    }
  }

  return const NullLocalLlmEngine();
});

/// Whether the on-device engine can run inference right now.
final localModelReadyProvider = FutureProvider<bool>((ref) async {
  final engine = await ref.watch(localLlmEngineProvider.future);
  return engine.isAvailable();
});

/// Coarse online/offline signal from connectivity_plus.
final aiOnlineProvider = StreamProvider<bool>((ref) {
  return Connectivity().onConnectivityChanged.map(
    (results) => results.any((r) => r != ConnectivityResult.none),
  );
});

/// Whether a cloud provider can be called for routing.
///
/// Choosing the on-device ("本機"/gemma) provider means cloud is NOT used for
/// task routing — so selecting "本機" genuinely keeps tasks on-device, instead
/// of that being controlled only by the separate privacy-mode toggle.
final cloudConfiguredProvider = Provider<bool>((ref) {
  if (ref.watch(aiProviderProvider) == AiProvider.gemma) return false;
  final geminiKey = ref.watch(geminiKeyProvider);
  final groqKey = ref.watch(groqKeyProvider);
  return geminiKey.trim().isNotEmpty || groqKey.trim().isNotEmpty;
});

/// The routing decision for a given AI task type, combining all live inputs
/// through the pure [AiRouter.route].
final aiRouteProvider = FutureProvider.family<AiRouteDecision, AiTaskType>((
  ref,
  type,
) async {
  final capability = await ref.watch(aiCapabilityProvider.future);
  final localReady = await ref.watch(localModelReadyProvider.future);
  final online = ref.watch(aiOnlineProvider).valueOrNull ?? true;
  final privacyMode = ref.watch(aiPrivacyModeProvider);
  final cloudConfigured = ref.watch(cloudConfiguredProvider);

  return AiRouter.route(
    type: type,
    capability: capability,
    localModelReady: localReady,
    online: online,
    privacyMode: privacyMode,
    cloudConfigured: cloudConfigured,
  );
});
