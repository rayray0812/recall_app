import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_entitlement_service.dart';

void main() {
  group('AiEntitlementService.parseTier', () {
    test('maps database tier names to app entitlement enum', () {
      expect(AiEntitlementService.parseTier('free'), AiEntitlement.free);
      expect(AiEntitlementService.parseTier('plus'), AiEntitlement.plus);
      expect(AiEntitlementService.parseTier('pro_ai'), AiEntitlement.proAi);
      expect(
        AiEntitlementService.parseTier('classroom'),
        AiEntitlement.classroom,
      );
    });

    test('fails closed to free for unknown or empty tier names', () {
      expect(AiEntitlementService.parseTier(null), AiEntitlement.free);
      expect(AiEntitlementService.parseTier(''), AiEntitlement.free);
      expect(AiEntitlementService.parseTier('proAi'), AiEntitlement.free);
      expect(AiEntitlementService.parseTier('admin'), AiEntitlement.free);
    });
  });

  group('AiEntitlementService.isExpired', () {
    test('treats null expiration as active', () {
      expect(AiEntitlementService.isExpired(null), isFalse);
    });

    test('expires at or before now', () {
      final now = DateTime.utc(2026, 6, 8, 12);

      expect(AiEntitlementService.isExpired(now, now: now), isTrue);
      expect(
        AiEntitlementService.isExpired(
          now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
      expect(
        AiEntitlementService.isExpired(
          now.add(const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
