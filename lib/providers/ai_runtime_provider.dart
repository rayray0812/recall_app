import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_entitlement_service.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai/ai_quota_service.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai/device_power_policy.dart';
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

/// The user's AI entitlement tier (gates daily cloud-AI quota, see §2.6).
///
/// Persisted in the settings box; defaults to [AiEntitlement.free]. For now this
/// is set locally — billing/server entitlement sync is future work, but the
/// gateway already reads from here so wiring real entitlements later is a
/// one-place change.
class AiEntitlementNotifier extends StateNotifier<AiEntitlement> {
  AiEntitlementNotifier() : super(AiEntitlement.free) {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(AppConstants.hiveSettingsBox);
      final name = box.get(AppConstants.settingAiEntitlementKey) as String?;
      if (name != null) {
        state = AiEntitlement.values.firstWhere(
          (e) => e.name == name,
          orElse: () => AiEntitlement.free,
        );
      }
    } catch (e) {
      debugPrint('AI entitlement load failed: $e');
      state = AiEntitlement.free;
    }
  }

  Future<void> setEntitlement(AiEntitlement entitlement) async {
    state = entitlement;
    try {
      await Hive.box(
        AppConstants.hiveSettingsBox,
      ).put(AppConstants.settingAiEntitlementKey, entitlement.name);
    } catch (e) {
      debugPrint('AI entitlement save failed: $e');
    }
  }
}

final aiEntitlementProvider =
    StateNotifierProvider<AiEntitlementNotifier, AiEntitlement>(
      (ref) => AiEntitlementNotifier(),
    );

/// Server-verified entitlement cache. Missing rows, signed-out users, expired
/// tiers, network errors, and unconfigured Supabase all fail closed to free.
final serverAiEntitlementProvider = FutureProvider<AiEntitlement>((ref) async {
  ref.watch(currentUserProvider);
  final service = AiEntitlementService(ref.watch(supabaseServiceProvider));
  try {
    return await service.fetchCurrent();
  } catch (e) {
    debugPrint('Server AI entitlement fetch failed: $e');
    return AiEntitlement.free;
  }
});

/// The entitlement that actually governs quota — the single source of truth for
/// all metered-AI decisions. In debug we honor [aiEntitlementProvider] so the
/// dev plan switcher can be used for testing. In release we read the
/// server-verified Supabase entitlement and fail closed to free while loading or
/// on error.
///
/// Do NOT read [aiEntitlementProvider] in release: it is local storage and can
/// be edited by a determined user.
final effectiveAiEntitlementProvider = Provider<AiEntitlement>((ref) {
  if (kDebugMode) return ref.watch(aiEntitlementProvider);
  return ref.watch(serverAiEntitlementProvider).valueOrNull ??
      AiEntitlement.free;
});

/// Server-side AI proxy client for owner-funded cloud AI.
///
/// The proxy owns all Grasp provider secrets in Supabase Edge Function env vars;
/// Flutter only sends whitelisted task payloads and receives generated text.
final aiProxyClientProvider = Provider<AiProxyClient>((ref) {
  return AiProxyClient();
});

/// Daily cloud-AI usage tracker + quota enforcement (Hive-backed).
final aiQuotaServiceProvider = Provider<AiQuotaService>((ref) {
  return AiQuotaService();
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

/// Whether device power state permits heavy on-device inference right now.
///
/// On-device LLM inference is a sustained, power-hungry, heat-generating
/// workload, so we back off in battery-saver / low-battery situations (see
/// [DevicePowerPolicy]). Reads battery state via battery_plus and *fails safe*:
/// any error or unsupported platform (web/desktop) returns true so AI features
/// are never blocked merely for lack of power information.
final localInferenceAllowedProvider = FutureProvider<bool>((ref) async {
  try {
    final battery = Battery();
    final level = await battery.batteryLevel;
    final batteryState = await battery.batteryState;
    final saveMode = await battery.isInBatterySaveMode;
    final isCharging =
        batteryState == BatteryState.charging ||
        batteryState == BatteryState.full;
    return DevicePowerPolicy.allowsLocalInference(
      DevicePowerSnapshot(
        batteryLevel: level,
        isCharging: isCharging,
        batterySaveMode: saveMode,
      ),
    );
  } catch (e) {
    debugPrint('localInferenceAllowed check failed (defaulting to true): $e');
    return true;
  }
});

/// Whether a *BYO* cloud key is configured (provider not gemma + a key present).
///
/// Choosing the on-device ("本機"/gemma) provider means cloud is NOT used for
/// task routing — so selecting "本機" genuinely keeps tasks on-device, instead
/// of that being controlled only by the separate privacy-mode toggle.
///
/// This intentionally does NOT account for the owner-funded server proxy, which
/// is only available for some tasks — use [cloudConfiguredForTaskProvider] for
/// routing decisions.
final cloudConfiguredProvider = Provider<bool>((ref) {
  if (ref.watch(aiProviderProvider) == AiProvider.gemma) return false;
  final geminiKey = ref.watch(geminiKeyProvider);
  final groqKey = ref.watch(groqKeyProvider);
  return geminiKey.trim().isNotEmpty || groqKey.trim().isNotEmpty;
});

/// Whether [type] has a usable cloud path: either a BYO key, or — for tasks the
/// client actually routes through the Grasp proxy ([proxyBackedTasks]) — a
/// signed-in user (owner-funded). A signed-in keyless user is NOT considered
/// cloud-capable for tasks without a proxy call site (conversation/photo import/
/// speaking score), so those correctly require a key instead of silently
/// "configuring" cloud and then degrading.
final cloudConfiguredForTaskProvider = Provider.family<bool, AiTaskType>((
  ref,
  type,
) {
  if (ref.watch(aiProviderProvider) == AiProvider.gemma) return false;
  if (ref.watch(cloudConfiguredProvider)) return true;
  final user = ref.watch(currentUserProvider);
  return user != null && proxyBackedTasks.contains(type);
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
  final cloudConfigured = ref.watch(cloudConfiguredForTaskProvider(type));
  final localAllowed = await ref.watch(localInferenceAllowedProvider.future);

  return AiRouter.route(
    type: type,
    capability: capability,
    localModelReady: localReady,
    online: online,
    privacyMode: privacyMode,
    cloudConfigured: cloudConfigured,
    localInferenceAllowed: localAllowed,
  );
});
