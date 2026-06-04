import 'package:flutter_test/flutter_test.dart';
import 'package:recall_app/features/study/services/conversation_scenario_validator.dart';
import 'package:recall_app/services/gemini_service.dart';

ConversationScenario _scenario({
  String title = 'Returning a Jacket',
  String setting = 'A clothing store counter, sorting out a refund.',
  String aiRole = 'Store Clerk',
  String userRole = 'Customer',
  String titleZh = '退換外套',
  List<String> stages = const ['Greet', 'Explain', 'Resolve', 'Confirm', 'Close'],
}) {
  return ConversationScenario(
    title: title,
    titleZh: titleZh,
    setting: setting,
    settingZh: '在服飾店櫃台處理退款。',
    aiRole: aiRole,
    aiRoleZh: '店員',
    userRole: userRole,
    userRoleZh: '顧客',
    stages: stages,
    stagesZh: const ['打招呼', '說明', '解決', '確認', '結束'],
  );
}

void main() {
  group('isStructurallyValidScenario', () {
    test('accepts a complete scenario even if no target words appear in it', () {
      // The whole point of the relaxation: vocabulary need NOT appear literally.
      expect(isStructurallyValidScenario(_scenario()), isTrue);
    });

    test('rejects empty core fields', () {
      expect(isStructurallyValidScenario(_scenario(setting: '   ')), isFalse);
      expect(isStructurallyValidScenario(_scenario(aiRole: '')), isFalse);
    });

    test('rejects identical AI and user roles', () {
      expect(
        isStructurallyValidScenario(
          _scenario(aiRole: 'Clerk', userRole: 'clerk'),
        ),
        isFalse,
      );
    });

    test('rejects leaked prompt/meta text', () {
      expect(
        isStructurallyValidScenario(
          _scenario(setting: 'Return ONLY a JSON object with target words'),
        ),
        isFalse,
      );
    });

    test('rejects when there is no Chinese translation anywhere', () {
      final allEnglish = ConversationScenario(
        title: 'Cafe Order',
        titleZh: 'Cafe Order',
        setting: 'A cafe',
        settingZh: 'A cafe',
        aiRole: 'Barista',
        aiRoleZh: 'Barista',
        userRole: 'Customer',
        userRoleZh: 'Customer',
        stages: ['Greet'],
        stagesZh: ['Greet'],
      );
      expect(isStructurallyValidScenario(allEnglish), isFalse);
    });

    test('rejects a title that duplicates a recent one', () {
      expect(
        isStructurallyValidScenario(
          _scenario(title: 'Returning a Jacket'),
          blockedTitles: ['returning a jacket'],
        ),
        isFalse,
      );
    });
  });

  group('helper predicates', () {
    test('scenarioContainsCjk detects Chinese', () {
      expect(scenarioContainsCjk('退款'), isTrue);
      expect(scenarioContainsCjk('refund'), isFalse);
    });

    test('scenarioHasMetaText flags leaked instructions', () {
      expect(scenarioHasMetaText('output exactly two lines'), isTrue);
      expect(scenarioHasMetaText('A cosy neighbourhood cafe'), isFalse);
    });

    test('isNearDuplicateScenarioTitle matches substrings', () {
      expect(isNearDuplicateScenarioTitle('Cafe Order', ['cafe order']), isTrue);
      expect(
        isNearDuplicateScenarioTitle('Cafe Order Deluxe', ['cafe order']),
        isTrue,
      );
      expect(isNearDuplicateScenarioTitle('Bank Visit', ['cafe order']), isFalse);
    });
  });
}
