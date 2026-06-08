import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_model_catalog.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';

void main() {
  group('AiCapability.recommendedTier', () {
    test('iOS never recommends a downloadable tier', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.ios,
        totalRamMb: 8000,
        appleFoundationModels: true,
      );
      expect(cap.recommendedTier, ModelTier.none);
      // ...but Apple FM still means local AI is supported.
      expect(cap.supportsLocalLlm, isTrue);
    });

    test('Android high RAM → standard tier', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 8000,
      );
      expect(cap.recommendedTier, ModelTier.standard);
      expect(cap.supportsLocalLlm, isTrue);
    });

    test('Android mid RAM → tiny tier', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 4000,
      );
      expect(cap.recommendedTier, ModelTier.tiny);
    });

    test('Android low RAM → none, no local LLM', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 2000,
      );
      expect(cap.recommendedTier, ModelTier.none);
      expect(cap.supportsLocalLlm, isFalse);
    });

    test(
      'Android unknown RAM falls back to tiny (conservative but usable)',
      () {
        final cap = AiCapability.resolve(platform: AiPlatform.android);
        expect(cap.recommendedTier, ModelTier.tiny);
      },
    );

    test('web has no local LLM', () {
      final cap = AiCapability.resolve(platform: AiPlatform.web);
      expect(cap.supportsLocalLlm, isFalse);
    });
  });

  group('ModelCatalog.recommended', () {
    test('standard tier device → Gemma 4 E2B', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 8000,
      );
      expect(ModelCatalog.recommended(cap), ModelCatalog.gemma4E2b);
    });

    test('tiny tier device → Qwen3 0.6B', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 4000,
      );
      expect(ModelCatalog.recommended(cap), ModelCatalog.qwen3_06b);
    });

    test('low-RAM Android → no recommendation', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.android,
        totalRamMb: 1500,
      );
      expect(ModelCatalog.recommended(cap), isNull);
    });

    test('iOS → no downloadable recommendation (uses Apple FM)', () {
      final cap = AiCapability.resolve(
        platform: AiPlatform.ios,
        appleFoundationModels: true,
      );
      expect(ModelCatalog.recommended(cap), isNull);
    });

    test('byId + fileName are stable', () {
      expect(ModelCatalog.byId('gemma-4-E2B-it'), ModelCatalog.gemma4E2b);
      expect(ModelCatalog.gemma4E2b.fileName, 'gemma-4-E2B-it.litertlm');
      expect(ModelCatalog.byId('does-not-exist'), isNull);
    });

    test('catalog models use ungated, direct HF download URLs', () {
      for (final m in ModelCatalog.all) {
        expect(m.url, startsWith('https://huggingface.co/litert-community/'));
        expect(m.url, contains('/resolve/main/'));
      }
    });
  });

  group('AiRouter.tierFor', () {
    test('hints/mnemonic/confusion are localOnly', () {
      expect(AiRouter.tierFor(AiTaskType.reviewHint), AiTaskTier.localOnly);
      expect(AiRouter.tierFor(AiTaskType.mnemonic), AiTaskTier.localOnly);
      expect(
        AiRouter.tierFor(AiTaskType.confusionDiagnosis),
        AiTaskTier.localOnly,
      );
    });

    test('example/photo import/speaking score are localPreferred', () {
      expect(
        AiRouter.tierFor(AiTaskType.exampleSentence),
        AiTaskTier.localPreferred,
      );
      expect(
        AiRouter.tierFor(AiTaskType.photoImport),
        AiTaskTier.localPreferred,
      );
      expect(
        AiRouter.tierFor(AiTaskType.speakingScore),
        AiTaskTier.localPreferred,
      );
    });

    test('conversation turn is cloudPreferred', () {
      expect(
        AiRouter.tierFor(AiTaskType.conversationTurn),
        AiTaskTier.cloudPreferred,
      );
    });
  });

  group('AiRouter.route', () {
    final androidReady = AiCapability.resolve(
      platform: AiPlatform.android,
      totalRamMb: 8000,
    );
    final lowEnd = AiCapability.resolve(
      platform: AiPlatform.android,
      totalRamMb: 1500,
    );

    AiRouteDecision routeHint({
      required AiCapability cap,
      required bool localReady,
      bool online = true,
      bool privacy = false,
      bool cloud = true,
    }) => AiRouter.route(
      type: AiTaskType.reviewHint,
      capability: cap,
      localModelReady: localReady,
      online: online,
      privacyMode: privacy,
      cloudConfigured: cloud,
    );

    test('localOnly task uses local when model ready', () {
      final d = routeHint(cap: androidReady, localReady: true);
      expect(d.target, AiRouteTarget.local);
    });

    test('localOnly task never falls back to cloud', () {
      final d = routeHint(cap: androidReady, localReady: false);
      expect(d.target, AiRouteTarget.unavailable);
    });

    test('privacy mode forbids cloud for localPreferred task', () {
      final d = AiRouter.route(
        type: AiTaskType.photoImport,
        capability: androidReady,
        localModelReady: false,
        online: true,
        privacyMode: true,
        cloudConfigured: true,
      );
      expect(d.target, AiRouteTarget.unavailable);
    });

    test('localPreferred falls back to cloud when local missing', () {
      final d = AiRouter.route(
        type: AiTaskType.photoImport,
        capability: lowEnd,
        localModelReady: false,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(d.target, AiRouteTarget.cloud);
    });

    test('localPreferred is unavailable when offline and no local model', () {
      final d = AiRouter.route(
        type: AiTaskType.photoImport,
        capability: lowEnd,
        localModelReady: false,
        online: false,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(d.target, AiRouteTarget.unavailable);
    });

    test('cloudPreferred uses cloud when online', () {
      final d = AiRouter.route(
        type: AiTaskType.conversationTurn,
        capability: androidReady,
        localModelReady: true,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(d.target, AiRouteTarget.cloud);
    });

    test('cloudPreferred falls back to local when offline', () {
      final d = AiRouter.route(
        type: AiTaskType.conversationTurn,
        capability: androidReady,
        localModelReady: true,
        online: false,
        privacyMode: false,
        cloudConfigured: true,
      );
      expect(d.target, AiRouteTarget.local);
    });

    test('iOS Apple FM counts as local-capable', () {
      final ios = AiCapability.resolve(
        platform: AiPlatform.ios,
        appleFoundationModels: true,
      );
      final d = routeHint(cap: ios, localReady: true);
      expect(d.target, AiRouteTarget.local);
    });
  });
}
