import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_capability_service.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai/device_power_policy.dart';
import 'package:recall_app/services/ai_task.dart';

void main() {
  group('DevicePowerPolicy.allowsLocalInference', () {
    bool allows({
      required int level,
      required bool charging,
      required bool saveMode,
    }) {
      return DevicePowerPolicy.allowsLocalInference(
        DevicePowerSnapshot(
          batteryLevel: level,
          isCharging: charging,
          batterySaveMode: saveMode,
        ),
      );
    }

    test('blocks when battery-saver is on, regardless of level', () {
      expect(allows(level: 95, charging: true, saveMode: true), isFalse);
    });

    test('blocks when battery low and not charging', () {
      expect(allows(level: 15, charging: false, saveMode: false), isFalse);
      expect(
        allows(
          level: DevicePowerPolicy.lowBatteryThreshold,
          charging: false,
          saveMode: false,
        ),
        isFalse,
      );
    });

    test('allows when battery low but charging', () {
      expect(allows(level: 10, charging: true, saveMode: false), isTrue);
    });

    test('allows on healthy battery', () {
      expect(allows(level: 80, charging: false, saveMode: false), isTrue);
    });

    test('unknown battery (-1) is treated as fine', () {
      expect(allows(level: -1, charging: false, saveMode: false), isTrue);
    });

    test('unknown snapshot fallback allows', () {
      expect(
        DevicePowerPolicy.allowsLocalInference(DevicePowerSnapshot.unknown),
        isTrue,
      );
    });
  });

  group('AiRouter.route respects localInferenceAllowed', () {
    final capability = AiCapability.resolve(
      platform: AiPlatform.android,
      totalRamMb: 8000,
    );

    test('localOnly task becomes unavailable when local inference disallowed',
        () {
      final decision = AiRouter.route(
        type: AiTaskType.reviewHint,
        capability: capability,
        localModelReady: true,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
        localInferenceAllowed: false,
      );
      expect(decision.target, AiRouteTarget.unavailable);
    });

    test('localPreferred falls back to cloud when local disallowed but online',
        () {
      final decision = AiRouter.route(
        type: AiTaskType.photoImport,
        capability: capability,
        localModelReady: true,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
        localInferenceAllowed: false,
      );
      expect(decision.target, AiRouteTarget.cloud);
    });

    test('still routes local when allowed (regression guard)', () {
      final decision = AiRouter.route(
        type: AiTaskType.reviewHint,
        capability: capability,
        localModelReady: true,
        online: true,
        privacyMode: false,
        cloudConfigured: true,
        localInferenceAllowed: true,
      );
      expect(decision.target, AiRouteTarget.local);
    });

    test('privacy mode + local disallowed → unavailable (never goes cloud)',
        () {
      final decision = AiRouter.route(
        type: AiTaskType.reviewHint,
        capability: capability,
        localModelReady: true,
        online: true,
        privacyMode: true,
        cloudConfigured: true,
        localInferenceAllowed: false,
      );
      expect(decision.target, AiRouteTarget.unavailable);
    });
  });
}
