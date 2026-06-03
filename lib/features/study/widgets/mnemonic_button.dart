import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/core/theme/app_theme.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

/// L2 affordance: a small "🧠 口訣" pill that, when tapped, asks the local
/// model for a memory mnemonic linking the term and its definition.
///
/// Designed for the *flipped* (answer-visible) side of an SRS card, where a
/// mnemonic helps cement the association just learned. Hidden entirely when no
/// local model is configured — fail silent rather than showing a broken button,
/// matching [ReviewHintButton].
class MnemonicButton extends ConsumerStatefulWidget {
  final String cardId;
  final String term;
  final String definition;

  const MnemonicButton({
    super.key,
    required this.cardId,
    required this.term,
    required this.definition,
  });

  @override
  ConsumerState<MnemonicButton> createState() => _MnemonicButtonState();
}

class _MnemonicButtonState extends ConsumerState<MnemonicButton> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final canRun =
        ref.watch(localMnemonicAvailableProvider).valueOrNull ?? false;
    if (!canRun) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);

    if (!_requested) {
      return TextButton.icon(
        onPressed: () => setState(() => _requested = true),
        icon: const Text('🧠', style: TextStyle(fontSize: 16)),
        label: Text(
          l10n.mnemonicCta,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        style: TextButton.styleFrom(
          foregroundColor: AppTheme.indigo,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    final mnemonic = ref.watch(
      mnemonicProvider(
        ReviewHintRequest(
          cardId: widget.cardId,
          term: widget.term,
          definition: widget.definition,
        ),
      ),
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: switch (mnemonic) {
        AsyncData(value: final text) when text != null && text.isNotEmpty =>
          _MnemonicBubble(key: const ValueKey('mnemonic-ready'), text: text),
        AsyncData() => _MnemonicBubble(
            key: const ValueKey('mnemonic-empty'),
            text: l10n.mnemonicUnavailable,
          ),
        AsyncError() => _MnemonicBubble(
            key: const ValueKey('mnemonic-error'),
            text: l10n.mnemonicUnavailable,
          ),
        _ => const _MnemonicLoading(key: ValueKey('mnemonic-loading')),
      },
    );
  }
}

class _MnemonicBubble extends StatelessWidget {
  final String text;
  const _MnemonicBubble({super.key, required this.text});

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
          const Text('🧠', style: TextStyle(fontSize: 14)),
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

class _MnemonicLoading extends StatelessWidget {
  const _MnemonicLoading({super.key});

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
            l10n.mnemonicGenerating,
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
