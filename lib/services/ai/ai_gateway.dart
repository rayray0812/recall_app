import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';

/// Final outcome after combining routing with entitlement/quota.
enum AiGatewayOutcome {
  /// Run on-device (free — never metered).
  runLocal,

  /// Run in the cloud, within the daily quota.
  runCloud,

  /// Routed to cloud but the daily quota for this entitlement is exhausted.
  blockedQuota,

  /// Cannot run anywhere (no model, offline + no cloud, privacy mode, etc.).
  unavailable,
}

/// The gateway's decision for a single AI task, with a human-readable reason and
/// the remaining cloud quota (for UI messaging like "3 left today").
class AiGatewayDecision {
  const AiGatewayDecision(this.outcome, this.reason, this.remaining);

  final AiGatewayOutcome outcome;
  final String reason;

  /// Remaining metered cloud calls today; [AiQuotaPolicy.unlimited] = no cap.
  /// Always [AiQuotaPolicy.unlimited] for local/unavailable outcomes.
  final int remaining;

  bool get canRun =>
      outcome == AiGatewayOutcome.runLocal ||
      outcome == AiGatewayOutcome.runCloud;

  @override
  String toString() =>
      'AiGatewayDecision($outcome, "$reason", remaining=$remaining)';
}

/// Single policy authority for AI execution: layers entitlement/quota on top of
/// the routing decision from [AiRouter]. Pure and fully unit-testable — callers
/// pass the live route decision and today's usage; the gateway decides whether
/// the task may run and where (docs §2.6: "all cloud tasks must pass the gateway,
/// never call a provider directly from the UI").
abstract final class AiGateway {
  /// Combine [route] with the [entitlement] quota for [type] (given [usedToday]
  /// metered cloud calls) into one decision.
  static AiGatewayDecision decide({
    required AiRouteDecision route,
    required AiEntitlement entitlement,
    required AiTaskType type,
    required int usedToday,
  }) {
    switch (route.target) {
      case AiRouteTarget.unavailable:
        return AiGatewayDecision(
          AiGatewayOutcome.unavailable,
          route.reason,
          AiQuotaPolicy.unlimited,
        );
      case AiRouteTarget.local:
        // On-device execution is free — quota never applies.
        return const AiGatewayDecision(
          AiGatewayOutcome.runLocal,
          'local execution (unmetered)',
          AiQuotaPolicy.unlimited,
        );
      case AiRouteTarget.cloud:
        final remaining = AiQuotaPolicy.remaining(
          entitlement: entitlement,
          type: type,
          usedToday: usedToday,
        );
        final allowed = AiQuotaPolicy.allows(
          entitlement: entitlement,
          type: type,
          usedToday: usedToday,
        );
        return allowed
            ? AiGatewayDecision(
                AiGatewayOutcome.runCloud,
                'cloud within quota',
                remaining,
              )
            : const AiGatewayDecision(
                AiGatewayOutcome.blockedQuota,
                'daily cloud quota exhausted',
                0,
              );
    }
  }
}
