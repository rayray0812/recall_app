import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Selected AI execution mode.
///
/// This is intentionally a single choice in settings:
/// - [appRemote]: Grasp-managed Supabase Edge Function, owner token protected.
/// - [gemma]: on-device local model only.
/// - [gemini]/[groq]: user's own API key only.
enum AiProvider { appRemote, gemma, gemini, groq }

const _boxName = 'settings';
const _providerKey = 'ai_provider';
const _groqKeyKey = 'groq_api_key';
const _gemmaLocalModelPathKey = 'gemma_local_model_path';

/// Notifier that persists the selected AI provider in Hive settings box.
class AiProviderNotifier extends StateNotifier<AiProvider> {
  AiProviderNotifier() : super(AiProvider.appRemote) {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(_boxName);
      final raw = box.get(_providerKey, defaultValue: 'appRemote') as String;
      state = switch (raw) {
        'appRemote' => AiProvider.appRemote,
        'groq' => AiProvider.groq,
        'gemma' => AiProvider.gemma,
        'gemini' => AiProvider.gemini,
        _ => AiProvider.appRemote,
      };
    } catch (e) {
      debugPrint('AI provider load failed: $e');
      state = AiProvider.appRemote;
    }
  }

  Future<void> setProvider(AiProvider provider) async {
    state = provider;
    try {
      final box = Hive.box(_boxName);
      await box.put(_providerKey, provider.name);
    } catch (e) {
      debugPrint('AI provider save failed: $e');
    }
  }
}

final aiProviderProvider =
    StateNotifierProvider<AiProviderNotifier, AiProvider>(
  (ref) => AiProviderNotifier(),
);

/// Groq API Key stored in FlutterSecureStorage.
class GroqKeyNotifier extends StateNotifier<String> {
  final FlutterSecureStorage _secureStorage;

  GroqKeyNotifier({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      super('') {
    _load();
  }

  Future<void> _load() async {
    try {
      final value = (await _secureStorage.read(key: _groqKeyKey) ?? '').trim();
      state = value;
    } catch (e) {
      debugPrint('Groq key load failed: $e');
      state = '';
    }
  }

  Future<void> setApiKey(String key) async {
    final value = key.trim();
    state = value;
    try {
      if (value.isEmpty) {
        await _secureStorage.delete(key: _groqKeyKey);
      } else {
        await _secureStorage.write(key: _groqKeyKey, value: value);
      }
    } catch (e) {
      debugPrint('Groq key write failed: $e');
    }
  }
}

final groqKeyProvider = StateNotifierProvider<GroqKeyNotifier, String>(
  (ref) => GroqKeyNotifier(),
);

/// Path to local Gemma .litertlm model file, persisted in Hive.
class GemmaLocalModelPathNotifier extends StateNotifier<String> {
  GemmaLocalModelPathNotifier() : super('') {
    _load();
  }

  void _load() {
    try {
      final box = Hive.box(_boxName);
      state = (box.get(_gemmaLocalModelPathKey, defaultValue: '') as String)
          .trim();
    } catch (e) {
      debugPrint('Gemma local model path load failed: $e');
      state = '';
    }
  }

  Future<void> setPath(String path) async {
    state = path.trim();
    try {
      await Hive.box(_boxName).put(_gemmaLocalModelPathKey, state);
    } catch (e) {
      debugPrint('Gemma local model path save failed: $e');
    }
  }

  Future<void> clear() async {
    state = '';
    try {
      await Hive.box(_boxName).delete(_gemmaLocalModelPathKey);
    } catch (e) {
      debugPrint('Gemma local model path delete failed: $e');
    }
  }
}

final gemmaLocalModelPathProvider =
    StateNotifierProvider<GemmaLocalModelPathNotifier, String>(
      (ref) => GemmaLocalModelPathNotifier(),
    );
