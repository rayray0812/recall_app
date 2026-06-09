import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:recall_app/core/constants/app_constants.dart';
import 'package:recall_app/services/ai/smart_distractor_cache_service.dart';

void main() {
  late Directory tempDir;
  late SmartDistractorCacheService cache;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('smart_distractor_cache_');
    Hive.init(tempDir.path);
    await Hive.openBox(AppConstants.hiveSettingsBox);
    cache = SmartDistractorCacheService();
  });

  tearDown(() async {
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  test('stores and restores distractors by stable card content key', () async {
    final key = cache.keyFor(
      cardId: 'c1',
      term: 'ephemeral',
      definition: '短暫的',
      correctOption: '短暫的',
      reversed: false,
    );

    await cache.put(key, ['永久的', '快速的', '巨大的']);

    expect(cache.get(key), ['永久的', '快速的', '巨大的']);
  });

  test('changing card content changes the cache key', () async {
    final original = cache.keyFor(
      cardId: 'c1',
      term: 'ephemeral',
      definition: '短暫的',
      correctOption: '短暫的',
      reversed: false,
    );
    final edited = cache.keyFor(
      cardId: 'c1',
      term: 'temporary',
      definition: '短暫的',
      correctOption: '短暫的',
      reversed: false,
    );

    await cache.put(original, ['永久的', '快速的', '巨大的']);

    expect(edited, isNot(original));
    expect(cache.get(edited), isNull);
  });
}
