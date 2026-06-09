import 'package:recall_app/services/ai/ai_quota_service.dart';
import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/ai_analytics_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tasks the Flutter client currently dispatches through the server proxy.
///
/// The edge function may *accept* more task types, but only these have a client
/// call site today. Routing uses this so a signed-in (keyless) user is treated
/// as cloud-capable only for tasks that actually have a proxy path.
const Set<AiTaskType> proxyBackedTasks = {
  AiTaskType.smartDistractors,
  AiTaskType.exampleSentence,
  AiTaskType.photoImport,
  AiTaskType.cardLookup,
};

/// Client for Grasp's server-side AI proxy.
///
/// This class intentionally has no API-key parameter. Owner-funded provider
/// keys must live only in Supabase Edge Function secrets (for example
/// `GRASP_GROQ_API_KEY`). User-supplied BYO keys should continue through the
/// existing direct Gemini/Groq clients and local secure storage.
class AiProxyClient {
  AiProxyClient({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabase {
    if (_client != null) return _client;
    try {
      return Supabase.instance.client;
    } catch (_) {
      throw ScanException(
        ScanFailureReason.authError,
        'Supabase is not configured.',
      );
    }
  }

  Future<AiProxyResponse> complete({
    required AiTaskType taskType,
    required List<AiProxyMessage> messages,
    String? model,
    double temperature = 0.3,
    int? maxTokens,
  }) async {
    final startedAt = DateTime.now();
    if (messages.isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'AI proxy messages are required.',
      );
    }

    try {
      await _ensureValidSession();
      final response = await _supabase.functions.invoke(
        'ai-proxy',
        body: {
          'taskType': taskType.name,
          'messages': messages.map((m) => m.toJson()).toList(growable: false),
          if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
          'temperature': temperature,
          if (maxTokens != null) 'maxTokens': maxTokens,
        },
      );

      final data = response.data;
      if (data is! Map) {
        throw ScanException(
          ScanFailureReason.parseError,
          'Invalid AI proxy response.',
        );
      }
      final parsed = AiProxyResponse.fromJson(Map<String, dynamic>.from(data));
      await _recordUsage(taskType, parsed, DateTime.now().difference(startedAt));
      return parsed;
    } on FunctionException catch (e) {
      throw ScanException(_reasonForStatus(e.status), _messageForFunction(e));
    } on ScanException {
      rethrow;
    } catch (e) {
      final reason = AiErrorClassifier.classifySdkError(e.toString());
      throw ScanException(reason, 'AI proxy request failed.');
    }
  }

  Future<void> _recordUsage(
    AiTaskType taskType,
    AiProxyResponse response,
    Duration elapsed,
  ) async {
    await AiAnalyticsService().logEvent(
      taskType: taskType,
      provider: response.provider,
      success: true,
      elapsed: elapsed,
      inputTokens: response.inputTokens,
      outputTokens: response.outputTokens,
    );
    await AiQuotaService().recordServerUsage(taskType);
  }

  Future<void> _ensureValidSession() async {
    final session = _supabase.auth.currentSession;
    if (session == null) {
      throw ScanException(
        ScanFailureReason.authError,
        'Sign in required.',
      );
    }
    if (!session.isExpired) return;

    try {
      final refreshed = await _supabase.auth.refreshSession();
      if (refreshed.session == null) {
        throw ScanException(
          ScanFailureReason.authError,
          'Invalid session.',
        );
      }
    } on ScanException {
      rethrow;
    } catch (_) {
      throw ScanException(
        ScanFailureReason.authError,
        'Invalid session.',
      );
    }
  }

  ScanFailureReason _reasonForStatus(int? status) {
    if (status == null) return ScanFailureReason.unknown;
    return AiErrorClassifier.classifyHttpError(status, '');
  }

  String _messageForFunction(FunctionException e) {
    final details = e.details;
    if (details is Map) {
      final message = details['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.trim();
      }
    }
    return e.reasonPhrase ?? 'AI proxy request failed.';
  }
}

enum AiProxyRole { system, user, assistant }

class AiProxyMessage {
  const AiProxyMessage({required this.role, required this.content});

  final AiProxyRole role;
  final String content;

  Map<String, dynamic> toJson() => {'role': role.name, 'content': content};
}

class AiProxyResponse {
  const AiProxyResponse({
    required this.text,
    required this.provider,
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String text;
  final String provider;
  final String model;
  final int inputTokens;
  final int outputTokens;

  factory AiProxyResponse.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String || text.trim().isEmpty) {
      throw ScanException(
        ScanFailureReason.parseError,
        'AI proxy returned empty text.',
      );
    }

    return AiProxyResponse(
      text: text,
      provider: _string(json['provider'], fallback: 'grasp-cloud'),
      model: _string(json['model'], fallback: 'unknown'),
      inputTokens: _int(json['inputTokens']),
      outputTokens: _int(json['outputTokens']),
    );
  }

  static String _string(Object? value, {required String fallback}) {
    if (value is! String) return fallback;
    final trimmed = value.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  static int _int(Object? value) {
    if (value is num) return value.toInt().clamp(0, 1 << 31);
    return 0;
  }
}
