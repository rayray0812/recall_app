import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/local_llm_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalLlmEngine backends', () {
    test('each engine reports its backend', () {
      expect(
        const AppleFoundationModelsEngine().backend,
        LocalLlmBackend.appleFoundationModels,
      );
      expect(
        AndroidMediaPipeEngine(modelPath: '/tmp/m.litertlm').backend,
        LocalLlmBackend.androidMediaPipe,
      );
      expect(const NullLocalLlmEngine().backend, LocalLlmBackend.none);
    });

    test('NullLocalLlmEngine is never available and yields empty output', () async {
      const engine = NullLocalLlmEngine();
      expect(await engine.isAvailable(), isFalse);
      expect(await engine.generate(prompt: 'hi'), isEmpty);
    });

    test('AndroidMediaPipeEngine with empty path is unavailable', () async {
      final engine = AndroidMediaPipeEngine(modelPath: '   ');
      expect(await engine.isAvailable(), isFalse);
    });

    test(
      'AppleFoundationModelsEngine degrades gracefully without native side',
      () async {
        // No MethodChannel handler registered → MissingPluginException is
        // swallowed and the engine reports unavailable / empty rather than
        // throwing into the UI.
        const engine = AppleFoundationModelsEngine();
        expect(await engine.isAvailable(), isFalse);
        expect(await engine.generate(prompt: 'hi'), isEmpty);
      },
    );
  });
}
