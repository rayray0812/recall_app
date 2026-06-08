import 'package:recall_app/services/ai/ai_token_estimator.dart';
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

  /// Release any owned resources (e.g. an HTTP client). Default no-op for
  /// engines that hold nothing (e.g. the SDK-backed Gemini engine).
  void close() {}
}

/// One provider dispatch within [FallbackConversationEngine], reported to
/// [FallbackConversationEngine.onAttempt] so the caller can record accurate
/// per-provider cost telemetry (a single product turn may dispatch >1 provider
/// on failover — see docs §2.6). Token counts are rough estimates.
class ConversationAttempt {
  final String provider;
  final bool success;
  final ScanFailureReason? failureReason;
  final Duration elapsed;
  final int inputTokens;
  final int outputTokens;

  const ConversationAttempt({
    required this.provider,
    required this.success,
    required this.elapsed,
    required this.inputTokens,
    this.failureReason,
    this.outputTokens = 0,
  });
}

typedef ConversationAttemptCallback = void Function(ConversationAttempt attempt);

/// Tries each engine in order; on any failure it falls through to the next, so a
/// rate-limited or erroring primary provider transparently hands off to the
/// secondary. This replaces the old "drop to canned local coach" path as the
/// first line of defence. Throws the last error only when *all* engines fail.
///
/// [onAttempt] fires once per actual provider dispatch (success or failure), so
/// callers can log a provider-level usage event for *each* call — not just one
/// per product turn — keeping cost accounting honest under failover. The engine
/// itself stays free of any analytics/storage dependency.
class FallbackConversationEngine implements ConversationEngine {
  final List<ConversationEngine> engines;
  final ConversationAttemptCallback? onAttempt;

  FallbackConversationEngine(this.engines, {this.onAttempt})
      : assert(engines.isNotEmpty, 'need at least one engine');

  @override
  String get name => engines.map((e) => e.name).join('+');

  @override
  void close() {
    for (final engine in engines) {
      engine.close();
    }
  }

  @override
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) async {
    final inputTokens = AiTokenEstimator.estimateAll([
      systemPrompt,
      for (final m in history) m.text,
      userMessage,
    ]);
    ConversationEngineException? last;
    for (final engine in engines) {
      final startedAt = DateTime.now().toUtc();
      try {
        final text = await engine.generateTurn(
          systemPrompt: systemPrompt,
          history: history,
          userMessage: userMessage,
        );
        onAttempt?.call(ConversationAttempt(
          provider: engine.name,
          success: true,
          elapsed: DateTime.now().toUtc().difference(startedAt),
          inputTokens: inputTokens,
          outputTokens: AiTokenEstimator.estimate(text),
        ));
        return text;
      } on ConversationEngineException catch (e) {
        last = e;
        onAttempt?.call(ConversationAttempt(
          provider: engine.name,
          success: false,
          failureReason: e.reason,
          elapsed: DateTime.now().toUtc().difference(startedAt),
          inputTokens: inputTokens,
        ));
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
