import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The platform an on-device model would run on.
enum AiPlatform { android, ios, web, other }

/// Recommended size class of a *downloadable* on-device model for a device.
///
/// iOS uses Apple's OS-provided Foundation Models instead of a downloaded
/// model, so this tier only drives Android model selection.
enum ModelTier {
  /// No on-device LLM (too little RAM, unsupported platform).
  none,

  /// ~2B-class model (Gemma 3n E2B, Qwen 2B). Needs ~3GB+ RAM.
  tiny,

  /// ~4B-class model (Gemma 3n E4B, Qwen3 4B). Needs ~6GB+ RAM.
  standard,
}

/// Snapshot of a device's on-device AI capability.
@immutable
class AiCapability {
  const AiCapability({
    required this.platform,
    required this.totalRamMb,
    required this.appleFoundationModels,
  });

  final AiPlatform platform;

  /// Total device RAM in MB, or null when it could not be determined.
  final int? totalRamMb;

  /// Whether Apple's Foundation Models framework is available (iOS 26+ with
  /// Apple Intelligence enabled). When true, iOS gets a zero-download engine.
  final bool appleFoundationModels;

  /// Whether *any* on-device LLM can run: Apple FM on iOS, or a recommendable
  /// downloadable model on Android.
  bool get supportsLocalLlm =>
      appleFoundationModels ||
      (platform == AiPlatform.android && recommendedTier != ModelTier.none);

  /// Which downloadable model tier to recommend (Android only).
  ModelTier get recommendedTier {
    if (platform != AiPlatform.android) return ModelTier.none;
    final ram = totalRamMb;
    // Unknown RAM → assume a usable mid-range device but stay conservative.
    if (ram == null) return ModelTier.tiny;
    if (ram >= 6000) return ModelTier.standard;
    if (ram >= 3000) return ModelTier.tiny;
    return ModelTier.none;
  }

  /// Pure, unit-testable constructor used by both the live detector and tests.
  static AiCapability resolve({
    required AiPlatform platform,
    int? totalRamMb,
    bool appleFoundationModels = false,
  }) {
    return AiCapability(
      platform: platform,
      totalRamMb: totalRamMb,
      appleFoundationModels: appleFoundationModels,
    );
  }

  @override
  String toString() =>
      'AiCapability(platform: $platform, ramMb: $totalRamMb, '
      'appleFM: $appleFoundationModels, tier: $recommendedTier)';
}

/// Detects on-device AI capability with best-effort native probes.
///
/// The native side (RAM query, Apple Foundation Models availability) is filled
/// in during Phase C2; until then the probes fail gracefully via
/// [MissingPluginException] and the resolver falls back to safe defaults.
class AiCapabilityService {
  const AiCapabilityService();

  static const MethodChannel _channel = MethodChannel('recall_app/on_device_ai');

  Future<AiCapability> detect() async {
    final platform = currentPlatform();
    int? ramMb;
    var appleFm = false;

    if (platform == AiPlatform.android) {
      ramMb = await _readTotalRamMb();
    } else if (platform == AiPlatform.ios) {
      appleFm = await _appleFoundationModelsAvailable();
    }

    return AiCapability.resolve(
      platform: platform,
      totalRamMb: ramMb,
      appleFoundationModels: appleFm,
    );
  }

  @visibleForTesting
  static AiPlatform currentPlatform() {
    if (kIsWeb) return AiPlatform.web;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => AiPlatform.android,
      TargetPlatform.iOS => AiPlatform.ios,
      _ => AiPlatform.other,
    };
  }

  Future<int?> _readTotalRamMb() async {
    try {
      final mb = await _channel.invokeMethod<int>('totalRamMb');
      return mb;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _appleFoundationModelsAvailable() async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'appleFoundationModelsAvailable',
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
