import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/services/ai/card_lookup_service.dart';

void main() {
  group('CardLookupService.buildPrompt', () {
    test('mentions the term and asks for the JSON shape', () {
      final prompt = CardLookupService.buildPrompt('resilient');
      expect(prompt, contains('resilient'));
      expect(prompt, contains('definition'));
      expect(prompt, contains('pos'));
      expect(prompt, contains('example'));
    });
  });

  group('CardLookupService.parse', () {
    test('parses a clean JSON object', () {
      final r = CardLookupService.parse(
        '{"definition":"有彈性的；堅韌的","pos":"adj.","example":"She is resilient."}',
      );
      expect(r, isNotNull);
      expect(r!.definition, '有彈性的；堅韌的');
      expect(r.pos, 'adj.');
      expect(r.example, 'She is resilient.');
      expect(r.isUsable, isTrue);
    });

    test('tolerates code fences and surrounding prose', () {
      final r = CardLookupService.parse(
        'Sure! Here you go:\n```json\n'
        '{"definition":"放棄","pos":"verb","example":"Do not abandon hope."}\n'
        '```',
      );
      expect(r, isNotNull);
      expect(r!.definition, '放棄');
      // "verb" normalizes to the short canonical form.
      expect(r.pos, 'v.');
      expect(r.example, 'Do not abandon hope.');
    });

    test('falls back to field extraction when JSON is malformed', () {
      final r = CardLookupService.parse(
        'definition: 短暫的\npos: adjective\nexample: a fleeting moment',
      );
      expect(r, isNotNull);
      expect(r!.definition, '短暫的');
      expect(r.pos, 'adj.');
    });

    test('returns null on empty or contentless output', () {
      expect(CardLookupService.parse(''), isNull);
      expect(CardLookupService.parse('   '), isNull);
      expect(CardLookupService.parse('I cannot help with that.'), isNull);
    });
  });

  group('CardLookupResult quality gate', () {
    test('English-only definition is NOT usable (forces cloud escalation)', () {
      const r = CardLookupResult(definition: 'flexible and tough');
      expect(r.isUsable, isFalse);
    });

    test('definition with Chinese is usable', () {
      const r = CardLookupResult(definition: '有彈性的');
      expect(r.isUsable, isTrue);
    });

    test('parse result without a Chinese definition is not usable', () {
      final r = CardLookupService.parse(
        '{"definition":"flexible","pos":"adj.","example":"It is flexible."}',
      );
      expect(r, isNotNull);
      expect(r!.isUsable, isFalse);
    });
  });
}
