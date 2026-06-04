import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/services/ai_error.dart';

/// [ConversationEngine] backed by Groq's OpenAI-compatible chat completions API.
/// Free tier, low latency. Body building and response parsing are split into
/// pure static methods (mirroring [GroqVisionService]) so they are unit-testable
/// without the network.
class GroqConversationEngine implements ConversationEngine {
  GroqConversationEngine({
    required this.apiKey,
    this.model = defaultModel,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Llama 3.3 70B — strong, free on Groq, good for natural dialogue.
  static const String defaultModel = 'llama-3.3-70b-versatile';
  static const String _endpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const Duration _timeout = Duration(seconds: 30);

  final String apiKey;
  final String model;
  final http.Client _client;

  @override
  String get name => 'groq';

  @override
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) async {
    final body = jsonEncode(
      buildChatBody(
        model: model,
        systemPrompt: systemPrompt,
        history: history,
        userMessage: userMessage,
      ),
    );
    try {
      final resp = await _client
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        throw ConversationEngineException(
          AiErrorClassifier.classifyHttpError(resp.statusCode, resp.body),
          'Groq error ${resp.statusCode}: ${resp.body}',
        );
      }
      final text = parseChatContent(resp.body);
      if (text.isEmpty) {
        throw ConversationEngineException(
          ScanFailureReason.parseError,
          'Empty Groq response',
        );
      }
      return text;
    } on ConversationEngineException {
      rethrow;
    } on TimeoutException {
      throw ConversationEngineException(
        ScanFailureReason.timeout,
        'Groq request timed out',
      );
    } catch (e) {
      throw ConversationEngineException(
        ScanFailureReason.networkError,
        e.toString(),
      );
    }
  }

  /// Build the OpenAI-compatible request body. Pure — visible for testing.
  ///
  /// Guarantees at least one non-system message (a kickoff "Begin…" user line)
  /// so the opening turn (empty history + empty userMessage) is still valid.
  static Map<String, dynamic> buildChatBody({
    required String model,
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      for (final m in history)
        {'role': m.isUser ? 'user' : 'assistant', 'content': m.text},
    ];
    if (userMessage.trim().isNotEmpty) {
      messages.add({'role': 'user', 'content': userMessage.trim()});
    }
    if (messages.length == 1) {
      messages.add({'role': 'user', 'content': 'Begin the conversation.'});
    }
    return {
      'model': model,
      'messages': messages,
      'temperature': 0.7,
      'max_tokens': 220,
    };
  }

  /// Extract the assistant message text from a Groq chat completion body.
  /// Pure — returns '' on any malformed/empty response.
  static String parseChatContent(String responseBody) {
    try {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return '';
      final message = choices[0]['message'] as Map<String, dynamic>?;
      return (message?['content']?.toString() ?? '').trim();
    } catch (_) {
      return '';
    }
  }
}
