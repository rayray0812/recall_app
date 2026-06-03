class AppConstants {
  static const String appName = '拾憶 Grasp';
  static const String hiveStudySetsBox = 'study_sets';
  static const String hiveCardProgressBox = 'card_progress';
  static const String hiveReviewLogsBox = 'review_logs';
  static const String hiveReviewSessionsBox = 'review_sessions';
  static const String hiveFoldersBox = 'folders';
  static const String hiveSettingsBox = 'settings';

  static const String settingNotificationEnabledKey = 'notification_enabled';
  static const String settingBiometricQuickUnlockKey = 'biometric_quick_unlock';
  static const String settingHasSeenOnboarding = 'has_seen_onboarding';
  static const String settingAuthEventsKey = 'auth_events';
  static const String settingSyncConflictsKey = 'sync_conflicts';
  static const String settingDeletedStudySetIdsKey = 'deleted_study_set_ids';
  static const String settingDeletedFolderIdsKey = 'deleted_folder_ids';
  static const String settingTtsEngineKey = 'tts_engine';
  static const String settingCommunityFriendIdsKey = 'community_friend_ids';
  static const String settingCommunitySavedSetIdsKey =
      'community_saved_set_ids';
  static const String settingConversationMutedKey = 'conversation_muted';
  static const String settingGemmaLocalModelPathKey = 'gemma_local_model_path';
  static const String settingAiEventsKey = 'ai_events';
  static const String settingAiPrivacyModeKey = 'ai_privacy_mode';

  static const int maxCardsPerSet = 2000;
  static const int defaultNewCardsPerDay = 20;
  static const String notificationChannelId = 'recall_daily_review';
  static const int defaultNotificationHour = 20;
  static const int defaultNotificationMinute = 0;

  // Home Screen Widgets
  static const String widgetAppGroupId = 'group.com.studyapp.recallapp';
  static const String widgetAndroidDailyMission =
      'widgets.DailyMissionWidgetProvider';
  static const String widgetAndroidPressureBar =
      'widgets.PressureBarWidgetProvider';
  static const String widgetIosDailyMission = 'DailyMissionWidget';
  static const String widgetIosPressureBar = 'PressureBarWidget';
  static const String deepLinkScheme = 'recall';
  static const int defaultDailyTarget = 20;

  static const String appVersion = '1.0.0';
}
