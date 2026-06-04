import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// How strongly a task prefers local vs cloud execution.
enum AiTaskTier {
  /// Must run on-device or not at all (privacy-sensitive, high-frequency,
  /// short output). Never goes to the cloud.
  localOnly,

  /// Run on-device when possible; fall back to cloud only when local is
  /// unavailable and the network/cloud is configured.
  localPreferred,

  /// Run in the cloud when possible (long context / high accuracy); fall back
  /// to local when offline.
  cloudPreferred,
}

/// Where a task should run.
enum AiRouteTarget { local, cloud, unavailable }

/// The outcome of routing a task, with a human-readable reason for analytics.
class AiRouteDecision {
  const AiRouteDecision(this.target, this.reason);

  final AiRouteTarget target;
  final String reason;

  bool get isLocal => target == AiRouteTarget.local;
  bool get isCloud => target == AiRouteTarget.cloud;

  @override
  String toString() => 'AiRouteDecision($target, "$reason")';
}

/// Decides whether an AI task runs on-device, in the cloud, or not at all.
///
/// The policy table ([tierFor]) and [route] are pure functions so they are
/// fully unit-testable without any device, model, or network.
class AiRouter {
  const AiRouter._();

  /// Maps each task type to its routing tier. This is the single source of
  /// truth for the local-first split documented in docs/ai_strategy_plan.md.
  static AiTaskTier tierFor(AiTaskType type) {
    return switch (type) {
      // Short, high-frequency, privacy-sensitive → always local.
      AiTaskType.reviewHint ||
      AiTaskType.mnemonic ||
      AiTaskType.confusionDiagnosis ||
      AiTaskType.exampleSentence ||
      AiTaskType.smartDistractors => AiTaskTier.localOnly,
      // Medium tasks: prefer local, cloud as fallback.
      AiTaskType.photoImport ||
      AiTaskType.speakingScore => AiTaskTier.localPreferred,
      // Long / multi-turn: prefer cloud, local fallback when offline.
      AiTaskType.conversationTurn => AiTaskTier.cloudPreferred,
    };
  }

  /// Resolve where a task should run.
  ///
  /// - [localModelReady]: the chosen local engine reports `isAvailable()`
  ///   (Android model downloaded, or Apple FM ready on iOS).
  /// - [privacyMode]: user opted to keep everything on-device — cloud is never
  ///   used; tasks that can't run locally become unavailable.
  /// - [cloudConfigured]: a cloud provider can be called (key set or free tier).
  /// - [localInferenceAllowed]: device power state permits heavy on-device work
  ///   (see [DevicePowerPolicy]). When false we treat local as unusable so
  ///   battery-saver / low-battery devices stop running the model — cloud tasks
  ///   are unaffected; localOnly affordances simply hide.
  static AiRouteDecision route({
    required AiTaskType type,
    required AiCapability capability,
    required bool localModelReady,
    required bool online,
    required bool privacyMode,
    required bool cloudConfigured,
    bool localInferenceAllowed = true,
  }) {
    final tier = tierFor(type);
    final localOk =
        capability.supportsLocalLlm && localModelReady && localInferenceAllowed;
    final cloudOk = online && cloudConfigured;

    if (privacyMode) {
      return localOk
          ? const AiRouteDecision(AiRouteTarget.local, 'privacy mode → local')
          : const AiRouteDecision(
              AiRouteTarget.unavailable,
              'privacy mode on but no local model',
            );
    }

    return switch (tier) {
      AiTaskTier.localOnly => localOk
          ? const AiRouteDecision(AiRouteTarget.local, 'localOnly task')
          : const AiRouteDecision(
              AiRouteTarget.unavailable,
              'localOnly task but no local model',
            ),
      AiTaskTier.localPreferred => localOk
          ? const AiRouteDecision(AiRouteTarget.local, 'localPreferred → local')
          : cloudOk
          ? const AiRouteDecision(
              AiRouteTarget.cloud,
              'localPreferred → cloud fallback',
            )
          : const AiRouteDecision(
              AiRouteTarget.unavailable,
              'no local model and cloud unavailable',
            ),
      AiTaskTier.cloudPreferred => cloudOk
          ? const AiRouteDecision(AiRouteTarget.cloud, 'cloudPreferred → cloud')
          : localOk
          ? const AiRouteDecision(
              AiRouteTarget.local,
              'cloudPreferred → local (offline fallback)',
            )
          : const AiRouteDecision(
              AiRouteTarget.unavailable,
              'cloud unavailable and no local model',
            ),
    };
  }
}
