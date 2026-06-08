import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_gateway.dart';
import 'package:recall_app/services/ai/ai_quota_policy.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';

void main() {
  group('AiQuotaPolicy.isMetered', () {
    test('cloud-routable cost-bearing tasks are metered', () {
      expect(AiQuotaPolicy.isMetered(AiTaskType.conversationTurn), isTrue);
      expect(AiQuotaPolicy.isMetered(AiTaskType.exampleSentence), isTrue);
      expect(AiQuotaPolicy.isMetered(AiTaskType.smartDistractors), isTrue);
      expect(AiQuotaPolicy.isMetered(AiTaskType.photoImport), isTrue);
      expect(AiQuotaPolicy.isMetered(AiTaskType.speakingScore), isTrue);
    });

    test('local-only tasks are never metered', () {
      expect(AiQuotaPolicy.isMetered(AiTaskType.reviewHint), isFalse);
      expect(AiQuotaPolicy.isMetered(AiTaskType.mnemonic), isFalse);
      expect(AiQuotaPolicy.isMetered(AiTaskType.confusionDiagnosis), isFalse);
    });
  });

  group('AiQuotaPolicy.dailyLimit', () {
    test('unmetered tasks are always unlimited regardless of tier', () {
      expect(
        AiQuotaPolicy.dailyLimit(AiEntitlement.free, AiTaskType.reviewHint),
        AiQuotaPolicy.unlimited,
      );
    });

    test('pro and classroom tiers are unlimited for metered tasks', () {
      expect(
        AiQuotaPolicy.dailyLimit(
          AiEntitlement.proAi,
          AiTaskType.smartDistractors,
        ),
        AiQuotaPolicy.unlimited,
      );
      expect(
        AiQuotaPolicy.dailyLimit(
          AiEntitlement.classroom,
          AiTaskType.conversationTurn,
        ),
        AiQuotaPolicy.unlimited,
      );
    });

    test('free tier has lower caps than plus', () {
      final free = AiQuotaPolicy.dailyLimit(
        AiEntitlement.free,
        AiTaskType.smartDistractors,
      );
      final plus = AiQuotaPolicy.dailyLimit(
        AiEntitlement.plus,
        AiTaskType.smartDistractors,
      );
      expect(free, greaterThan(0));
      expect(plus, greaterThan(free));
      expect(
        AiQuotaPolicy.dailyLimit(
          AiEntitlement.free,
          AiTaskType.exampleSentence,
        ),
        30,
      );
      expect(
        AiQuotaPolicy.dailyLimit(
          AiEntitlement.plus,
          AiTaskType.exampleSentence,
        ),
        300,
      );
    });
  });

  group('AiQuotaPolicy.allows / remaining', () {
    test('allows until the cap is reached, then blocks', () {
      const e = AiEntitlement.free;
      const t = AiTaskType.photoImport; // free cap = 10
      expect(
        AiQuotaPolicy.allows(entitlement: e, type: t, usedToday: 9),
        isTrue,
      );
      expect(
        AiQuotaPolicy.allows(entitlement: e, type: t, usedToday: 10),
        isFalse,
      );
    });

    test('unlimited tier always allows', () {
      expect(
        AiQuotaPolicy.allows(
          entitlement: AiEntitlement.proAi,
          type: AiTaskType.photoImport,
          usedToday: 99999,
        ),
        isTrue,
      );
    });

    test('remaining clamps to 0 and never goes negative', () {
      expect(
        AiQuotaPolicy.remaining(
          entitlement: AiEntitlement.free,
          type: AiTaskType.photoImport,
          usedToday: 25,
        ),
        0,
      );
    });

    test('remaining for unlimited stays unlimited', () {
      expect(
        AiQuotaPolicy.remaining(
          entitlement: AiEntitlement.proAi,
          type: AiTaskType.smartDistractors,
          usedToday: 5,
        ),
        AiQuotaPolicy.unlimited,
      );
    });
  });

  group('AiGateway.decide', () {
    const cloudRoute = AiRouteDecision(AiRouteTarget.cloud, 'test cloud');
    const localRoute = AiRouteDecision(AiRouteTarget.local, 'test local');
    const unavailableRoute =
        AiRouteDecision(AiRouteTarget.unavailable, 'test none');

    test('cloud route within quota → runCloud with remaining count', () {
      final d = AiGateway.decide(
        route: cloudRoute,
        entitlement: AiEntitlement.free,
        type: AiTaskType.smartDistractors,
        usedToday: 0,
      );
      expect(d.outcome, AiGatewayOutcome.runCloud);
      expect(d.canRun, isTrue);
      expect(d.remaining, greaterThan(0));
    });

    test('cloud route with exhausted quota → blockedQuota', () {
      final d = AiGateway.decide(
        route: cloudRoute,
        entitlement: AiEntitlement.free,
        type: AiTaskType.smartDistractors,
        usedToday: 60, // free cap
      );
      expect(d.outcome, AiGatewayOutcome.blockedQuota);
      expect(d.canRun, isFalse);
      expect(d.remaining, 0);
    });

    test('local route is unmetered → runLocal (quota ignored)', () {
      final d = AiGateway.decide(
        route: localRoute,
        entitlement: AiEntitlement.free,
        type: AiTaskType.smartDistractors,
        usedToday: 99999,
      );
      expect(d.outcome, AiGatewayOutcome.runLocal);
      expect(d.canRun, isTrue);
    });

    test('unavailable route → unavailable, carries the route reason', () {
      final d = AiGateway.decide(
        route: unavailableRoute,
        entitlement: AiEntitlement.free,
        type: AiTaskType.smartDistractors,
        usedToday: 0,
      );
      expect(d.outcome, AiGatewayOutcome.unavailable);
      expect(d.canRun, isFalse);
      expect(d.reason, 'test none');
    });

    test('unlimited tier on cloud route never blocks', () {
      final d = AiGateway.decide(
        route: cloudRoute,
        entitlement: AiEntitlement.proAi,
        type: AiTaskType.smartDistractors,
        usedToday: 100000,
      );
      expect(d.outcome, AiGatewayOutcome.runCloud);
      expect(d.remaining, AiQuotaPolicy.unlimited);
    });
  });
}
