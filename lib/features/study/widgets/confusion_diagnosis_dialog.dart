import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

/// L3 affordance: a dialog that asks the local model why a quiz distractor is
/// easy to confuse with the correct answer, and how to keep them apart.
///
/// Opened deliberately by the learner (via a "why the mix-up?" button) after a
/// wrong multiple-choice answer, so it never auto-interrupts the quiz rhythm.
/// Gating (model installed / privacy on) is checked before the button is shown,
/// so by the time this dialog opens the local engine is expected to be ready.
class ConfusionDiagnosisDialog extends ConsumerWidget {
  final ConfusionRequest request;

  const ConfusionDiagnosisDialog({super.key, required this.request});

  /// Convenience opener; returns when the dialog is dismissed.
  static Future<void> show(
    BuildContext context, {
    required ConfusionRequest request,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => ConfusionDiagnosisDialog(request: request),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final explanation = ref.watch(confusionExplanationProvider(request));

    return AlertDialog(
      title: Row(
        children: [
          const Text('🧠', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.confusionDialogTitle)),
        ],
      ),
      content: _DiagnosisContent(explanation: explanation, l10n: l10n),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}

class _DiagnosisContent extends StatelessWidget {
  final AsyncValue<String?> explanation;
  final AppLocalizations l10n;

  const _DiagnosisContent({required this.explanation, required this.l10n});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final maxHeight = (media.height * 0.45).clamp(120.0, 360.0);
    final content = switch (explanation) {
      AsyncData(value: final text) when text != null && text.isNotEmpty => Text(
        text,
        style: const TextStyle(fontSize: 14, height: 1.45),
      ),
      AsyncData() || AsyncError() => Text(
        l10n.confusionUnavailable,
        style: TextStyle(
          fontSize: 14,
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
      _ => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.indigo.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              l10n.confusionGenerating,
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.indigo.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    };

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: media.width * 0.82,
        maxHeight: maxHeight,
      ),
      child: SingleChildScrollView(child: content),
    );
  }
}
