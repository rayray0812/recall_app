import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

/// L1 affordance: a small "💡 提示" pill that, when tapped, asks the local
/// Gemma model for a one-sentence hint about the current card.
///
/// Hidden entirely when no local model is configured — fail silent rather than
/// showing a broken button.
class ReviewHintButton extends ConsumerStatefulWidget {
  final String cardId;
  final String term;
  final String definition;

  const ReviewHintButton({
    super.key,
    required this.cardId,
    required this.term,
    required this.definition,
  });

  @override
  ConsumerState<ReviewHintButton> createState() => _ReviewHintButtonState();
}

class _ReviewHintButtonState extends ConsumerState<ReviewHintButton> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final canHint =
        ref.watch(localHintAvailableProvider).valueOrNull ?? false;
    if (!canHint) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);

    if (!_requested) {
      return TextButton.icon(
        onPressed: () => setState(() => _requested = true),
        icon: const Text('💡', style: TextStyle(fontSize: 16)),
        label: Text(
          l10n.localHintCta,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.indigo,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    final hint = ref.watch(
      reviewHintProvider(
        ReviewHintRequest(
          cardId: widget.cardId,
          term: widget.term,
          definition: widget.definition,
        ),
      ),
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: switch (hint) {
        AsyncData(value: final text) when text != null && text.isNotEmpty =>
          _HintBubble(key: const ValueKey('hint-ready'), text: text),
        AsyncData() => _HintBubble(
            key: const ValueKey('hint-empty'),
            text: l10n.localHintUnavailable,
          ),
        AsyncError() => _HintBubble(
            key: const ValueKey('hint-error'),
            text: l10n.localHintUnavailable,
          ),
        _ => const _HintLoading(key: ValueKey('hint-loading')),
      },
    );
  }
}

class _HintBubble extends StatelessWidget {
  final String text;
  const _HintBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.indigo.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.indigo.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('💡', style: TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: AppTheme.indigo.withValues(alpha: 0.92),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HintLoading extends StatelessWidget {
  const _HintLoading({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.indigo.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            l10n.localHintGenerating,
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.indigo.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
