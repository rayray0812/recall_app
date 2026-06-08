import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/features/study/services/gemini_conversation_engine.dart';
import 'package:recall_app/features/study/services/groq_conversation_engine.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// Builds the conversation engine from the user's provider choice + configured
/// keys, with the *other* cloud provider as automatic fallback when its key is
/// present (so a rate-limited primary hands off instead of dropping to canned
/// replies). Returns null when no cloud key is configured at all.
final conversationEngineProvider = Provider<ConversationEngine?>((ref) {
  final provider = ref.watch(aiProviderProvider);
  final geminiKey = ref.watch(geminiKeyProvider).trim();
  final groqKey = ref.watch(groqKeyProvider).trim();

  final gemini = geminiKey.isNotEmpty
      ? GeminiConversationEngine(apiKey: geminiKey)
      : null;
  final groq = groqKey.isNotEmpty
      ? GroqConversationEngine(apiKey: groqKey)
      : null;

  // Order by user preference; on-device ('gemma') has no cloud chat, so it just
  // uses whatever cloud keys exist (Gemini first by default).
  final ordered = <ConversationEngine>[];
  if (provider == AiProvider.groq) {
    if (groq != null) ordered.add(groq);
    if (gemini != null) ordered.add(gemini);
  } else {
    if (gemini != null) ordered.add(gemini);
    if (groq != null) ordered.add(groq);
  }

  if (ordered.isEmpty) return null;
  // Always wrap (even a single engine) so every provider dispatch is logged as
  // its own usage event — keeping cost accounting accurate under failover
  // (docs §2.6). The engine stays storage-agnostic; we log here.
  return FallbackConversationEngine(
    ordered,
    onAttempt: (a) {
      AiAnalyticsService().logEvent(
        taskType: AiTaskType.conversationTurn,
        provider: a.provider,
        success: a.success,
        elapsed: a.elapsed,
        failureReason: a.failureReason,
        inputTokens: a.inputTokens,
        outputTokens: a.outputTokens,
      );
    },
  );
});
