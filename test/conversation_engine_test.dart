import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/study/services/conversation_engine.dart';
import 'package:recall_app/features/study/services/gemini_conversation_engine.dart';
import 'package:recall_app/features/study/services/groq_conversation_engine.dart';
import 'package:recall_app/services/ai_error.dart';

/// Fake engine: returns [reply] or throws [error].
class _FakeEngine implements ConversationEngine {
  _FakeEngine(this._name, {this.reply, this.error});
  final String _name;
  final String? reply;
  final ConversationEngineException? error;
  int calls = 0;

  @override
  String get name => _name;

  @override
  Future<String> generateTurn({
    required String systemPrompt,
    required List<ConversationMessage> history,
    String userMessage = '',
  }) async {
    calls++;
    if (error != null) throw error!;
    return reply!;
  }
}

void main() {
  group('GroqConversationEngine.buildChatBody', () {
    test('prepends system and maps history roles', () {
      final body = GroqConversationEngine.buildChatBody(
        model: 'm',
        systemPrompt: 'sys',
        history: const [
          ConversationMessage(isUser: false, text: 'hello'),
          ConversationMessage(isUser: true, text: 'hi there'),
        ],
        userMessage: 'next',
      );
      final msgs = body['messages'] as List;
      expect(msgs.first, {'role': 'system', 'content': 'sys'});
      expect(msgs[1], {'role': 'assistant', 'content': 'hello'});
      expect(msgs[2], {'role': 'user', 'content': 'hi there'});
      expect(msgs.last, {'role': 'user', 'content': 'next'});
      expect(body['model'], 'm');
    });

    test('opening turn (no history, no user) still has a user kickoff', () {
      final body = GroqConversationEngine.buildChatBody(
        model: 'm',
        systemPrompt: 'sys',
        history: const [],
      );
      final msgs = body['messages'] as List;
      expect(msgs.length, 2);
      expect(msgs.last['role'], 'user');
    });

    test('blank userMessage is not appended', () {
      final body = GroqConversationEngine.buildChatBody(
        model: 'm',
        systemPrompt: 'sys',
        history: const [ConversationMessage(isUser: true, text: 'x')],
        userMessage: '   ',
      );
      final msgs = body['messages'] as List;
      expect(msgs.length, 2); // system + the one history user msg
    });
  });

  group('GroqConversationEngine.parseChatContent', () {
    test('extracts assistant content', () {
      final body = jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '  Sure, what next?  '},
          },
        ],
      });
      expect(GroqConversationEngine.parseChatContent(body), 'Sure, what next?');
    });

    test('empty choices → empty string', () {
      expect(
        GroqConversationEngine.parseChatContent('{"choices":[]}'),
        '',
      );
    });

    test('malformed JSON → empty string', () {
      expect(GroqConversationEngine.parseChatContent('not json'), '');
    });
  });

  group('GeminiConversationEngine.buildContents', () {
    test('maps roles and appends user message', () {
      final contents = GeminiConversationEngine.buildContents(
        const [
          ConversationMessage(isUser: false, text: 'q1'),
          ConversationMessage(isUser: true, text: 'a1'),
        ],
        'a2',
      );
      expect(contents.length, 3);
      expect(contents[0].role, 'model');
      expect(contents[1].role, 'user');
      expect(contents[2].role, 'user');
    });

    test('empty history + empty message → single kickoff content', () {
      final contents = GeminiConversationEngine.buildContents(const [], '');
      expect(contents.length, 1);
      expect(contents.first.role, 'user');
    });
  });

  group('FallbackConversationEngine', () {
    Future<String> run(FallbackConversationEngine e) => e.generateTurn(
          systemPrompt: 's',
          history: const [],
        );

    test('returns the primary result without calling the secondary', () async {
      final primary = _FakeEngine('p', reply: 'PRIMARY');
      final secondary = _FakeEngine('s', reply: 'SECONDARY');
      final engine = FallbackConversationEngine([primary, secondary]);
      expect(await run(engine), 'PRIMARY');
      expect(secondary.calls, 0);
    });

    test('falls through to secondary when primary rate-limits', () async {
      final primary = _FakeEngine(
        'p',
        error: ConversationEngineException(
          ScanFailureReason.quotaExceeded,
          '429',
        ),
      );
      final secondary = _FakeEngine('s', reply: 'SECONDARY');
      final engine = FallbackConversationEngine([primary, secondary]);
      expect(await run(engine), 'SECONDARY');
      expect(primary.calls, 1);
      expect(secondary.calls, 1);
    });

    test('throws the last error when all engines fail', () async {
      final primary = _FakeEngine(
        'p',
        error: ConversationEngineException(ScanFailureReason.networkError, 'net'),
      );
      final secondary = _FakeEngine(
        's',
        error: ConversationEngineException(ScanFailureReason.serverError, '500'),
      );
      final engine = FallbackConversationEngine([primary, secondary]);
      await expectLater(
        run(engine),
        throwsA(
          isA<ConversationEngineException>().having(
            (e) => e.reason,
            'reason',
            ScanFailureReason.serverError,
          ),
        ),
      );
    });

    test('name joins member engine names', () {
      final engine = FallbackConversationEngine(
        [_FakeEngine('gemini', reply: 'x'), _FakeEngine('groq', reply: 'y')],
      );
      expect(engine.name, 'gemini+groq');
    });
  });
}
