import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai/ai_quota_messages.dart';
import 'package:recall_app/services/ai_error.dart';

void main() {
  group('aiQuotaUpgradeMessage', () {
    test('free tier nudges an upgrade', () {
      final msg = aiQuotaUpgradeMessage(AiEntitlement.free);
      expect(msg, contains('Plus'));
      expect(msg, isNotEmpty);
    });

    test('paid tiers do not push an upgrade (just inform)', () {
      expect(aiQuotaUpgradeMessage(AiEntitlement.plus), isNot(contains('升級')));
      expect(aiQuotaUpgradeMessage(AiEntitlement.proAi), isNotEmpty);
      expect(aiQuotaUpgradeMessage(AiEntitlement.classroom), isNotEmpty);
    });

    test('every tier returns a non-empty message', () {
      for (final e in AiEntitlement.values) {
        expect(aiQuotaUpgradeMessage(e), isNotEmpty, reason: e.name);
      }
    });
  });

  group('AiQuotaExceededException', () {
    test('is a ScanException with quotaExceeded reason + carries entitlement',
        () {
      final ex = AiQuotaExceededException(
        AiEntitlement.free,
        aiQuotaUpgradeMessage(AiEntitlement.free),
      );
      expect(ex, isA<ScanException>());
      expect(ex.reason, ScanFailureReason.quotaExceeded);
      expect(ex.entitlement, AiEntitlement.free);
      expect(ex.toString(), contains('Plus'));
    });
  });
}
