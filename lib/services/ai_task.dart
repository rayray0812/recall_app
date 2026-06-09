import 'package:recall_app/services/ai_error.dart';

/// The type of AI operation.
enum AiTaskType {
  photoImport,
  conversationTurn,
  speakingScore,
  // Local-AI tasks (on-device):
  reviewHint, // L1
  mnemonic, // L2
  confusionDiagnosis, // L3
  exampleSentence, // example-sentence generation for a vocab card
  smartDistractors, // plausible wrong options for multiple-choice quiz
  cardLookup, // auto-fill a card (definition + part of speech + example) from a term
}

/// Lifecycle state of an AI operation.
///
/// All AI-driven modes (photo import, conversation, G1 embedding) represent
/// their in-flight state with this sealed class so the UI layer stays uniform.
sealed class AiTaskState<T> {
  const AiTaskState();
}

/// No AI operation is in progress.
class AiTaskIdle<T> extends AiTaskState<T> {
  const AiTaskIdle();
}

/// An AI operation is running. [hint] is a short UI-facing progress label.
class AiTaskRunning<T> extends AiTaskState<T> {
  final String hint;
  const AiTaskRunning({this.hint = ''});
}

/// The AI operation completed successfully with [result].
class AiTaskDone<T> extends AiTaskState<T> {
  final T result;
  final Duration elapsed;
  const AiTaskDone(this.result, {required this.elapsed});
}

/// The AI operation failed.
class AiTaskError<T> extends AiTaskState<T> {
  final ScanFailureReason reason;
  final String message;
  final Duration elapsed;
  const AiTaskError({
    required this.reason,
    required this.message,
    required this.elapsed,
  });
}

/// Descriptor for a pending or completed AI operation.
///
/// Carry this alongside the result so analytics and error reporting know
/// which task type and provider produced the event.
class AiTask {
  final AiTaskType type;
  final String provider; // 'gemini' | 'groq' | 'gemma'
  final DateTime startedAt;

  const AiTask({
    required this.type,
    required this.provider,
    required this.startedAt,
  });

  Duration get elapsed => DateTime.now().toUtc().difference(startedAt);
}
