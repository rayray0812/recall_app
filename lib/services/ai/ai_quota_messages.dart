import 'package:recall_app/services/ai/ai_entitlement.dart';
import 'package:recall_app/services/ai_error.dart';

/// User-facing copy for "you've hit today's cloud-AI quota" situations (§2.6).
///
/// Kept separate from the provider-rate-limit message (`scanQuotaExceeded`):
/// that one means the *cloud provider* throttled the user's own key, whereas
/// this means *our* daily free allowance for the plan is spent — so the right
/// nudge is to upgrade (or wait for tomorrow), not to slow down.
String aiQuotaUpgradeMessage(AiEntitlement entitlement) {
  return switch (entitlement) {
    AiEntitlement.free =>
      '今日免費 AI 額度已用完，升級 Plus 解鎖更多用量；額度每天會重置。',
    AiEntitlement.plus => '今日 AI 額度已用完，明天會重置。',
    AiEntitlement.proAi || AiEntitlement.classroom => '今日 AI 額度已用完。',
  };
}

/// Thrown when a metered cloud-AI task is blocked by the daily quota (not by a
/// provider rate-limit). Subclasses [ScanException] so existing
/// `on ScanException` handlers still catch it, but lets the UI show the
/// upgrade-oriented [message] instead of the generic quota copy.
class AiQuotaExceededException extends ScanException {
  AiQuotaExceededException(this.entitlement, String message)
      : super(ScanFailureReason.quotaExceeded, message);

  final AiEntitlement entitlement;
}
