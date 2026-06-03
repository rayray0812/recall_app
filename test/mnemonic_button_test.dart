import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/features/study/widgets/mnemonic_button.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Future<void> pumpButton(
    WidgetTester tester, {
    required AsyncValue<bool> availability,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localMnemonicAvailableProvider.overrideWithValue(availability),
        ],
        child: MaterialApp(
          localizationsDelegates: const [AppLocalizations.delegate],
          supportedLocales: const [Locale('en')],
          locale: const Locale('en'),
          home: const Scaffold(
            body: MnemonicButton(
              cardId: 'c1',
              term: 'ephemeral',
              definition: 'lasting a very short time',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('hidden when local AI unavailable', (tester) async {
    await pumpButton(tester, availability: const AsyncData(false));

    expect(find.text('Mnemonic'), findsNothing);
    expect(find.text('🧠'), findsNothing);
  });

  testWidgets('hidden while availability is still loading', (tester) async {
    await pumpButton(tester, availability: const AsyncLoading());

    expect(find.text('Mnemonic'), findsNothing);
  });

  testWidgets('shows the CTA pill when available and not yet requested', (
    tester,
  ) async {
    await pumpButton(tester, availability: const AsyncData(true));

    expect(find.text('Mnemonic'), findsOneWidget);
    expect(find.text('🧠'), findsOneWidget);
  });
}
