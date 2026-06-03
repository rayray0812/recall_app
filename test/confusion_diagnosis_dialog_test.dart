import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:recall_app/core/l10n/app_localizations.dart';
import 'package:recall_app/features/study/widgets/confusion_diagnosis_dialog.dart';
import 'package:recall_app/providers/local_ai_provider.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const request = ConfusionRequest(
    targetTerm: 'affect',
    targetDefinition: 'to influence',
    chosenTerm: 'effect',
    chosenDefinition: 'a result',
  );

  Future<void> pumpDialog(
    WidgetTester tester, {
    required Override override,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [override],
        child: const MaterialApp(
          localizationsDelegates: [AppLocalizations.delegate],
          supportedLocales: [Locale('en')],
          locale: Locale('en'),
          home: Scaffold(
            body: ConfusionDiagnosisDialog(request: request),
          ),
        ),
      ),
    );
  }

  testWidgets('shows the diagnosis text when the model returns one', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      override: confusionExplanationProvider(request).overrideWith(
        (ref) async => 'Affect is a verb; effect is a noun.',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Confusion check'), findsOneWidget);
    expect(
      find.text('Affect is a verb; effect is a noun.'),
      findsOneWidget,
    );
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('shows the fallback message when the model returns null', (
    tester,
  ) async {
    await pumpDialog(
      tester,
      override: confusionExplanationProvider(request)
          .overrideWith((ref) async => null),
    );
    await tester.pumpAndSettle();

    expect(find.text('Diagnosis failed, please retry'), findsOneWidget);
  });

  testWidgets('shows a loading state while generating', (tester) async {
    await pumpDialog(
      tester,
      override: confusionExplanationProvider(request).overrideWith(
        // Never completes within the test → stays in loading.
        (ref) => Completer<String?>().future,
      ),
    );
    await tester.pump();

    expect(find.text('Analyzing…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
