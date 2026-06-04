import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/services/ai_error.dart';

/// [ConversationEngine] backed by the Gemini generative AI SDK.
///
/// Stateless: every call rebuilds the full history as [Content] and calls
/// `generateContent` (rather than a stateful `ChatSession`) so it shares the
/// same contract as the Groq engine and can be swapped freely by
/// [FallbackConversationEngine]. Uses `gemini-2.0-flash` (not flash-lite) for
/// noticeably more natural dialogue.
class GeminiConversationEngine implements ConversationEngine {
  GeminiConversationEngine({required this.apiKey, this.model = defaultModel});

  static const String defaultModel = 'gemini-2.0-flash';

  final String apiKey;
  final String model;

  @override
  String get name => 'gemini';

  @override
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) async {
    try {
      final gm = GenerativeModel(
        model: model,
        apiKey: apiKey,
        systemInstruction: Content.system(systemPrompt),
        generationConfig: GenerationConfig(
          temperature: 0.7,
          maxOutputTokens: 220,
        ),
      );
      final resp = await gm.generateContent(buildContents(history, userMessage));
      final text = (resp.text ?? '').trim();
      if (text.isEmpty) {
        throw ConversationEngineException(
          ScanFailureReason.parseError,
          'Empty Gemini response',
        );
      }
      return text;
    } on ConversationEngineException {
      rethrow;
    } catch (e) {
      throw ConversationEngineException(
        AiErrorClassifier.classifySdkError(e.toString()),
        e.toString(),
      );
    }
  }

  /// Map history + latest user message into Gemini [Content]. Pure — visible for
  /// testing. Falls back to a kickoff turn when there is nothing to send.
  static List<Content> buildContents(
    List<ConversationMessage> history,
    String userMessage,
  ) {
    final contents = <Content>[
      for (final m in history)
        if (m.isUser) Content.text(m.text) else Content.model([TextPart(m.text)]),
    ];
    if (userMessage.trim().isNotEmpty) {
      contents.add(Content.text(userMessage.trim()));
    }
    if (contents.isEmpty) {
      contents.add(Content.text('Begin the conversation.'));
    }
    return contents;
  }
}
