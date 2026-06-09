import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/providers/card_lookup_provider.dart';

/// "✨ 智慧填入" button for the card editor.
///
/// The learner types only the English term; one tap fills the Traditional
/// Chinese definition, an example sentence (when that field exists), and adds a
/// part-of-speech tag. Local-first with cloud-proxy fallback (see
/// [cardLookupProvider]); the button hides itself when no AI path is available
/// so the manual, no-AI flow is always the baseline.
class AiAutofillButton extends ConsumerStatefulWidget {
  const AiAutofillButton({
    super.key,
    required this.termController,
    required this.definitionController,
    this.exampleSentenceController,
    this.onAddTag,
  });

  final TextEditingController termController;
  final TextEditingController definitionController;
  final TextEditingController? exampleSentenceController;
  final void Function(String tag)? onAddTag;

  @override
  ConsumerState<AiAutofillButton> createState() => _AiAutofillButtonState();
}

class _AiAutofillButtonState extends ConsumerState<AiAutofillButton> {
  bool _loading = false;

  Future<void> _autofill() async {
    final term = widget.termController.text.trim();
    if (term.isEmpty) {
      _toast('請先輸入英文單字');
      return;
    }
    setState(() => _loading = true);
    try {
      final result = await ref.read(cardLookupProvider(term).future);
      if (!mounted) return;
      if (result == null) {
        _toast('找不到資料，請手動填寫或確認已登入');
        return;
      }

      // Only fill empty fields — never clobber what the learner already typed.
      if (widget.definitionController.text.trim().isEmpty &&
          result.definition.isNotEmpty) {
        widget.definitionController.text = result.definition;
      }
      final exampleController = widget.exampleSentenceController;
      if (exampleController != null &&
          exampleController.text.trim().isEmpty &&
          result.example.isNotEmpty) {
        exampleController.text = result.example;
      }
      if (result.pos.isNotEmpty) {
        widget.onAddTag?.call(result.pos);
      }
      _toast('已自動填入，請確認內容');
    } catch (_) {
      if (mounted) _toast('產生失敗，請再試一次');
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
    if (!ref.watch(cardLookupAvailableProvider)) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      onPressed: _loading ? null : _autofill,
      icon: _loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('✨', style: TextStyle(fontSize: 14)),
      label: Text(_loading ? '查詢中…' : '智慧填入'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
    );
  }
}
