import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai_error.dart';

void main() {
  group('AiProxyResponse', () {
    test('parses valid proxy response', () {
      final response = AiProxyResponse.fromJson({
        'text': 'Use "analyze" when you break a problem into parts.',
        'provider': 'groq',
        'model': 'llama-3.1-8b-instant',
        'inputTokens': 32,
        'outputTokens': 14,
      });

      expect(response.text, contains('analyze'));
      expect(response.provider, 'groq');
      expect(response.model, 'llama-3.1-8b-instant');
      expect(response.inputTokens, 32);
      expect(response.outputTokens, 14);
    });

    test('rejects empty text', () {
      expect(
        () => AiProxyResponse.fromJson({
          'text': ' ',
          'provider': 'groq',
          'model': 'llama-3.1-8b-instant',
        }),
        throwsA(isA<ScanException>()),
      );
    });
  });

  test('proxy message serializes without any api key field', () {
    const message = AiProxyMessage(
      role: AiProxyRole.user,
      content: 'Generate three distractors.',
    );

    expect(message.toJson(), {
      'role': 'user',
      'content': 'Generate three distractors.',
    });
    expect(message.toJson().containsKey('apiKey'), isFalse);
    expect(message.toJson().containsKey('token'), isFalse);
  });
}
