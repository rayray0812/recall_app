import 'package:recall_app/services/ai_error.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tasks the Flutter client currently dispatches through the server proxy.
///
/// The edge function may *accept* more task types, but only these have a client
/// call site today. Routing uses this so a signed-in (keyless) user is treated
/// as cloud-capable only for tasks that actually have a proxy path.
const Set<AiTaskType> proxyBackedTasks = {
  AiTaskType.smartDistractors,
  AiTaskType.exampleSentence,
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
    if (messages.isEmpty) {
      throw ScanException(
        ScanFailureReason.invalidRequest,
        'AI proxy messages are required.',
      );
    }

    try {
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
      return AiProxyResponse.fromJson(Map<String, dynamic>.from(data));
    } on FunctionException catch (e) {
      throw ScanException(_reasonForStatus(e.status), _messageForFunction(e));
    } on ScanException {
      rethrow;
    } catch (e) {
      final reason = AiErrorClassifier.classifySdkError(e.toString());
      throw ScanException(reason, 'AI proxy request failed.');
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
