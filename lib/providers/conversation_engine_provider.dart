import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/features/study/services/gemini_conversation_engine.dart';
import 'package:recall_app/features/study/services/groq_conversation_engine.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_task.dart';

/// Builds the conversation engine from the user's single AI mode.
///
/// App remote conversation is not proxied yet, and local Gemma has no chat
/// engine here, so both return null instead of silently falling back to BYO
/// keys. That keeps Settings honest: the selected mode is the mode that runs.
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

  final ordered = switch (provider) {
    AiProvider.gemini => [if (gemini != null) gemini],
    AiProvider.groq => [if (groq != null) groq],
    AiProvider.appRemote || AiProvider.gemma => <ConversationEngine>[],
  };

  if (ordered.isEmpty) return null;
  // Always wrap (even a single engine) so every provider dispatch is logged as
  // its own usage event — keeping cost accounting accurate under failover
  // (docs §2.6). The engine stays storage-agnostic; we log here.
  final engine = FallbackConversationEngine(
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
  // This provider rebuilds whenever the AI provider choice or a key changes;
  // close the superseded engines' HTTP clients instead of leaking them.
  ref.onDispose(engine.close);
  return engine;
});
