import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/features/import/screens/photo_import_screen.dart';
import 'package:recall_app/providers/ai_provider_provider.dart';

void main() {
  final zhL10n = AppLocalizationsZh(const Locale('zh', 'TW'));

  test('activeAiProviderLabel returns correct provider name', () {
    expect(activeAiProviderLabel(AiProvider.appRemote), 'Grasp AI');
    expect(activeAiProviderLabel(AiProvider.gemini), 'Gemini');
    expect(activeAiProviderLabel(AiProvider.groq), 'Groq');
  });

  test('missingApiKeyMessageForProvider uses provider-specific copy', () {
    final groqMessage = missingApiKeyMessageForProvider(
      AiProvider.groq,
      zhL10n,
    );

    expect(groqMessage, contains('Groq API Key'));
    expect(groqMessage, isNot(zhL10n.geminiApiKeyNotSet));
    expect(
      missingApiKeyMessageForProvider(AiProvider.gemini, zhL10n),
      zhL10n.geminiApiKeyNotSet,
    );
    expect(
      missingApiKeyMessageForProvider(AiProvider.appRemote, zhL10n),
      contains('請先登入'),
    );
  });

  test('authErrorMessageForProvider uses provider-specific copy', () {
    final groqMessage = authErrorMessageForProvider(AiProvider.groq);

    expect(groqMessage, contains('Groq API Key'));
    expect(groqMessage, contains('API'));
    expect(
      authErrorMessageForProvider(AiProvider.gemini),
      'API authentication failed. Please check your Gemini API key.',
    );
  });
}
