import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// Cloud text-completion via Groq's OpenAI-compatible chat API.
///
/// Used for high-frequency AI tasks that were re-routed *off-device* for
/// battery/heat reasons (see docs/ai_roadmap_status.md §2.5). The first such
/// task is smart quiz distractors: triggered automatically on every
/// multiple-choice question, so running it on a small local model every time is
/// the highest power-drain risk. Cloud (free Groq) keeps the phone cool; the
/// on-device engine remains the offline/privacy fallback via [AiRouter].
///
/// Body building and response parsing are pure statics (mirroring
/// [GroqConversationEngine]) so they are unit-testable without the network, and
/// the prompt/parse logic is shared with [LocalAiService] so local and cloud
/// produce identically-shaped options.
class GroqCompletionService {
  GroqCompletionService({
    required this.apiKey,
    this.model = defaultModel,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Llama 3.3 70B — strong, free on Groq, good for short structured output.
  static const String defaultModel = 'llama-3.3-70b-versatile';
  static const String _endpoint =
      'https://api.groq.com/openai/v1/chat/completions';
  static const Duration _timeout = Duration(seconds: 20);

  final String apiKey;
  final String model;
  final http.Client _client;

  String get name => 'groq';

  /// Cloud counterpart of [LocalAiService.generateDistractors]. Reuses the same
  /// prompt builder and parser so the options are shaped identically to the
  /// on-device path. Returns null on any failure or too-few usable options, so
  /// the caller keeps its random-card baseline. Logs to [AiAnalyticsService]
  /// just like the local path.
  Future<List<String>?> generateDistractors({
    required String term,
    required String definition,
    required String correctOption,
    required bool reversed,
    int count = 3,
  }) async {
    final task = AiTask(
      type: AiTaskType.smartDistractors,
      provider: name,
      startedAt: DateTime.now().toUtc(),
    );
    final analytics = AiAnalyticsService();
    try {
      final prompt = LocalAiService.buildDistractorsPrompt(
        term: term,
        definition: definition,
        correctOption: correctOption,
        reversed: reversed,
        count: count,
      );
      final raw = await _complete(prompt: prompt, temperature: 0.8, maxTokens: 160);
      final list =
          LocalAiService.parseDistractorLines(raw, exclude: correctOption, max: count);
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: true,
        elapsed: task.elapsed,
      );
      return list.length >= count ? list : null;
    } catch (e) {
      final reason = e is ScanException
          ? e.reason
          : AiErrorClassifier.classifySdkError(e.toString());
      analytics.logEvent(
        taskType: task.type,
        provider: task.provider,
        success: false,
        elapsed: task.elapsed,
        failureReason: reason,
      );
      debugPrint('GroqCompletionService.generateDistractors failed: $e');
      return null;
    }
  }

  /// Send a single-prompt completion and return the assistant text.
  /// Throws [ScanException] with a structured reason on any non-200/timeout.
  Future<String> _complete({
    required String prompt,
    double temperature = 0.8,
    int maxTokens = 160,
  }) async {
    final body = jsonEncode(
      buildBody(
        model: model,
        prompt: prompt,
        temperature: temperature,
        maxTokens: maxTokens,
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
        // Classify using the body, but don't put the raw body in the message —
        // it can end up in debug logs and may contain sensitive content.
        throw ScanException(
          AiErrorClassifier.classifyHttpError(resp.statusCode, resp.body),
          'Groq error ${resp.statusCode}',
        );
      }
      return parseContent(resp.body);
    } on ScanException {
      rethrow;
    } on TimeoutException {
      throw ScanException(ScanFailureReason.timeout, 'Groq request timed out');
    }
  }

  /// Build the OpenAI-compatible request body for a single user prompt.
  /// Pure — visible for testing.
  static Map<String, dynamic> buildBody({
    required String model,
    required String prompt,
    double temperature = 0.8,
    int maxTokens = 160,
  }) {
    return {
      'model': model,
      'messages': [
        {'role': 'user', 'content': prompt},
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
    };
  }

  /// Extract the assistant message text from a Groq chat completion body.
  /// Pure — returns '' on any malformed/empty response.
  static String parseContent(String responseBody) {
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
