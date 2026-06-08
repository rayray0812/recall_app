import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/providers/auth_provider.dart';
import 'package:recall_app/providers/gemini_key_provider.dart';
import 'package:recall_app/services/ai/ai_gateway.dart';
import 'package:recall_app/services/ai/ai_proxy_client.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/gemini_service.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// "✨ AI 例句" button for the card editor: generates one example sentence and
/// fills [exampleSentenceController].
///
/// It tries the local model first, then falls back to the server-side AI proxy
/// for signed-in users or the user's own Gemini key. This keeps the editor
/// usable when tiny local models return reasoning text instead of a clean
/// sentence.
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
      final decision = await ref.read(
        aiRouteProvider(AiTaskType.exampleSentence).future,
      );
      final definition = widget.definitionController.text.trim();
      var sentence = await _generateLocal(
        decision: decision,
        term: term,
        definition: definition,
      );
      if (sentence != null && sentence.isEmpty) sentence = null;
      sentence ??= await _generateCloudFallback(
        currentDecision: decision,
        term: term,
        definition: definition,
      );
      sentence ??= await _generateCloud(
        decision: decision,
        term: term,
        definition: definition,
      );
      if (!mounted) return;
      if (sentence == null || sentence.isEmpty) {
        _toast('產生失敗，請確認已登入或雲端 AI 已設定');
        return;
      }
      widget.exampleSentenceController.text = sentence;
    } catch (_) {
      _toast('產生失敗，請再試一次');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
    } catch (_) {
      return null;
    }
  }

  Future<String?> _generateCloudFallback({
    required AiRouteDecision currentDecision,
    required String term,
    required String definition,
  }) async {
    if (currentDecision.isCloud ||
        currentDecision.target == AiRouteTarget.unavailable) {
      return null;
    }
    if (ref.read(aiPrivacyModeProvider)) return null;
    if (!(ref.read(aiOnlineProvider).valueOrNull ?? true)) return null;
    if (!ref.read(
      cloudConfiguredForTaskProvider(AiTaskType.exampleSentence),
    )) {
      return null;
    }
    return _generateCloud(
      decision: const AiRouteDecision(
        AiRouteTarget.cloud,
        'exampleSentence local failed → cloud fallback',
      ),
      term: term,
      definition: definition,
    );
  }

  Future<String?> _generateCloud({
    required AiRouteDecision decision,
    required String term,
    required String definition,
  }) async {
    if (!decision.isCloud) return null;
    final user = ref.read(currentUserProvider);
    if (user == null) {
      return _generateWithUserGeminiKey(term: term, definition: definition);
    }

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
    final response = await ref.read(aiProxyClientProvider).complete(
      taskType: task,
      messages: [
        const AiProxyMessage(
          role: AiProxyRole.system,
          content:
              'Generate exactly one natural English example sentence. Do not include explanations, translations, labels, markdown, or thinking.',
        ),
        AiProxyMessage(role: AiProxyRole.user, content: prompt),
      ],
      temperature: 0.45,
      maxTokens: 90,
    );
    final sentence = LocalAiService.cleanSingleSentence(response.text);
    return sentence.toLowerCase().contains(term.toLowerCase())
        ? sentence
        : null;
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
    final raw = results[term] ??
        (results.isNotEmpty ? results.values.first : '');
    final sentence = LocalAiService.cleanSingleSentence(raw);
    return sentence.toLowerCase().contains(term.toLowerCase())
        ? sentence
        : null;
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
    final hasCloudCredential = ref.watch(currentUserProvider) != null ||
        ref.watch(geminiKeyProvider).trim().isNotEmpty;
    final available = route != null &&
        (route.isLocal || (route.isCloud && hasCloudCredential));
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
