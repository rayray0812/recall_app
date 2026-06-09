import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai/ai_gateway.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/gemini_service.dart';
import 'package:recall_app/services/groq_completion_service.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// "✨ AI 例句" button for the card editor: generates one example sentence and
/// fills [exampleSentenceController].
///
/// It follows the single AI mode selected in settings: Grasp remote, local
/// model, user's Gemini key, or user's Groq key. Modes are intentionally not
/// mixed so users can reason about privacy and cost.
class AiExampleButton extends ConsumerStatefulWidget {
  const AiExampleButton({
    super.key,
    required this.termController,
    required this.definitionController,
    required this.exampleSentenceController,
  });

  final TextEditingController termController;
  final TextEditingController definitionController;
  final TextEditingController exampleSentenceController;

  @override
  ConsumerState<AiExampleButton> createState() => _AiExampleButtonState();
}

class _AiExampleButtonState extends ConsumerState<AiExampleButton> {
  bool _loading = false;

  Future<void> _generate() async {
    final term = widget.termController.text.trim();
    if (term.isEmpty) {
      _toast('請先輸入單字');
      return;
    }
    setState(() => _loading = true);
    try {
      if (ref.read(aiProviderProvider) == AiProvider.appRemote &&
          ref.read(currentUserProvider) == null) {
        _toast('請先登入，才能使用 Grasp 遠端 AI');
        return;
      }
      final decision = await ref.read(
        aiRouteProvider(AiTaskType.exampleSentence).future,
      );
      final definition = widget.definitionController.text.trim();
      final sentence = await _generateForSelectedMode(
        decision: decision,
        term: term,
        definition: definition,
      );
      if (!mounted) return;
      if (sentence == null || sentence.isEmpty) {
        _toast('AI 沒有回傳可用例句，請再試一次');
        return;
      }
      widget.exampleSentenceController.text = sentence;
    } on ScanException catch (e) {
      debugPrint('AiExampleButton.generate failed: $e');
      _toast(_messageForScanError(e));
    } catch (e) {
      debugPrint('AiExampleButton.generate failed: $e');
      _toast('產生失敗，請再試一次');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _messageForScanError(ScanException error) {
    return switch (error.reason) {
      ScanFailureReason.authError => '登入已失效，請重新登入後再試',
      ScanFailureReason.quotaExceeded => '今日 AI 額度已用完',
      ScanFailureReason.networkError => '網路連線失敗，請確認手機可連到 Supabase',
      ScanFailureReason.invalidRequest => 'AI 請求格式錯誤，請稍後再試',
      ScanFailureReason.serverError => '遠端 AI 服務暫時失敗，請稍後再試',
      ScanFailureReason.parseError => 'AI 回覆格式不正確，請再試一次',
      ScanFailureReason.timeout => 'AI 產生逾時，請再試一次',
      ScanFailureReason.unknown => '產生失敗，請再試一次',
    };
  }

  Future<String?> _generateForSelectedMode({
    required AiRouteDecision decision,
    required String term,
    required String definition,
  }) {
    return switch (ref.read(aiProviderProvider)) {
      AiProvider.appRemote => _generateCloud(
        decision: decision,
        term: term,
        definition: definition,
      ),
      AiProvider.gemma => _generateLocal(
        decision: decision,
        term: term,
        definition: definition,
      ),
      AiProvider.gemini => _generateWithUserGeminiKey(
        term: term,
        definition: definition,
      ),
      AiProvider.groq => _generateWithUserGroqKey(
        term: term,
        definition: definition,
      ),
    };
  }

  Future<String?> _generateLocal({
    required AiRouteDecision decision,
    required String term,
    required String definition,
  }) async {
    if (!decision.isLocal) return null;
    final engine = await ref.read(localLlmEngineProvider.future);
    try {
      return await LocalAiService.generateExampleSentence(
        engine: engine,
        term: term,
        definition: definition,
      );
    } catch (e) {
      debugPrint('AiExampleButton local example failed: $e');
      return null;
    }
  }

  Future<String?> _generateCloud({
    required AiRouteDecision decision,
    required String term,
    required String definition,
  }) async {
    if (!decision.isCloud) return null;
    final user = ref.read(currentUserProvider);
    if (user == null) return null;

    const task = AiTaskType.exampleSentence;
    final entitlement = ref.read(effectiveAiEntitlementProvider);
    final quota = ref.read(aiQuotaServiceProvider);
    final gateway = AiGateway.decide(
      route: decision,
      entitlement: entitlement,
      type: task,
      usedToday: quota.usageToday(task),
    );
    if (gateway.outcome != AiGatewayOutcome.runCloud) return null;
    // Do NOT consume the local quota here: the proxy path is metered
    // server-side (consume_ai_daily_quota), so consuming locally too would
    // double-count. This mirrors the smartDistractors proxy path.

    final prompt = LocalAiService.buildExampleSentencePrompt(
      term: term,
      definition: definition,
    );
    final response = await ref
        .read(aiProxyClientProvider)
        .complete(
          taskType: task,
          messages: [
            const AiProxyMessage(
              role: AiProxyRole.system,
              content: 'Return one short English sentence only. No Chinese.',
            ),
            AiProxyMessage(role: AiProxyRole.user, content: prompt),
          ],
          temperature: 0.45,
          maxTokens: 90,
        );
    final sentence = LocalAiService.cleanSingleSentence(response.text);
    return _usableSentence(sentence, term: term, source: 'appRemote');
  }

  Future<String?> _generateWithUserGeminiKey({
    required String term,
    required String definition,
  }) async {
    final key = ref.read(geminiKeyProvider).trim();
    if (key.isEmpty) return null;
    final results = await GeminiService.generateExampleSentencesBatch(
      apiKey: key,
      terms: [
        {'term': term, 'definition': definition},
      ],
    );
    final raw =
        results[term] ?? (results.isNotEmpty ? results.values.first : '');
    final sentence = LocalAiService.cleanSingleSentence(raw);
    return _usableSentence(sentence, term: term, source: 'gemini');
  }

  Future<String?> _generateWithUserGroqKey({
    required String term,
    required String definition,
  }) async {
    final key = ref.read(groqKeyProvider).trim();
    if (key.isEmpty) return null;
    final groq = GroqCompletionService(apiKey: key);
    try {
      return await groq.generateExampleSentence(
        term: term,
        definition: definition,
      );
    } finally {
      groq.close();
    }
  }

  String? _usableSentence(
    String sentence, {
    required String term,
    required String source,
  }) {
    final cleaned = sentence.trim();
    if (cleaned.isEmpty) {
      if (kDebugMode) {
        debugPrint('AiExampleButton $source returned empty example sentence.');
      }
      return null;
    }
    if (!LocalAiService.isLikelyEnglishSentence(cleaned)) {
      if (kDebugMode) {
        debugPrint(
          'AiExampleButton $source returned non-English example: $cleaned',
        );
      }
      return null;
    }
    if (!cleaned.toLowerCase().contains(term.toLowerCase())) {
      if (kDebugMode) {
        debugPrint(
          'AiExampleButton $source example did not contain "$term": $cleaned',
        );
      }
    }
    return cleaned;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final route = ref
        .watch(aiRouteProvider(AiTaskType.exampleSentence))
        .valueOrNull;
    final selectedProvider = ref.watch(aiProviderProvider);
    final available =
        selectedProvider == AiProvider.appRemote ||
        (route != null && route.target != AiRouteTarget.unavailable);
    if (!available) return const SizedBox.shrink();

    return TextButton.icon(
      onPressed: _loading ? null : _generate,
      icon: _loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('✨', style: TextStyle(fontSize: 14)),
      label: Text(_loading ? '產生中…' : 'AI 例句'),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
