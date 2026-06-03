import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/ai_runtime_provider.dart';
import 'package:recall_app/services/ai/ai_router.dart';
import 'package:recall_app/services/ai_task.dart';
import 'package:recall_app/services/local_ai_service.dart';

/// "✨ AI 例句" button for the card editor: generates one example sentence on
/// the local model and fills [exampleSentenceController].
///
/// Hidden entirely when the local AI can't run (no model / privacy off / low
/// RAM) — fail silent rather than showing a broken button, matching
/// [ReviewHintButton]'s behaviour.
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
      if (decision.target != AiRouteTarget.local) {
        _toast('本地 AI 尚未就緒');
        return;
      }
      final engine = await ref.read(localLlmEngineProvider.future);
      final sentence = await LocalAiService.generateExampleSentence(
        engine: engine,
        term: term,
        definition: widget.definitionController.text.trim(),
      );
      if (!mounted) return;
      if (sentence == null || sentence.isEmpty) {
        _toast('產生失敗，請再試一次');
        return;
      }
      widget.exampleSentenceController.text = sentence;
    } catch (_) {
      _toast('產生失敗，請再試一次');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final available =
        ref.watch(aiRouteProvider(AiTaskType.exampleSentence)).valueOrNull?.isLocal ??
        false;
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
