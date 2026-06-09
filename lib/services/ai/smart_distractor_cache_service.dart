import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';

class SmartDistractorCacheService {
  static const int _version = 1;
  static const int _maxEntries = 600;

  Box get _box => Hive.box(AppConstants.hiveSettingsBox);

  String keyFor({
    required String cardId,
    required String term,
    required String definition,
    required String correctOption,
    required bool reversed,
  }) {
    final signature = _stableHash(
      [term.trim(), definition.trim(), correctOption.trim()].join('\n'),
    );
    return 'v$_version|$cardId|${reversed ? 'def_term' : 'term_def'}|$signature';
  }

  List<String>? get(String key) {
    final cache = _readCache();
    final raw = cache[key];
    if (raw is! Map) return null;

    final optionsRaw = raw['options'];
    if (optionsRaw is! List) return null;
    final options = optionsRaw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return options.length >= 3 ? options : null;
  }

  Future<void> put(String key, List<String> options) async {
    final cleaned = options
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(3)
        .toList(growable: false);
    if (cleaned.length < 3) return;

    final cache = _readCache();
    cache[key] = {
      'options': cleaned,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
    _trim(cache);
    await _box.put(AppConstants.settingSmartDistractorCacheKey, cache);
  }

  Map<String, dynamic> _readCache() {
    final raw = _box.get(
      AppConstants.settingSmartDistractorCacheKey,
      defaultValue: <String, dynamic>{},
    );
    if (raw is! Map) return <String, dynamic>{};
    return Map<String, dynamic>.from(raw);
  }

  void _trim(Map<String, dynamic> cache) {
    if (cache.length <= _maxEntries) return;
    final entries = cache.entries.toList()
      ..sort((a, b) {
        final aTime = _updatedAt(a.value);
        final bTime = _updatedAt(b.value);
        return aTime.compareTo(bTime);
      });
    final removeCount = cache.length - _maxEntries;
    for (final entry in entries.take(removeCount)) {
      cache.remove(entry.key);
    }
  }

  DateTime _updatedAt(Object? value) {
    if (value is Map) {
      final parsed = DateTime.tryParse(value['updated_at']?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  int _stableHash(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash;
  }
}
