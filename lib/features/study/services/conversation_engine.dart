import 'package:recall_app/services/ai_error.dart';

/// One message in a conversation history (role + text). Provider-agnostic so the
/// same history can be sent to any [ConversationEngine].
class ConversationMessage {
  final bool isUser;
  final String text;
  const ConversationMessage({required this.isUser, required this.text});
}

/// Structured failure from a conversation engine, carrying a [ScanFailureReason]
/// so callers (and [FallbackConversationEngine]) can decide whether to retry on
/// another provider.
class ConversationEngineException implements Exception {
  final ScanFailureReason reason;
  final String message;

  ConversationEngineException(this.reason, this.message);

  bool get isRateLimit => AiErrorClassifier.isRateLimit(reason);

  @override
  String toString() => 'ConversationEngineException($reason): $message';
}

/// A stateless cloud conversation backend. Each call sends the full prior
/// [history] plus the latest [userMessage] (empty for the opening turn), so the
/// same abstraction works for Gemini and Groq (which has no stateful chat).
abstract class ConversationEngine {
  /// Short provider label for analytics / logging (e.g. 'gemini', 'groq').
  String get name;

  /// Produce the assistant's next message. Throws [ConversationEngineException]
  /// on any failure.
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  });
}

/// Tries each engine in order; on any failure it falls through to the next, so a
/// rate-limited or erroring primary provider transparently hands off to the
/// secondary. This replaces the old "drop to canned local coach" path as the
/// first line of defence. Throws the last error only when *all* engines fail.
class FallbackConversationEngine implements ConversationEngine {
  final List<ConversationEngine> engines;

  FallbackConversationEngine(this.engines)
      : assert(engines.isNotEmpty, 'need at least one engine');

  @override
  String get name => engines.map((e) => e.name).join('+');

  @override
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) async {
    ConversationEngineException? last;
    for (final engine in engines) {
      try {
        return await engine.generateTurn(
          systemPrompt: systemPrompt,
          history: history,
          userMessage: userMessage,
        );
      } on ConversationEngineException catch (e) {
        last = e;
        // try the next provider
      }
    }
    throw last ??
        ConversationEngineException(
          ScanFailureReason.unknown,
          'No conversation engine available',
        );
  }
}
