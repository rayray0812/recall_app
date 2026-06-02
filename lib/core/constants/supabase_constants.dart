import 'package:flutter/foundation.dart';

class SupabaseConstants {
  // Provide via --dart-define:
  // SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_REDIRECT_URL
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
  );
  static const String supabaseRedirectUrl = String.fromEnvironment(
    'SUPABASE_REDIRECT_URL',
  );
  static const String _debugFallbackUrl =
      'https://jijyptcixzievhdohzje.supabase.co';
  static const String _debugFallbackAnonKey =
      'sb_publishable_FPDzL1AlThG5iSORBR4Q2A_ZfLpcVm5';
  static const String mobileRedirectUrl =
      'io.supabase.flutter://login-callback/';

  static String get resolvedSupabaseUrl {
    final configured = supabaseUrl.trim();
    if (configured.isNotEmpty) return configured;
    if (kDebugMode) return _debugFallbackUrl;
    return '';
  }

  static String get resolvedSupabaseAnonKey {
    final configured = supabaseAnonKey.trim();
    if (configured.isNotEmpty) return configured;
    if (kDebugMode) return _debugFallbackAnonKey;
    return '';
  }

  static bool get isConfigured =>
      resolvedSupabaseUrl.isNotEmpty && resolvedSupabaseAnonKey.isNotEmpty;

  static String get authRedirectUrl {
    if (supabaseRedirectUrl.trim().isNotEmpty) return supabaseRedirectUrl;
    if (kIsWeb) return Uri.base.origin;
    return mobileRedirectUrl;
  }

  static const String studySetsTable = 'study_sets';
  static const String cardProgressTable = 'card_progress';
  static const String reviewLogsTable = 'review_logs';
  static const String foldersTable = 'folders';
  static const String profilesTable = 'profiles';
  static const String classesTable = 'classes';
  static const String classMembersTable = 'class_members';
  static const String classSetsTable = 'class_sets';
  static const String classAssignmentsTable = 'class_assignments';
  static const String studentAssignmentProgressTable =
      'student_assignment_progress';
  static const String classMatchingResultsTable = 'class_matching_results';
  static const String adminRolesTable = 'admin_roles';
  static const String adminRoleBindingsTable = 'admin_role_bindings';
  static const String adminAuditLogsTable = 'admin_audit_logs';
  static const String adminAccountBlocksTable = 'admin_account_blocks';
  static const String adminBulkJobsTable = 'admin_bulk_jobs';
  static const String adminRiskAlertsTable = 'admin_risk_alerts';
  static const String adminImpersonationSessionsTable =
      'admin_impersonation_sessions';
  static const String adminApprovalRequestsTable = 'admin_approval_requests';
  static const String adminNotificationRoutesTable =
      'admin_notification_routes';
  static const String adminNotificationOutboxTable =
      'admin_notification_outbox';
  static const String adminImpersonationTelemetryTable =
      'admin_impersonation_telemetry';
  static const String adminComplianceExportsTable = 'admin_compliance_exports';
  static const String publicStudySetsTable = 'public_study_sets';
  static const String communityReportsTable = 'community_reports';
  static const String communityLikesTable = 'community_likes';
  static const String communitySavesTable = 'community_saves';
  static const String communityDownloadsTable = 'community_downloads';
  static const String communityCommentsTable = 'community_comments';
  static const String communityRatingsTable = 'community_ratings';
  static const String communityFriendshipsTable = 'community_friendships';
}
